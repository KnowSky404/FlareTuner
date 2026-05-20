# FlareTuner Project Rules

## Files

- `scripts/flaretuner.sh`: interactive CLI and all runtime behavior.
- `tests/flaretuner_test.sh`: Bash test suite with temp dirs and command/file overrides.
- `docs/tuning-rules.md`: profile inputs, generated setting behavior, tc limits, rollback, and apply safety.
- `README.md`: user-facing usage, scope, and safety notes.
- `AGENTS.md`: repository instructions for coding agents.

## Runtime Model

FlareTuner generates a conservative sysctl profile from:

- Workload: `web`, `proxy`, `download`, `low-memory`.
- Memory tier: `under-512m`, `512m-1g`, `1g-4g`, `4g-plus`.
- Bandwidth tier: `under-100m`, `100m-500m`, `500m-1g`, `1g-plus`.
- Tuning profile: `conservative`, `balanced`, `aggressive`.
- Path profile: `normal`, `high-latency`, `qos-sensitive`.
- Target bandwidth Mbps: positive integer or `auto`.

Every generated profile includes:

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

The optional target Mbps influences profile recommendation only. It is not a traffic shaper. The separate `tc` menu path applies runtime interface-wide egress shaping.

## Safety-Critical Behavior

Apply:

- Requires root.
- Requires Debian or Ubuntu.
- Attempts to make BBR available with `modprobe tcp_bbr` only on apply.
- Backs up the existing managed file, if any.
- Writes only the managed sysctl file.
- Runs `sysctl --system`.
- Verifies active congestion control is `bbr` and default qdisc is `fq`.
- On failure, restores the previous managed state when possible and reruns `sysctl --system` best-effort.

Restore:

- Requires root.
- Parses metadata explicitly; never source metadata as shell.
- Rejects unknown keys, duplicate keys, invalid values, unsafe paths, missing files, symlinks, and paths escaping the backup directory.
- Restores or removes only the managed sysctl file.

TC egress limit:

- Requires root.
- Validates interface name and numeric Mbps.
- Replaces the selected interface root qdisc.
- Stores metadata at `/var/lib/flaretuner/tc-limit.env`.
- Clears only the latest FlareTuner-recorded root qdisc.
- Is runtime state and is not persisted across reboot by FlareTuner.

## Test Overrides

Use these instead of touching host state:

- `FLARETUNER_ETC_DIR`
- `FLARETUNER_STATE_DIR`
- `FLARETUNER_OS_RELEASE`
- `FLARETUNER_SYSCTL_CMD`
- `FLARETUNER_MODPROBE_CMD`
- `FLARETUNER_LSMOD_CMD`
- `FLARETUNER_UNAME_CMD`
- `FLARETUNER_ID_CMD`
- `FLARETUNER_MEMINFO`
- `FLARETUNER_NET_CLASS_DIR`
- `FLARETUNER_TC_CMD`

## Common Change Checklist

- Profile value change: update render/profile tests and `docs/tuning-rules.md`.
- New menu behavior: add mocked tests, update `README.md`, and manually exercise safe input paths.
- Apply/restore behavior change: add regression tests for failure and rollback paths, update docs.
- Managed path or state path change: update tests, `README.md`, `docs/tuning-rules.md`, and `AGENTS.md`.
- TC behavior change: test command generation and metadata handling; document runtime/non-persistent behavior.
