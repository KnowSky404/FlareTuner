# FlareTuner Tuning Rules

FlareTuner's first script version targets Debian and Ubuntu VPS servers using standard Linux BBR and `fq`. It does not install kernels, replace congestion control modules, tune BBRv2, or run benchmarks.

## Inputs

The generated configuration is based on four interactive inputs:

- Workload: `web`, `proxy`, `download`, or `low-memory`.
- Memory tier: `under-512m`, `512m-1g`, `1g-4g`, or `4g-plus`.
- Bandwidth tier: `under-100m`, `100m-500m`, `500m-1g`, or `1g-plus`.
- Tuning profile: `conservative`, `balanced`, or `aggressive`.

## Baseline Settings

Every generated profile includes:

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

`fq` pairs with standard BBR because BBR depends on packet pacing to control send timing. The fair queue scheduler provides kernel pacing support and per-flow fairness, which makes it a practical default queue discipline for BBR on supported Linux systems.

## Memory Safety

Low-memory systems can become unstable if socket buffer ceilings are raised too far. FlareTuner caps receive and send buffer limits on small memory tiers, and the `low-memory` workload overrides other inputs with smaller bounded values for buffers, connection queues, and network device backlog.

## Workload Behavior

The `web` workload raises connection backlog values with `net.core.somaxconn` and `net.ipv4.tcp_max_syn_backlog` while keeping socket buffers moderate.

The `proxy` workload raises `net.core.netdev_max_backlog` to give the network device queue more room during bursts.

The `download` workload raises socket buffer ceilings with `net.core.rmem_max`, `net.core.wmem_max`, `net.ipv4.tcp_rmem`, and `net.ipv4.tcp_wmem` for higher throughput profiles.

The `low-memory` workload takes priority over throughput-oriented choices by bounding socket buffers, connection backlog values, and network device backlog to smaller values.

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

Restore uses the latest FlareTuner metadata to restore or remove only the FlareTuner-managed sysctl file. If a previous managed file existed, restore copies that backup back to `/etc/sysctl.d/99-flaretuner.conf`. If no previous managed file existed, restore removes `/etc/sysctl.d/99-flaretuner.conf`.

## Apply Safety

When apply mode writes a generated configuration, it runs `sysctl --system` and verifies that active congestion control is `bbr` and active default qdisc is `fq`. If applying or verification fails, FlareTuner attempts to restore the previous managed file and re-run `sysctl --system`.

The restore menu can also be used to restore the latest FlareTuner-managed backup.
