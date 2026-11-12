# AGENTS.md

Default context for Codex and other coding agents working in this repository.

## Project Overview

FlareTuner is an interactive Bash script for conservative Linux network tuning on Debian and Ubuntu VPS servers. The MVP enables standard Linux BBR with `fq`, renders a small managed sysctl profile from interactive inputs, can apply it as root, can restore the latest FlareTuner-managed backup, and can report current tuning status.

Primary files:

- `scripts/flaretuner.sh` - interactive CLI and all MVP behavior.
- `tests/flaretuner_test.sh` - Bash test runner using environment overrides and temp dirs.
- `docs/tuning-rules.md` - tuning inputs, safety rules, workload behavior, and rollback model.
- `README.md` - user-facing scope, usage, and safety notes.
- `skills/flaretuner/SKILL.md` - repo-local skill for agents working on FlareTuner behavior, docs, tests, or release workflow.

## Hard Product Boundaries

- Support Debian and Ubuntu only.
- Target standard Linux `bbr` plus `fq`.
- Do not install, replace, or upgrade kernels.
- Do not add automatic BBRv2 tuning.
- Do not add benchmark or speed test workflows unless explicitly requested.
- Do not support non-Debian/Ubuntu distributions in MVP behavior.
- Do not edit `/etc/sysctl.conf`.
- FlareTuner must only write, restore, or remove its managed sysctl file:
  `/etc/sysctl.d/99-flaretuner.conf`.
- Backup metadata and backups belong under `/var/lib/flaretuner/`.

## Safety Rules

- Treat apply and restore paths as high-risk because they affect host sysctl state.
- Apply and restore must require root before writing files or running `sysctl --system`.
- Preview and status should remain usable without root where practical.
- Tests must never touch real `/etc` or `/var/lib` paths. Use the existing environment overrides:
  - `FLARETUNER_ETC_DIR`
  - `FLARETUNER_STATE_DIR`
  - `FLARETUNER_OS_RELEASE`
  - `FLARETUNER_SYSCTL_CMD`
  - `FLARETUNER_MODPROBE_CMD`
  - `FLARETUNER_LSMOD_CMD`
  - `FLARETUNER_UNAME_CMD`
  - `FLARETUNER_ID_CMD`
- Do not source backup metadata as shell code. Parse and validate metadata explicitly.
- Backup restore must reject unsafe paths, missing backup files, symlinks, and paths outside the FlareTuner backup directory.
- If apply fails after writing the managed file, restore the previous managed state when possible and re-run `sysctl --system` best-effort.

## Implementation Style

- Keep the project simple: Bash, Markdown, and focused shell tests.
- Agents that support repo-local skills should load `skills/flaretuner/SKILL.md` before modifying project behavior, documentation, tests, or release workflow.
- Prefer using Superpowers skills for architecture discussion, implementation planning, feature development, debugging, testing strategy, and completion verification whenever the available task matches a Superpowers workflow.
- For larger or ambiguous changes, generate or update a written plan before editing code. Keep plans in `docs/superpowers/plans/` when they are meant to be reused by future agents.
- For new behavior or bug fixes, prefer a test-first or regression-test-first workflow when practical.
- Prefer small named Bash functions split by responsibility:
  platform detection, root checks, BBR checks, profile mapping, config rendering, backup/restore, status, and menu flow.
- Keep generated sysctl values conservative and explainable. Low-memory behavior takes priority over throughput-oriented settings.
- Preserve the `FLARETUNER_TESTING=1` guard:

```bash
if [[ "${FLARETUNER_TESTING:-0}" != "1" ]]; then
  main "$@"
fi
```

- Use ASCII in scripts and docs unless existing content requires otherwise.
- Avoid broad refactors unrelated to the requested change.

## Development And PR Workflow

These rules apply to every feature, bug fix, refactor, test, documentation, configuration, and workflow change, including changes to these instructions.

1. Inspect the current status, worktrees, and remote state. Fetch `origin` and create a dedicated local worktree with a new task branch from `origin/main`. Do not develop directly on `main` or reuse another task's branch. Preserve unrelated changes.
2. Implement and run the required local verification in that worktree. Inspect the complete diff and create focused Conventional Commits.
3. Before every push and before creating a PR, run local Codex `/review` on the complete branch diff against `origin/main` (CLI equivalent: `codex review --base origin/main`). Resolve findings and repeat verification and review until no unresolved findings remain. Record the reviewed HEAD and base SHAs. One completed review may cover the following push and PR creation only while HEAD, base, and diff are unchanged. Any subsequent change invalidates that review. If local review cannot run or complete, stop before pushing or creating the PR and report the blocker.
4. Verify the GitHub Actions policy below before pushing, creating the PR, or merging. Push the task branch and open a PR targeting `main`; never push task changes directly to `main`.
5. Inspect reviews, inline threads, PR comments, and check runs for the current PR HEAD. If Codex automatically starts a review, wait for completion and resolve all findings before merging. Fixes must go through local verification and `/review` again before another push. Reviews for an older HEAD do not satisfy this gate.
6. Never manually trigger or retrigger the Codex bot: no review-request comments, reviewer requests, dispatches, configuration toggles, empty commits, or draft/ready transitions intended to provoke review. If read-only inspection confirms no automatic Codex review started, record `not_triggered` and proceed without requesting one. Pending/running, failed/cancelled, stale, unreadable, or query-failed review states are not proof of absence; reconcile them before merging. An acknowledgement or reaction alone does not prove review completion.
7. After local verification, the applicable review gate, and any existing merge requirements are satisfied, rebase merge the reviewed PR HEAD (for example, `gh pr merge <PR> --rebase --match-head-commit <SHA>`). Do not bypass branch protections or use merge/squash commits. Completing a requested change includes pushing, opening the PR, handling automatic review, merging, and cleanup unless the user explicitly narrows the scope.
8. Confirm the PR is merged and its changes are present in `origin/main`; rebase can change commit SHAs, so verify content or patch equivalence. Fast-forward a clean local `main` only. Delete the original remote task branch if it still exists, remove the clean task worktree without force, and delete its local branch only after confirming all task changes were integrated. Preserve unrelated worktrees, untracked files, and retained evidence. Report any cleanup blocker.

## GitHub Actions Authorization

- GitHub Actions is disabled at repository level by default. Keep it disabled unless the user explicitly authorizes a specific workflow/run or a change to this policy. Verify the live setting with `gh api repos/KnowSky404/FlareTuner/actions/permissions`; `enabled` must be `false` before ordinary pushes, PR creation, and merges. If it has drifted, restore the disabled setting before proceeding; report a permission blocker instead of risking a run.
- A request to implement, test, push, create a PR, merge, tag, or release is not authorization to run GitHub Actions. Run required verification locally.
- Without explicit authorization, do not enable Actions, dispatch or rerun workflows/jobs, approve pending runs, or add/enable automatic triggers such as `push`, `pull_request`, `pull_request_target`, `schedule`, `release`, `workflow_run`, or `repository_dispatch`. This includes indirect triggers and workflows in other repositories.
- If a workflow is needed, keep it manual-only with `workflow_dispatch`; adding that definition does not authorize enabling Actions or executing it. Before any authorized temporary enablement, inspect all workflows and prevent unrelated automatic runs, then restore the disabled setting after the authorized work unless broader permission was explicit.
- Do not add required Actions checks while Actions is disabled. If an existing required check blocks merging, report the conflict; do not enable CI or bypass protection without explicit authorization.
- Automatic Codex review through its GitHub App is separate from Actions authorization. Allow an existing automatic review, but never enable or run Actions to obtain it. If review requires Actions, report that conflict.
- Repository settings are maintained through GitHub, not tracked files: allow rebase merging only and enable automatic deletion of merged PR branches. Verify settings when delivering workflow changes; do not claim a documentation edit alone enforces them.

## Git And Commit Discipline

- Prefer small, atomic commits that each represent one coherent change.
- After completing requested modifications, create an atomic commit for the completed work unless the user explicitly asks not to commit.
- Do not mix unrelated refactors, formatting churn, generated files, and behavior changes in the same commit.
- Before committing, inspect the diff and stage only files that belong to the intended change.
- Commit messages should describe the behavior or documentation change, not the mechanics of editing.
- Do not rewrite, squash, or amend user-authored work unless the user explicitly asks.

## Verification Commands

Run these before claiming a script or documentation-adjacent code change is complete:

```bash
bash -n scripts/flaretuner.sh
bash -n tests/flaretuner_test.sh
bash tests/flaretuner_test.sh
```

For changes that affect the interactive menu, manually exercise the relevant menu path with mocked or safe local inputs where possible. Full real-system apply should only be verified on a disposable Debian or Ubuntu VPS.

## Documentation Expectations

- Keep `README.md` aligned with user-visible behavior.
- Keep `docs/tuning-rules.md` aligned with profile inputs, generated settings, low-memory rules, and rollback behavior.
- If changing managed paths, backup behavior, supported OS rules, or apply semantics, update both docs and tests.

## Context7 Documentation Rule

Use Context7 MCP to fetch current documentation whenever asked about a library, framework, SDK, API, CLI tool, or cloud service, including API syntax, configuration, migration, setup, debugging, and CLI usage. Start with `resolve-library-id` unless the user provides an exact `/org/project` library ID, then call `query-docs` and answer from the fetched docs.

Do not use Context7 for refactoring, writing scripts from scratch, debugging project business logic, code review, or general programming concepts.

## GitHub CLI Body Safety

When using `gh` commands that send issue or pull request prose, prefer `--body-file`. Never inline multi-line Markdown, backticks, dollar signs, quotes, or complex prose directly into a shell string for:

- `gh issue create`
- `gh issue edit`
- `gh issue comment`
- `gh pr create`
- `gh pr edit`
- `gh pr comment`

Write the body to a temporary file with a quoted heredoc and pass `--body-file`.

## JavaScript Package Manager Preference

If global JavaScript or Node.js packages or CLIs are ever needed, prefer:

1. `bun`
2. `pnpm`
3. `npm`

Use `npm` for global installs only if `bun` and `pnpm` are unsuitable or unavailable. Confirm Codex's non-interactive shell can resolve the installed binary.

## Subagent Defaults

When spawning child agents, do not override the model unless the user explicitly asks for a different model. Child agents should inherit the current parent model by default. Reasoning effort may vary when task-appropriate.
