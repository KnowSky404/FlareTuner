#!/usr/bin/env bash
# Optional real-kernel acceptance; every tc mutation is inside a fresh netns.
set -euo pipefail

[[ "$(id -u)" == 0 ]] || { echo 'This isolated test requires root.' >&2; exit 1; }
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/flaretuner.sh"
for dependency in unshare ip tc mount umount; do command -v "$dependency" >/dev/null; done
kernel_tmp="$(mktemp -d)"
cleanup() {
  local status=$?
  if [[ "$status" == 0 ]]; then rm -r -- "$kernel_tmp";
  else echo "Failed test scratch retained: $kernel_tmp" >&2; fi
}
trap cleanup EXIT
parent_netns="$(readlink /proc/self/ns/net)"
unshare --mount --net bash -s -- "$SCRIPT" "$kernel_tmp" "$parent_netns" <<'NETNS'
set -euo pipefail
script="$1"; scratch="$2"; parent_netns="$3"
[[ "$(readlink /proc/self/ns/net)" != "$parent_netns" ]] || exit 1
[[ "$(ip -o link show | wc -l)" == 1 ]] || exit 1
ip link show dev lo >/dev/null
mount --make-rprivate /
mkdir "$scratch/sysfs"
mount -t sysfs sysfs "$scratch/sysfs"
trap 'umount "$scratch/sysfs"' EXIT
ip link add ft-test0 type veth peer name ft-peer0
ip link set ft-test0 up
ip link set ft-peer0 up
mkdir -p "$scratch/etc/sysctl.d"
FLARETUNER_TESTING=1 FLARETUNER_ETC_DIR="$scratch/etc" \
  FLARETUNER_STATE_DIR="$scratch/state" FLARETUNER_NET_CLASS_DIR="$scratch/sysfs/class/net" \
  FLARETUNER_OS_RELEASE=/etc/os-release FLARETUNER_STAT_CMD=stat \
  FLARETUNER_ID_CMD=id FLARETUNER_TC_CMD=tc \
  FLARETUNER_BOOT_ID=/proc/sys/kernel/random/boot_id source "$script"

passed=0
ok() { passed=$((passed + 1)); echo "kernel ok $passed - $*"; }
expect_failure() { if ( "$@" ); then echo "Unexpected success: $*" >&2; exit 1; fi; }
assert_default() { read_tc_state ft-test0; tc_initial_state; }
assert_clean() {
  local pending=("$STATE_DIR"/transaction.*)
  [[ ! -e "${pending[0]}" && ! -e "$TC_LIMIT_FILE" ]]
}

apply_tc_egress_limit ft-test0 90
load_tc_limit_metadata
read_tc_state ft-test0
tc_owned_state
printf '%s\n%s\n' "$LIVE_QDISC" "$LIVE_CLASS"
ok 'first apply and real HTB/fq output verification'

before_metadata="$(file_hash "$TC_LIMIT_FILE")"
before_runtime="$LIVE_HASH"
apply_tc_egress_limit ft-test0 90
[[ "$(file_hash "$TC_LIMIT_FILE")" == "$before_metadata" ]]
read_tc_state ft-test0
[[ "$LIVE_HASH" == "$before_runtime" ]]
ok 'identical repeat preserves metadata and runtime'

apply_tc_egress_limit ft-test0 80
load_tc_limit_metadata
read_tc_state ft-test0
tc_owned_state
[[ "$PARSED_TC_RATE_MBPS" == 80 ]]
ok 'owned rate update'

clear_tc_egress_limit
clear_tc_egress_limit
assert_default
assert_clean
ok 'clear and repeated clear restore noqueue'

command tc qdisc add dev ft-test0 root handle 2: htb default 20
read_tc_state ft-test0
foreign_hash="$LIVE_HASH"
expect_failure apply_tc_egress_limit ft-test0 90
read_tc_state ft-test0
[[ "$LIVE_HASH" == "$foreign_hash" ]]
command tc qdisc del dev ft-test0 root handle 2:
ok 'foreign root is preserved'

fail_class_add() {
  if [[ "$1 $2" == 'class add' ]]; then return 1; fi
  command tc "$@"
}
TC_CMD=fail_class_add
expect_failure apply_tc_egress_limit ft-test0 90
TC_CMD=tc
assert_default
assert_clean
ok 'class creation failure removes only the new owned root'

fail_child_replace() {
  if [[ "$1 $2" == 'qdisc replace' ]]; then return 1; fi
  command tc "$@"
}
TC_CMD=fail_child_replace
expect_failure apply_tc_egress_limit ft-test0 90
TC_CMD=tc
assert_default
assert_clean
ok 'child attach failure recovers real automatic pfifo intermediate state'

eval "$(declare -f atomic_publish | sed '1s/atomic_publish/saved_atomic_publish/')"
atomic_publish() {
  [[ "$2" != "$TC_LIMIT_FILE" ]] || return 1
  saved_atomic_publish "$@"
}
expect_failure apply_tc_egress_limit ft-test0 90
assert_default
assert_clean
eval "$(declare -f saved_atomic_publish | sed '1s/saved_atomic_publish/atomic_publish/')"
ok 'metadata commit failure recovers live kernel tree'

apply_tc_egress_limit ft-test0 90
command tc class change dev ft-test0 parent 1: classid 1:10 htb rate 70mbit ceil 70mbit
read_tc_state ft-test0
drift_hash="$LIVE_HASH"
expect_failure clear_tc_egress_limit
expect_failure apply_tc_egress_limit ft-test0 80
read_tc_state ft-test0
[[ "$LIVE_HASH" == "$drift_hash" ]]
ok 'external class drift blocks clear and update'

# This tree was created by this test and exists only in this netns.
command tc qdisc del dev ft-test0 root handle 1:
clear_tc_egress_limit
assert_default
assert_clean
ok 'externally deleted tree causes metadata-only cleanup'

echo "Passed $passed isolated real-kernel tc cases"
NETNS
