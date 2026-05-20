# FlareTuner

FlareTuner is an interactive Bash script for applying conservative network tuning profiles on Debian and Ubuntu VPS servers. The script focuses on enabling standard Linux BBR with `fq` and writing a small managed sysctl configuration based on the selected server profile.

## MVP Scope

The script MVP supports:

- Debian and Ubuntu only.
- Previewing a generated tuning profile.
- Applying a generated tuning profile as root.
- Restoring the latest FlareTuner-managed backup.
- Inspecting current network tuning status.
- Reading local memory and interface speed data to preselect conservative recommended profile inputs.
- Applying and clearing an optional runtime `tc` egress bandwidth limit.

Non-goals for this MVP:

- Installing, replacing, or upgrading the kernel.
- BBRv2 tuning.
- Benchmarking or proving performance gains.
- Supporting non-Debian and non-Ubuntu distributions.

## Usage

Run the interactive menu:

```bash
bash scripts/flaretuner.sh
```

Apply and restore require root privileges because they write or remove the managed sysctl file and reload sysctl settings:

```bash
sudo bash scripts/flaretuner.sh
```

Preview and status can run without root. The menu can preview tuning, apply tuning, restore the latest FlareTuner backup, or show current network tuning status.

When generating a profile, FlareTuner reads local system information to recommend defaults for workload, memory tier, bandwidth tier, path profile, and tuning profile. Press Enter to accept each recommended value, or enter a menu number to override it manually. The recommendation is intentionally simple: it reads `/proc/meminfo` for memory size and `/sys/class/net/*/speed` for interface speed where available. It does not run speed tests or contact cloud provider metadata services.

You can enter an optional target bandwidth in Mbps before choosing the profile inputs. This value changes the generated sysctl recommendation tier, but it is not an actual traffic shaper. For example, entering `90` can make the sysctl profile stay conservative for a route that becomes unstable above 100 Mbps, but FlareTuner does not enforce a 90 Mbps cap in this MVP.

For real server-to-client egress shaping, use the `Apply tc egress bandwidth limit` menu item as root. It asks for an interface such as `eth0` and a numeric Mbps rate, then installs a FlareTuner-managed root qdisc on that interface. This is runtime state: it is not persisted across reboot by FlareTuner. Clearing the FlareTuner tc limit uses the metadata stored under `/var/lib/flaretuner/` and removes the root qdisc from the recorded interface.

## Safety

FlareTuner writes only its managed sysctl file:

```text
/etc/sysctl.d/99-flaretuner.conf
```

It does not edit `/etc/sysctl.conf`.

Backup metadata and backups are stored under:

```text
/var/lib/flaretuner/
```

The restore menu restores the latest FlareTuner-managed backup. If no previous managed file existed, restore removes the managed file. Apply failures trigger restoration of the previous managed file when possible.

Apply and restore run `sysctl --system`, which reloads system sysctl configuration broadly. FlareTuner still only writes, restores, or removes its managed file.

The optional `tc` egress limiter replaces the root qdisc on the chosen interface. Do not use it on an interface where you already maintain custom `tc` policy unless you are prepared for FlareTuner to replace that root qdisc.

## Tuning Rules

See [docs/tuning-rules.md](docs/tuning-rules.md) for the profile inputs, baseline settings, workload behavior, low-memory safety rules, and rollback model.

## Development

Run shell syntax checks:

```bash
bash -n scripts/flaretuner.sh
bash -n tests/flaretuner_test.sh
```

Run the test suite:

```bash
bash tests/flaretuner_test.sh
```
