# v0.2.0 runtime safety implementation

Scope: P0-1 through P0-5 in the user-provided MicroBin task bWXznd.
No release, profile-value changes, kernel changes, persistence, or integration.

## Audit before changes

- Critical: tc root replacement overwrites unrelated policy; clear trusts old metadata.
- High: class/child/metadata failures leave partial untracked kernel state.
- High: sysctl conflict sources are ignored; verification checks only two keys.
- High: direct config/metadata writes, predictable backup names, no shared lock,
  interrupt recovery, file permissions, or managed-file drift checks.
- Medium: status presents metadata as active tc state and can exit on corrupt state.
- Existing coverage: 31 tests, primarily happy paths and backup-path rejection.

## Implementation sequence

1. Add stateful negative regression fixtures before modifying operations.
2. Shared filesystem validation, exclusive lock, private transaction journal,
   atomic publication, and signal/EXIT recovery. Refuse unfinished journals.
3. Inventory procps/systemd source directories with basename masking; report
   equal/different/unknown declarations including sysctl.conf and glob rules.
   Do not claim a single boot-time winner; verify all managed runtime keys.
4. Snapshot managed file and runtime keys; verify idempotence and guarded rollback.
5. Validate live tc topology, boot/interface identity and protected fingerprints;
   use add for first apply and change only the owned class for updates. Guard
   every step, metadata commit, cleanup and rollback against drift.
6. Accurate read-only status; update README and tuning rules; add acceptance
   report including test boundaries and v0.3/integration follow-ups.
7. Required syntax/tests/diff checks, commit, exact-HEAD local Codex review,
   Actions-disabled push/PR, automatic-review inspection, rebase merge, cleanup.

## Evidence and boundaries

Tests use temporary etc/state/sysfs and mocked sysctl/tc; no host mutations.
The default sandbox has no CAP_NET_ADMIN or CAP_SYS_ADMIN. Subsequent authorized
execution outside the sandbox enabled a guarded fresh-network-namespace tc harness;
ten real-kernel tc cases passed. Full VM/sysctl acceptance remains unverified. Bash cannot atomically
commit multiple kernel operations or exclude unrelated privileged writers.
Uncertain recovery must fail with a retained private journal, never delete an
unverified qdisc. SIGKILL/power loss leaves a journal that blocks new mutations.
