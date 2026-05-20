# FlareTuner

FlareTuner is an interactive Bash script for conservative network tuning on Debian and Ubuntu VPS servers. It focuses on standard Linux BBR with `fq`, a small managed sysctl profile, and an optional runtime `tc` egress limit for servers that need a practical bandwidth ceiling.

The project is intentionally small: one Bash script, one shell test runner, and Markdown documentation. It does not install kernels, benchmark the network, or try to tune BBRv2.

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

## Repository Map

- `scripts/flaretuner.sh` - interactive CLI and all runtime behavior.
- `tests/flaretuner_test.sh` - shell tests using environment overrides and temp directories.
- `docs/tuning-rules.md` - detailed tuning inputs, generated settings, safety rules, and rollback model.
- `AGENTS.md` - working instructions for Codex, Hermes-style agents, and other AI coding agents.
- `docs/superpowers/specs/` - project specs for larger changes.
- `docs/superpowers/plans/` - implementation plans that future agents can reuse.

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

Menu items:

1. `Generate and apply tuning` - generates a profile, asks for confirmation, writes the managed sysctl file, runs `sysctl --system`, and verifies active `bbr` plus `fq`.
2. `Preview tuning only` - renders the profile and current status without writing files or loading kernel modules.
3. `Restore last FlareTuner backup` - restores or removes only the FlareTuner-managed sysctl file from the latest metadata.
4. `Show current network tuning status` - prints OS, kernel, BBR, qdisc, managed config, backup, and tc limit state.
5. `Apply tc egress bandwidth limit` - applies a runtime interface-wide egress limit with `tc`.
6. `Clear FlareTuner tc egress limit` - removes the latest FlareTuner-recorded root qdisc from the recorded interface.

When generating a profile, FlareTuner reads local system information to recommend defaults for workload, memory tier, bandwidth tier, path profile, and tuning profile. Press Enter to accept each recommended value, or enter a menu number to override it manually. The recommendation is intentionally simple: it reads `/proc/meminfo` for memory size and `/sys/class/net/*/speed` for interface speed where available. It does not run speed tests or contact cloud provider metadata services.

You can enter an optional target bandwidth in Mbps before choosing the profile inputs. This value changes the generated sysctl recommendation tier, but it is not an actual traffic shaper. For example, entering `90` can make the sysctl profile stay conservative for a route that becomes unstable above 100 Mbps, but FlareTuner does not enforce a 90 Mbps cap in this MVP.

For real server-to-client egress shaping, use the `Apply tc egress bandwidth limit` menu item as root. It asks for an interface such as `eth0` and a numeric Mbps rate, then installs a FlareTuner-managed root qdisc on that interface. This is runtime state: it is not persisted across reboot by FlareTuner. Clearing the FlareTuner tc limit uses the metadata stored under `/var/lib/flaretuner/` and removes the root qdisc from the recorded interface.

## Profile Inputs

Generated sysctl profiles use these inputs:

- Workload: `web`, `proxy`, `download`, or `low-memory`.
- Memory tier: `under-512m`, `512m-1g`, `1g-4g`, or `4g-plus`.
- Bandwidth tier: `under-100m`, `100m-500m`, `500m-1g`, or `1g-plus`.
- Tuning profile: `conservative`, `balanced`, or `aggressive`.
- Path profile: `normal`, `high-latency`, or `qos-sensitive`.
- Target bandwidth Mbps: a positive integer, or `auto`.

Low-memory behavior takes priority over throughput-oriented settings. The `qos-sensitive` path profile keeps buffers and backlogs more conservative, but it does not shape traffic by itself.

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

## AI Agent Notes

AI coding agents should start with [AGENTS.md](AGENTS.md). It is the authoritative agent instruction file for this repository and includes product boundaries, safety rules, test requirements, Context7 usage rules, GitHub CLI body safety, and subagent defaults.

For Codex, Hermes-style agents, or other agents that support reusable skills:

- Use the repo-level `AGENTS.md` before making changes.
- Treat `scripts/flaretuner.sh` as the source of truth for runtime behavior.
- Treat `docs/tuning-rules.md` as the source of truth for tuning semantics and rollback behavior.
- Keep this README aligned with user-visible behavior.
- For behavior changes or bug fixes, prefer regression-test-first edits in `tests/flaretuner_test.sh`.
- For larger changes, write or update a spec under `docs/superpowers/specs/` and an implementation plan under `docs/superpowers/plans/`.
- If the task asks about a library, SDK, API, CLI tool, or cloud service, use Context7 MCP for current docs before answering or editing.
- Do not use Context7 for ordinary Bash refactoring, business-logic debugging, or code review.

Agent-safe local verification commands:

```bash
bash -n scripts/flaretuner.sh
bash -n tests/flaretuner_test.sh
bash tests/flaretuner_test.sh
```

The test suite is designed to avoid real `/etc` and `/var/lib` writes. It uses environment overrides such as `FLARETUNER_ETC_DIR`, `FLARETUNER_STATE_DIR`, `FLARETUNER_SYSCTL_CMD`, `FLARETUNER_TC_CMD`, and related command/file overrides.

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
