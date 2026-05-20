# FlareTuner Tuning Rules

FlareTuner's first script version targets Debian and Ubuntu VPS servers using standard Linux BBR and `fq`. It does not install kernels, replace congestion control modules, tune BBRv2, or run benchmarks.

## Inputs

The generated configuration is based on six interactive inputs:

- Workload: `web`, `proxy`, `download`, or `low-memory`.
- Memory tier: `under-512m`, `512m-1g`, `1g-4g`, or `4g-plus`.
- Bandwidth tier: `under-100m`, `100m-500m`, `500m-1g`, or `1g-plus`.
- Tuning profile: `conservative`, `balanced`, or `aggressive`.
- Path profile: `normal`, `high-latency`, or `qos-sensitive`.
- Optional target bandwidth in Mbps, or `auto`.

FlareTuner preselects recommended defaults before prompting. It reads `/proc/meminfo` to classify memory and reads numeric `/sys/class/net/*/speed` values, excluding loopback, to classify bandwidth. If memory cannot be read, it defaults to `512m-1g`. If interface speed cannot be read, it defaults to `under-100m`.

The recommendation rule stays conservative:

- `under-512m` memory recommends `low-memory` with the `conservative` profile.
- `1g-plus` bandwidth with more than 1 GiB memory recommends `download` with the `balanced` profile.
- Other detected combinations recommend `web` with the `conservative` profile.

Users can press Enter to accept each recommendation or select a different menu option. FlareTuner does not run speed tests or contact cloud provider metadata services.

The optional target bandwidth value maps to the same bandwidth tiers used by the rest of the profile. It does not enforce a traffic cap. It only guides sysctl profile generation. Real per-route or per-user rate limiting requires a separate traffic control layer such as application-level limits or `tc`.

## Baseline Settings

Every generated profile includes:

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

`fq` pairs with standard BBR because BBR depends on packet pacing to control send timing. The fair queue scheduler provides kernel pacing support and per-flow fairness, which makes it a practical default queue discipline for BBR on supported Linux systems.

## Memory Safety

Low-memory systems can become unstable if socket buffer ceilings are raised too far. Memory tier selection sets the starting receive and send buffer limits, but later bandwidth and workload choices can raise those limits for throughput-oriented profiles.

The `low-memory` workload is the safety override that runs after the other inputs. It enforces smaller bounded values for buffers, connection queues, and network device backlog.

## Workload Behavior

The `web` workload raises connection backlog values with `net.core.somaxconn` and `net.ipv4.tcp_max_syn_backlog` while keeping socket buffers moderate.

The `proxy` workload raises `net.core.netdev_max_backlog` to give the network device queue more room during bursts.

The `download` workload raises socket buffer ceilings with `net.core.rmem_max`, `net.core.wmem_max`, `net.ipv4.tcp_rmem`, and `net.ipv4.tcp_wmem` for higher throughput profiles.

The `low-memory` workload takes priority over throughput-oriented choices by bounding socket buffers, connection backlog values, and network device backlog to smaller values.

## Path Behavior

The `normal` path profile leaves the workload, memory, bandwidth, and tuning profile rules unchanged.

The `high-latency` path profile is intended for cross-region or high-RTT paths. It allows moderate socket buffer growth when memory is sufficient, because higher RTT increases bandwidth-delay product.

The `qos-sensitive` path profile is intended for routes where bursts or sustained throughput above a threshold appear to trigger throttling. It keeps socket buffers, connection backlog values, and device backlog more conservative. This can reduce aggressive buffering, but it does not shape traffic or guarantee that throughput remains under a provider or network QoS threshold.

## Traffic Control Limits

FlareTuner can optionally apply a runtime `tc` egress bandwidth limit to a selected interface. This is intended for server-to-client return traffic, for example a Japan VPS sending proxy traffic back to a client where rates above a threshold trigger QoS.

The current limiter is interface-wide egress shaping:

- It requires root.
- It validates the interface name and numeric Mbps value before running `tc`.
- It replaces the selected interface root qdisc with an `htb` class at the requested rate and attaches `fq` below that class.
- It stores FlareTuner metadata at `/var/lib/flaretuner/tc-limit.env`.
- It can clear only the latest FlareTuner-recorded tc limit.
- It is runtime state and is not persisted across reboot by FlareTuner.

The limiter does not handle ingress shaping, IFB devices, per-user limits, per-destination limits, or proxy-application account limits. It also cannot control the client-to-server direction from the server, because TCP rate control primarily applies at the sender.

## Rollback Model

FlareTuner writes only this managed sysctl file:

```text
/etc/sysctl.d/99-flaretuner.conf
```

It stores latest backup metadata at:

```text
/var/lib/flaretuner/latest-backup.env
```

Backups are stored under:

```text
/var/lib/flaretuner/backup/
```

Optional tc limit metadata is stored at:

```text
/var/lib/flaretuner/tc-limit.env
```

Restore uses the latest FlareTuner metadata to restore or remove only the FlareTuner-managed sysctl file. If a previous managed file existed, restore copies that backup back to `/etc/sysctl.d/99-flaretuner.conf`. If no previous managed file existed, restore removes `/etc/sysctl.d/99-flaretuner.conf`.

## Apply Safety

When apply mode writes a generated configuration, it runs `sysctl --system` and verifies that active congestion control is `bbr` and active default qdisc is `fq`. If applying or verification fails, FlareTuner attempts to restore the previous managed file and re-run `sysctl --system`.

The restore menu can also be used to restore the latest FlareTuner-managed backup.
