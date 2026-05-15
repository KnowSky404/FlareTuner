# FlareTuner Script MVP Design

Date: 2026-05-15

## Goal

Build the first FlareTuner release around an interactive shell script for Debian and Ubuntu VPS servers. The script helps users enable standard BBR with `fq`, generate conservative network tuning parameters from a small set of server profile inputs, preview the result, optionally apply it, and roll back the last FlareTuner-managed change.

The script is the source of truth for the first version because system detection, safety checks, backups, and recovery behavior are the highest-risk parts of the product. A web page can later reuse the same input model and tuning rules to generate copyable configuration.

## Non-Goals

- No Web UI in this MVP.
- No automatic kernel installation or replacement.
- No automatic BBRv2 tuning.
- No benchmark runner or speed test workflow.
- No support guarantee for CentOS, Rocky Linux, AlmaLinux, Arch, or Alpine in the first version.
- No direct editing of `/etc/sysctl.conf`.

## Supported Platform

The MVP explicitly supports Debian and Ubuntu servers that have:

- `bash`
- `sysctl`
- `/etc/os-release`
- `/etc/sysctl.d/`
- a kernel with `tcp_bbr` available or loadable

If the script detects another distribution, it should stop before applying changes and explain that only Debian and Ubuntu are supported in this version.

## User Flow

The script starts with a simple menu:

1. Generate and apply tuning
2. Preview tuning only
3. Restore last FlareTuner backup
4. Show current network tuning status
5. Exit

For generation flows, the script asks:

- Workload:
  - Web/API
  - Proxy/VPN
  - Download or high-throughput transfer
  - Low-memory VPS
- Memory tier:
  - under 512 MB
  - 512 MB to 1 GB
  - 1 GB to 4 GB
  - 4 GB or more
- Bandwidth tier:
  - under 100 Mbps
  - 100 Mbps to 500 Mbps
  - 500 Mbps to 1 Gbps
  - 1 Gbps or more
- Tuning profile:
  - conservative
  - balanced
  - aggressive

The script then prints:

- detected OS and kernel
- current congestion control and queue discipline
- whether BBR appears available
- generated sysctl config
- a short explanation of the main tuning choices

In apply mode, the script asks for explicit confirmation before writing files or running `sysctl --system`.

## Configuration Target

FlareTuner writes only this managed file:

```text
/etc/sysctl.d/99-flaretuner.conf
```

The generated file includes a header stating that it is managed by FlareTuner and can be restored through the script. The MVP does not modify `/etc/sysctl.conf` or other sysctl snippets.

The baseline generated settings include:

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

Additional settings are chosen from the workload, memory tier, bandwidth tier, and tuning profile. The rules should prefer safe, explainable values over maximum benchmark-oriented values. Low-memory profiles must keep socket buffers modest. High-bandwidth profiles may increase buffer and backlog values, but with bounded ceilings.

## Tuning Rule Shape

The script keeps tuning rules in named Bash functions instead of inline menu branches. The initial implementation should separate:

- input parsing and validation
- platform detection
- BBR availability checks
- profile-to-parameter mapping
- config rendering
- apply and rollback operations
- status reporting

This structure keeps the shell MVP testable and makes it easier to port the rule model to a future Web UI.

## BBR Handling

The script checks:

- current value of `net.ipv4.tcp_congestion_control`
- current value of `net.core.default_qdisc`
- whether `bbr` appears in `sysctl net.ipv4.tcp_available_congestion_control`
- whether `tcp_bbr` is already loaded according to `lsmod`

If BBR is unavailable, the script may try `modprobe tcp_bbr` when running as root. If BBR is still unavailable after that, apply mode should stop and explain that the kernel likely does not support standard BBR.

BBRv2 is not tuned automatically. If the script detects non-standard BBR-related algorithms, it should report the current state and continue to target standard `bbr` only.

## Apply Flow

Before applying, the script:

- requires root
- verifies Debian or Ubuntu
- verifies BBR availability
- creates `/var/lib/flaretuner/backup/` if needed
- backs up the current `/etc/sysctl.d/99-flaretuner.conf` when present
- records latest backup metadata in `/var/lib/flaretuner/latest-backup.env`

After writing the new managed file, the script runs:

```text
sysctl --system
```

Then it verifies the active values for:

- `net.ipv4.tcp_congestion_control`
- `net.core.default_qdisc`

If verification fails, it should print the failure clearly and suggest using the restore menu.

## Backup And Rollback

Backups live under:

```text
/var/lib/flaretuner/backup/
```

The script keeps `/var/lib/flaretuner/latest-backup.env` as the pointer for the latest backup. The metadata records whether a previous managed file existed and, if so, the backup path. Restore mode should:

- require root
- restore the previous managed file if one existed
- remove `/etc/sysctl.d/99-flaretuner.conf` if the previous state had no FlareTuner file
- run `sysctl --system`
- print the restored status

Rollback is scoped to the FlareTuner-managed file. It does not try to infer or reverse unrelated sysctl files.

## Status Flow

The status command prints:

- OS name and version
- kernel version
- current congestion control
- available congestion control algorithms
- current default queue discipline
- whether `/etc/sysctl.d/99-flaretuner.conf` exists
- latest backup path, if present

Status mode must not require root unless a specific check cannot run without it.

## Documentation

Add `docs/tuning-rules.md` with:

- supported platforms
- inputs and what they mean
- generated parameter categories
- why FlareTuner enables `bbr` and `fq`
- safety notes for low-memory VPS servers
- rollback behavior

Update `README.md` with:

- project purpose
- MVP support scope
- install/run command
- safety notes
- rollback instructions

## Testing And Verification

The implementation should include focused verification steps:

- `bash -n scripts/flaretuner.sh`
- preview mode as non-root
- invalid menu input handling
- distro detection with mocked `/etc/os-release` where practical
- config rendering for each workload and memory tier
- apply path review to confirm only `/etc/sysctl.d/99-flaretuner.conf` is written

Full system apply should be manually verified on a disposable Debian or Ubuntu VPS before recommending public use.

## Future Web UI Direction

The future Web UI should use the same input model:

- workload
- memory tier
- bandwidth tier
- tuning profile

It can render the same sysctl config and explain each parameter. The Web UI should not require server access for MVP behavior; it should generate copyable configuration and the one-line script command.
