---
name: flaretuner
description: Work safely on the FlareTuner repository, an interactive Bash network-tuning tool for Debian/Ubuntu VPS servers. Use when modifying or reviewing scripts/flaretuner.sh, tests/flaretuner_test.sh, README.md, docs/tuning-rules.md, AGENTS.md, managed sysctl behavior, backup/restore logic, tc egress limit behavior, profile recommendations, or project release/verification workflow.
---

# FlareTuner

Use this skill to keep FlareTuner changes aligned with its narrow safety model: conservative Bash-only tuning for Debian/Ubuntu, standard Linux `bbr` plus `fq`, one managed sysctl file, safe backups, and focused shell tests.

## Start Here

1. Read the repo-level `AGENTS.md` first. Its instructions are authoritative for this project.
2. Read `README.md` for user-visible behavior.
3. Read `docs/tuning-rules.md` when changing profile inputs, generated sysctl values, path behavior, tc limits, or rollback/apply semantics.
4. Inspect `scripts/flaretuner.sh` and `tests/flaretuner_test.sh` before editing behavior.
5. For a compact project rules reference, read `references/project-rules.md`.

## Workflow

For behavior changes or bug fixes:

1. Add or update focused tests in `tests/flaretuner_test.sh` first when practical.
2. Keep implementation in `scripts/flaretuner.sh`; avoid splitting into extra runtime files unless the project explicitly changes direction.
3. Preserve the `FLARETUNER_TESTING=1` guard at the bottom of the script.
4. Use existing environment overrides in tests. Tests must not touch real `/etc`, `/var/lib`, sysctl state, modules, or tc state.
5. Update `README.md` and `docs/tuning-rules.md` when behavior, managed paths, safety semantics, supported OS rules, profile inputs, generated settings, backup/restore, or tc behavior changes.

For documentation-only changes:

1. Keep `README.md` user-facing.
2. Keep `AGENTS.md` agent-facing and operational.
3. Keep `docs/tuning-rules.md` as the detailed tuning/rollback reference.
4. Do not describe unsupported behavior as planned or available.

For releases or publishing:

1. Inspect `git diff` and stage only intended files.
2. Use small atomic commits.
3. Run the verification commands below before claiming completion.

## Hard Boundaries

- Support Debian and Ubuntu only.
- Target standard Linux `bbr` with `fq`.
- Do not install, replace, or upgrade kernels.
- Do not add automatic BBRv2 behavior.
- Do not add benchmark or speed-test workflows unless the user explicitly requests them.
- Do not edit `/etc/sysctl.conf`.
- Only write, restore, or remove `/etc/sysctl.d/99-flaretuner.conf`.
- Store backups and metadata under `/var/lib/flaretuner/`.
- Treat apply, restore, and `tc` paths as high-risk host-network operations.

## Verification

Run these before saying script or documentation-adjacent work is complete:

```bash
bash -n scripts/flaretuner.sh
bash -n tests/flaretuner_test.sh
bash tests/flaretuner_test.sh
```

If the interactive menu changes, manually exercise the relevant menu path with mocked or safe local inputs where possible. Do not verify full real-system apply on a non-disposable server.

## Context7

Use Context7 MCP for current docs only when the user asks about a library, framework, SDK, API, CLI tool, or cloud service. Do not use Context7 for ordinary Bash refactoring, FlareTuner business-logic debugging, code review, or writing shell tests from scratch.
