# v0.2.0 runtime safety candidate

This change implements the P0 safety work requested in MicroBin task bWXznd.
It is an independent FlareTuner candidate, with no Release or sing-box-vps integration.

## Audit and resulting changes

| Before | Risk | Implemented boundary |
| --- | --- | --- |
| tc root replacement and metadata-only deletion | Critical | Refuse foreign trees; verify live topology, rate, identity and protected fingerprint before update/delete |
| Unchecked tc intermediate steps and metadata write | High | Check each command/state; guarded rollback; atomic metadata after full verification |
| No sysctl source inventory; only BBR/fq verified | High | Directory masking, sysctl.conf, equal/different/tool/unknown diagnostics; verify every generated value |
| Direct writes, timestamp backups, no concurrency/signal handling | High | Trusted paths, unique snapshots, atomic rename, shared lock, signal recovery and retained journals |
| Status equates metadata with active tc | Medium | Separate runtime/metadata/default-device state and report stale/drift/unknown |

Core implementation remains `scripts/flaretuner.sh`. Tests remain in the existing
`tests/flaretuner_test.sh` runner, with stateful negative cases in
`tests/safety_cases.sh`. README and tuning rules describe the delivered behavior;
the implementation plan is under `docs/superpowers/plans/`.

## Verification

The original 31 cases remain, with fixtures updated to provide full runtime values
and new ownership evidence. Added cases exercise source directories, masks,
slash keys, tool markers, globs/unknown syntax, managed aliases, idempotence,
non-BBR/fq verification, partial reload, metadata commit failure, safe rollback,
failed rollback, saved-runtime restore, damaged snapshots, symlink/hardlink/mode
checks, all three tc creation failures, update/repeat/clear, reboot/missing/deleted
queues, changed root/class/child/filter/ifindex, interface switching, legacy and
corrupt metadata, INT/TERM/HUP, metadata-publication interruption, shared locking,
interactive apply/status/clear/failure paths, external managed-file deletion after
reload, failed restore with distinct on-disk and saved runtime values, persistent
reload errors that still restore saved keys, per-key restoration failures, external
runtime drift, unrelated valid sysctl exclusions, and hidden implicit HTB leaves.
The optional `tests/tc_netns_test.sh` adds ten real-kernel tc acceptance cases.

Local verification passed: **71/71 cases**, all four syntax checks, and
`git diff --check`. Interactive tc apply/status/clear and failure paths were
exercised with the same isolated fixtures. No profile values were changed.

Required local commands:

```bash
bash -n scripts/flaretuner.sh
bash -n tests/flaretuner_test.sh
bash -n tests/safety_cases.sh
bash -n tests/tc_netns_test.sh
bash tests/flaretuner_test.sh
git diff --check
```

The 71-case suite uses isolated filesystem and command mocks. The default sandbox
has no CAP_NET_ADMIN/CAP_SYS_ADMIN, and its `unshare -Urn true` preflight fails.
Authorized execution outside that sandbox has the required capabilities and passed
**10/10 real-kernel tc cases** with:

```bash
sudo bash tests/tc_netns_test.sh
```

The optional harness verifies a fresh network namespace differs from the parent
and initially contains only loopback. It makes mount propagation private, mounts
sysfs for that namespace, and uses only a newly created veth pair. It validates
real HTB/fq creation, repeat, rate update, clear/repeat, foreign-root preservation,
class/child/metadata failures, external class drift, and deleted-tree stale cleanup.
No host interface is selected, and no real sysctl write/reload is performed.

The real-kernel run exposed an implicit HTB pfifo leaf absent from qdisc dumps;
the implementation now accepts this known intermediate state, with a corresponding
mock regression. Explicit pfifo dumps remain supported. The HTB quantum warning
from default r2q remains visible; this work does not tune throughput or benchmark.
Kernel/iproute2 versions and raw outputs are retained with the acceptance logs.
These checks prove the tested tc paths on one Ubuntu host kernel, not Debian,
production traffic, reboot, all failure modes, or real sysctl acceptance.

## Transaction and ownership limits

See [tuning rules](tuning-rules.md#transaction-and-recovery-boundaries) for exact
rollback, journal inspection, permissions and legacy-state handling.

- Only the managed sysctl file and protected FlareTuner state are written.
- Equal external declarations are allowed, differing/uncertain declarations refuse.
- First tc apply requires an unshaped noqueue root. There is no arbitrary qdisc
  restoration; uncertain state is retained for manual recovery.
- Protected fingerprints and identity detect drift; they are not kernel ownership
  tags. A privileged external writer can race checks or create an identical tree.
- Rollback verifies saved managed runtime and file state; broad sysctl reload can
  affect unrelated settings outside the snapshot boundary.
- Multiple kernel commands are not atomic. Repeated signals, SIGKILL, disk errors
  or power loss can leave a journal and partial state. New mutations then refuse.
- New metadata is private and versioned by its required evidence fields. Older
  metadata without the necessary ownership/runtime evidence is never automatically
  upgraded into permission to delete or restore resources.

## Disposable VPS acceptance still needed

Use a disposable Debian or Ubuntu VM with console access and no production SSH
or application traffic. Keep original tc/sysctl inventories and use an isolated
veth pair/network namespace when supported. Confirm required capabilities before
any mutation. Do not run shaping against a production host interface.

Validate first apply from noqueue, all generated sysctl runtime values, identical
repeat, class-rate update, clear/repeat, reboot metadata cleanup, and preservation
of a deliberately installed foreign queue/filter. Observe actual iproute2 output
and the automatic HTB pfifo leaf on supported target versions. Inject failures
and interrupts only in the disposable environment; inspect journal retention,
rollback values and nonzero results. Verify both Debian and Ubuntu loading paths,
including a sysctl.conf symlink and a conflicting sing-box-vps-style BBR declaration.
The ten isolated tc checks above passed; broader disposable-VPS and real sysctl
acceptance remains outstanding.

## v0.3.0 CLI and sing-box-vps follow-ups

Keep a small noninteractive command set for preview, status, apply, restore, tc
apply and tc clear. Define exit codes for conflict, drift, operation failure and
recovery-required separately; introduce a versioned machine-readable status
schema after stabilizing the underlying operations. Require explicit mutation
inputs, keep preview read-only, and expose journal identifiers rather than an
unsafe generic force/recover option. No such API is added in this candidate.

Before sing-box-vps adoption, coordinate its legacy sysctl.conf BBR/fq declarations
and service reloads explicitly. Equal values today do not transfer ownership;
differing values block FlareTuner. Any migration must belong to a separately
approved cross-project design with backups and rollback proof. Coordinate locks,
root qdisc ownership, private state and exit-code handling, and retain the current
runtime-only reboot behavior. Never invoke restore/delete based only on old
sing-box-vps or FlareTuner metadata.
