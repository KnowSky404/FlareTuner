# FlareTuner Tuning Rules

FlareTuner's first script version targets Debian and Ubuntu VPS servers using standard Linux BBR and `fq`. It does not install kernels, replace congestion control modules, tune BBRv2, or run benchmarks.

## Inputs

The generated configuration is based on six interactive inputs:

- Workload: `web`, `proxy`, `download`, or `low-memory`.
- Memory tier: `under-512m`, `512m-1g`, `1g-4g`, or `4g-plus`.
- Bandwidth tier: `under-100m`, `100m-500m`, `500m-1g`, or `1g-plus`.
- Tuning profile: `conservative`, `balanced`, or `aggressive`.
- Path profile: `normal`, `high-latency`, or `qos-sensitive`.
- Optional target bandwidth in Mbps, or `auto`.

FlareTuner preselects recommended defaults before prompting. It reads `/proc/meminfo` to classify memory and reads numeric `/sys/class/net/*/speed` values, excluding loopback, to classify bandwidth. If memory cannot be read, it defaults to `512m-1g`. If interface speed cannot be read, it defaults to `under-100m`.

The recommendation rule stays conservative:

- `under-512m` memory recommends `low-memory` with the `conservative` profile.
- `1g-plus` bandwidth with more than 1 GiB memory recommends `download` with the `balanced` profile.
- Other detected combinations recommend `web` with the `conservative` profile.

Users can press Enter to accept each recommendation or select a different menu option. FlareTuner does not run speed tests or contact cloud provider metadata services.

The optional target bandwidth value maps to the same bandwidth tiers used by the rest of the profile. It does not enforce a traffic cap. It only guides sysctl profile generation. Real per-route or per-user rate limiting requires a separate traffic control layer such as application-level limits or `tc`.

## Baseline Settings

Every generated profile includes:

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

`fq` pairs with standard BBR because BBR depends on packet pacing to control send timing. The fair queue scheduler provides kernel pacing support and per-flow fairness, which makes it a practical default queue discipline for BBR on supported Linux systems.

## Memory Safety

Low-memory systems can become unstable if socket buffer ceilings are raised too far. Memory tier selection sets the starting receive and send buffer limits, but later bandwidth and workload choices can raise those limits for throughput-oriented profiles.

The `low-memory` workload is the safety override that runs after the other inputs. It enforces smaller bounded values for buffers, connection queues, and network device backlog.

## Workload Behavior

The `web` workload raises connection backlog values with `net.core.somaxconn` and `net.ipv4.tcp_max_syn_backlog` while keeping socket buffers moderate.

The `proxy` workload raises `net.core.netdev_max_backlog` to give the network device queue more room during bursts.

The `download` workload raises socket buffer ceilings with `net.core.rmem_max`, `net.core.wmem_max`, `net.ipv4.tcp_rmem`, and `net.ipv4.tcp_wmem` for higher throughput profiles.

The `low-memory` workload takes priority over throughput-oriented choices by bounding socket buffers, connection backlog values, and network device backlog to smaller values.

## Path Behavior

The `normal` path profile leaves the workload, memory, bandwidth, and tuning profile rules unchanged.

The `high-latency` path profile is intended for cross-region or high-RTT paths. It allows moderate socket buffer growth when memory is sufficient, because higher RTT increases bandwidth-delay product.

The `qos-sensitive` path profile is intended for routes where bursts or sustained throughput above a threshold appear to trigger throttling. It keeps socket buffers, connection backlog values, and device backlog more conservative. This can reduce aggressive buffering, but it does not shape traffic or guarantee that throughput remains under a provider or network QoS threshold.

## Sysctl Source Ownership

FlareTuner inventories `/etc/sysctl.d`, `/run/sysctl.d`,
`/usr/local/lib/sysctl.d`, `/usr/lib/sysctl.d`, and `/lib/sysctl.d`.
For equal basenames, the first directory wins; selected files are sorted in
C lexicographic order. A symlink to `/dev/null` masks a lower-priority file.
Procps `sysctl --system` also loads `/etc/sysctl.conf` last. Systemd-sysctl
uses sysctl.d files and does not read sysctl.conf directly; Debian/Ubuntu may
supply a sysctl.d symlink to it. Boot services, unit overrides, and later
privileged writers can change the outcome. A filename alone proves no final
runtime value.

Sources: [procps sysctl(8)](https://man7.org/linux/man-pages/man8/sysctl.8.html)
and [systemd sysctl.d](https://github.com/systemd/systemd/blob/main/man/sysctl.d.xml).

The scanner distinguishes no overlap, equal literal assignments, different
assignments, tool-management markers, and unknown sources/syntax. Valid exclusion
rules unrelated to managed keys are ignored; relevant exclusions remain uncertain. Slash aliases
of the managed keys and optional leading assignment `-` are normalized.
Management markers are diagnostic hints, not proof of the other tool's identity.

A different assignment in any selected file refuses apply, even if another
selected file would override it today. Relevant globs, relevant exclusions/unknown syntax,
unreadable files, aliases of the managed file, and vendor files with the reserved
`99-flaretuner.conf` basename also refuse apply. Equal literal declarations are
reported and allowed. This deliberately avoids relying on a particular boot
loader to settle disagreements; it does not implement an arbitrary sysctl parser
or claim to predict all future writers. Files masked by higher-priority basenames
are not treated as loaded declarations.

The managed path must be absent or a trusted regular file with the FlareTuner
header. Once new backup metadata exists, its applied digest must still match.
A sing-box-vps declaration in `/etc/sysctl.conf` is reported in the same way:
equal is allowed, different refuses apply. FlareTuner never deletes or takes over
those declarations. No cross-project migration is implemented.

Apply snapshots all ten generated runtime keys before publication. Success
requires every active value to match, including queues and TCP buffer triples.
Identical file and runtime values skip publication, backup, module loading, and
reload. Runtime drift requires a verified apply; file drift refuses overwrite.
The tuning numbers and profile mapping are unchanged.

## Traffic Control Limits

The limiter remains interface-wide egress HTB plus fq, root-only, runtime-only,
and Debian/Ubuntu-only. No ingress, IFB, per-user, per-destination, persistence,
or application-account policy is added. Rates are integer Mbps, 1 to 9999999;
leading zeros are rejected to avoid ambiguous shell arithmetic.

Before any kernel mutation, FlareTuner verifies the interface exists, reads its
ifindex and boot identity, and inspects qdiscs, classes, and filters at root and
the managed parents. First apply accepts only one `noqueue 0:` root with no
classes/filters. Existing fq, fq_codel, mq, CAKE, HTB, ingress/clsact, custom
classes, and uncertain queues are refused, even when some might be kernel defaults.
There is no generic qdisc serializer or automatic external-policy restoration.

Creation uses root `add`, class `add`, then attaches fq to the new class. Linux
HTB automatically creates a pfifo leaf for a new class; only the default leaf of that newly created, verified
class is replaced; kernels may omit an implicit handle-zero leaf
from qdisc dumps. Both absent and explicit pfifo intermediate dumps are accepted
only in the fresh owned class. Every command and intermediate topology is
checked. Unknown output or a command that fails after changing state retains
a recovery journal rather than deleting an unverified root. This intermediate
behavior is derived from [Linux HTB](https://github.com/torvalds/linux/blob/master/net/sched/sch_htb.c)
and has been checked by the optional isolated tc kernel harness on Ubuntu.

After full verification, metadata records interface, rate, boot/ifindex identity,
and a SHA-256 fingerprint of the normalized qdisc/class/filter configuration.
Volatile HTB direct-packet and qdisc reference counters are excluded. Metadata
is published atomically with mode 600. The fingerprint is a protected local
ownership record, not a kernel owner tag or cryptographic proof against root.

A matching repeat changes nothing. An update preserves the root/fq topology
and changes only the owned HTB class. Failure restores the previous class rate
only when the last verified full fingerprint still matches, then verifies the
previous fingerprint. A failed first apply deletes only a last-verified owned
partial tree and checks the original baseline afterward. Metadata commit failure
uses the same recovery path.

Clear compares identity, shape, rate, fingerprint, and filters before deleting
`root handle 1:`. A missing interface or a lone default handle-zero root with no
classes/filters permits metadata-only stale cleanup. This handles reboot and
externally deleted queues without deleting their replacement. Other changed
queues/classes/filters refuse clear/update and retain metadata. Repeated clear
is harmless. Clear the old interface before applying to another interface.
Legacy two-field metadata cannot establish ownership and requires manual inspection.

## Transaction and Recovery Boundaries

Paths remain:

- Managed configuration: `/etc/sysctl.d/99-flaretuner.conf`.
- Latest sysctl backup metadata: `/var/lib/flaretuner/latest-backup.env`.
- Unique config/runtime snapshots: `/var/lib/flaretuner/backup/`.
- Latest tc metadata: `/var/lib/flaretuner/tc-limit.env`.
- Shared lock: `/var/lib/flaretuner/.lock`.
- Private in-flight/recovery journal: `/var/lib/flaretuner/transaction.*`.

Use local storage for state and a filesystem supporting `flock` and atomic rename.
Mutation paths and their ancestors must be root-owned and not group/world writable;
symlinks, special files, and multiply linked regular files are rejected. A sticky
`/tmp` ancestor is allowed for isolated tests. New files use mode 600, new state
and transaction directories use mode 700, and backup names use `mktemp`.
Existing root-owned non-writable directories may retain mode 755.

Mutations share one nonblocking lock, so sysctl apply/restore and tc apply/clear
cannot race each other. Config and metadata use same-directory temporary files
and rename. SIGINT, SIGTERM, and SIGHUP exit through guarded recovery. Bash does
not provide a kernel transaction: each tc/sysctl command is a separate operation.
There is no fsync/power-loss durability guarantee. SIGKILL or power loss can leave
a journal, temporary files, and partial state; the next mutation refuses to run.

Sysctl failure recovery checks the written managed digest, selected source
fingerprint, and current key values against the intended and saved values.
Unexpected external changes refuse rollback. Otherwise it restores/removes the
managed file, reloads `sysctl --system`, reapplies saved managed runtime values,
and verifies them. A reload error is recorded but does not skip guarded restoration
of saved managed values; the journal is retained and the operation returns failure.
It does not restore unrelated kernel keys, unloaded modules,
or arbitrary effects of a broad reload. Restore similarly validates snapshot
paths/digests, current file/runtime ownership, and source conflicts before acting;
a failed restore attempts to recover the pre-restore state. A successful restore
consumes latest metadata, retaining historical snapshot files.

Errors return nonzero; unsafe/failed recovery returns 2 from the operation.
The interactive menu remembers failures/cancellations and exits nonzero even if
the user subsequently selects Exit. It keeps all seven existing menu choices.

If recovery is unsafe or fails, do not blindly delete the journal or run a root
qdisc deletion. As root, inspect the reported journal, `show status`, current
sysctl sources/runtime, and `tc qdisc/class/filter show` for the recorded interface.
Compare before/current snapshots, operation, intended config, runtime snapshots,
and metadata. Resolve the discrepancy manually during an appropriate maintenance
window; for tc there may be no safely reconstructable previous external tree.
After independently verifying the desired managed and runtime state, archive the
journal and recovery evidence outside the `transaction.*` pattern. Only then can
new mutations proceed. No automatic recovery command is provided in this version.

Checks narrow races with unrelated privileged writers but cannot eliminate the
read/check/write window or identify an identical external replacement. Coordinate
network management tools; the FlareTuner lock is cooperative, not a host-wide lock.
Read-only status does not acquire the mutation lock and can observe an in-flight
transition. Missing permissions or unsupported output is reported as unknown or
invalid state, never as an active verified limit.

## Status and Validation

Status separates current TCP congestion control, BBR availability/module state,
the system default qdisc parameter, managed file presence/runtime agreement,
source conflicts, managed-file digest drift, backup metadata, recorded tc metadata, actual device qdisc,
active/stale/drifted tc state, and unfinished journals. A default of fq does not
assert that device roots are fq. Private metadata may require root to inspect;
preview remains read-only and never loads a module.

The required syntax checks and shell suite run with isolated directory/command
overrides. `FLARETUNER_SYSCTL_ROOT` redirects runtime/vendor source directories;
`FLARETUNER_BOOT_ID` redirects boot identity and `FLARETUNER_STAT_CMD` permits
mocking root ownership while preserving real modes/link counts in fixtures, alongside existing
etc/state/sysfs/sysctl/tc overrides. No mock invokes host sysctl writes or changes
host qdiscs. The optional root-only `tests/tc_netns_test.sh` separately validates
ten real tc paths inside a guarded fresh network/mount namespace with a private
veth pair; it never performs a real sysctl reload. See [runtime safety report](runtime-safety-v020.md) for the evidence
boundary and the remaining disposable-VPS acceptance.
