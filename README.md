# FlareTuner

FlareTuner is an interactive Bash script for conservative network tuning on Debian and Ubuntu VPS servers. It focuses on standard Linux BBR with `fq`, a small managed sysctl profile, and an optional runtime `tc` egress limit for servers that need a practical bandwidth ceiling.

The project is intentionally small: one runtime Bash script, focused shell tests, and Markdown documentation. It does not install kernels, benchmark the network, or try to tune BBRv2.

## Scope

The v0.2.0 safety candidate supports:

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
- `tests/flaretuner_test.sh` and `tests/safety_cases.sh` - isolated shell tests and stateful failure fixtures.
- `docs/tuning-rules.md` - detailed tuning inputs, generated settings, safety rules, and rollback model.
- `AGENTS.md` - working instructions for Codex, Hermes-style agents, and other AI coding agents.
- `skills/flaretuner/` - project skill for agents that can load repo-local skills.
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

1. `Generate and apply tuning` - generates a profile, asks for confirmation, writes the managed sysctl file, checks configuration sources, runs `sysctl --system`, and verifies every generated runtime value.
2. `Preview tuning only` - renders the profile and current status without writing files or loading kernel modules.
3. `Restore last FlareTuner backup` - restores or removes only the FlareTuner-managed sysctl file from the latest metadata.
4. `Show current network tuning status` - prints OS, kernel, BBR, qdisc, managed config, backup, and tc limit state.
5. `Apply tc egress bandwidth limit` - applies a runtime interface-wide egress limit with `tc`.
6. `Clear FlareTuner tc egress limit` - verifies live ownership before removing the managed root qdisc; stale metadata alone never authorizes deletion.

When generating a profile, FlareTuner reads local system information to recommend defaults for workload, memory tier, bandwidth tier, path profile, and tuning profile. Press Enter to accept each recommended value, or enter a menu number to override it manually. The recommendation is intentionally simple: it reads `/proc/meminfo` for memory size and `/sys/class/net/*/speed` for interface speed where available. It does not run speed tests or contact cloud provider metadata services.

You can enter an optional target bandwidth in Mbps before choosing the profile inputs. This value changes the generated sysctl recommendation tier, but it is not an actual traffic shaper. For example, entering `90` can make the sysctl profile stay conservative for a route that becomes unstable above 100 Mbps, but FlareTuner does not enforce a 90 Mbps cap in this MVP.

For real server-to-client egress shaping, use the `Apply tc egress bandwidth limit` menu item as root. It asks for an interface such as `eth0` and a numeric Mbps rate, then installs a FlareTuner-managed root qdisc on that interface. This is runtime state: it is not persisted across reboot by FlareTuner. Clearing verifies protected metadata against the live interface identity, qdisc/class/filter state, and recorded configuration fingerprint. A missing managed qdisc only causes stale metadata cleanup; external policy is preserved.

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

Before sysctl apply, FlareTuner checks declarations in `/etc/sysctl.conf` and the procps/systemd sysctl directories. Equal declarations are reported; different values, relevant globs, unknown syntax, foreign reserved basenames, and managed-file drift refuse application. Other tools' files are never edited or migrated. See [tuning rules](docs/tuning-rules.md#sysctl-source-ownership) for loading and conflict boundaries.

Apply and restore require root and Debian/Ubuntu. They use a shared local `flock`, private snapshots, and atomic file replacement. Every generated runtime key is verified. Reapplying identical configuration with matching runtime skips config writes, backups, and reload. Restore checks the applied file digest, snapshot digests, runtime, and other configuration sources before restoring the latest saved file/runtime state.

Apply and restore still run `sysctl --system`, which reloads system configuration broadly. Recovery covers the managed file and snapshotted keys; it cannot undo every unrelated system effect or exclude arbitrary privileged writers. Failed operations return nonzero. Uncertain or failed rollback preserves a private `transaction.*` journal under `/var/lib/flaretuner/` and blocks further mutations until manual recovery. See [recovery instructions](docs/tuning-rules.md#transaction-and-recovery-boundaries).

First tc apply accepts only an unshaped `noqueue` root without classes/filters. It refuses existing custom queues, including queues whose ownership is uncertain. Updates change only a verified owned class; switching interfaces requires clearing the previous limit first. No tc state is persisted across reboot. Older metadata without ownership/runtime evidence requires manual inspection, rather than automatic deletion or restore.

Full status may require root to read private state. It distinguishes the default qdisc parameter from the actual recorded device queue, active limits from stale metadata, and conflicts from unreadable state.

The 72-case safety suite uses isolated files and simulated commands. An optional network-namespace harness passed ten real-kernel tc cases on Ubuntu. Real sysctl and production VPS acceptance remain outstanding. See the [v0.2.0 safety report](docs/runtime-safety-v020.md) for verification evidence, limitations, and follow-up acceptance. No Release is published by this change.

## AI Agent Notes

AI coding agents should start with [AGENTS.md](AGENTS.md). It is the authoritative agent instruction file for this repository and includes product boundaries, safety rules, test requirements, Context7 usage rules, GitHub CLI body safety, and subagent defaults.

For Codex, Hermes-style agents, or other agents that support reusable skills:

- Use the repo-level `AGENTS.md` before making changes.
- Load `skills/flaretuner/SKILL.md` when working on FlareTuner behavior, docs, tests, or release workflow.
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

Every change uses a dedicated local Git worktree and task branch from `origin/main`, including documentation and configuration changes. Complete local verification and Codex `/review` before every push and before opening a PR. Fix review findings before proceeding; an unchanged HEAD, base, and diff may reuse the same completed local review for the push and PR creation.

Push the branch and open a PR to `main`. Wait for any automatically started Codex review on the current HEAD and resolve its findings. Never manually summon or retrigger the bot. If inspection confirms no review started, record `not_triggered` and proceed with rebase merging after local checks and existing merge requirements pass. Confirm integration, then delete the task branches and clean worktree. See [AGENTS.md](AGENTS.md#development-and-pr-workflow) for the full procedure.

GitHub Actions is disabled at repository level. Running or enabling Actions requires explicit user authorization; permission to push, open a PR, merge, or release does not include permission to run CI. Required checks run locally by default. Any future workflow definitions must be manual-only unless the user explicitly authorizes automatic triggers. Repository settings allow rebase merging only and automatically delete merged PR branches.

Run shell syntax checks:

```bash
bash -n scripts/flaretuner.sh
bash -n tests/flaretuner_test.sh
```

Run the test suite:

```bash
bash tests/flaretuner_test.sh
```
