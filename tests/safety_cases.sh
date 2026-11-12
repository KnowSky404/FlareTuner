# Stateful isolated fixtures for the runtime safety regressions.
safety_fixture() {
  safety_root="$(mktemp -d "$TEST_TMP_DIR/safety.XXXXXX")"
  mkdir -p "$safety_root/etc/sysctl.d" "$safety_root/state" "$safety_root/net/eth0" "$safety_root/net/eth1" "$safety_root/bin" "$safety_root/runtime"
  printf 'ID=debian\n' >"$safety_root/os-release"
  printf 'test-boot\n' >"$safety_root/boot-id"
  printf '2\n' >"$safety_root/net/eth0/ifindex"
  printf '3\n' >"$safety_root/net/eth1/ifindex"
  export SAFETY_ROOT="$safety_root"
  cat >"$safety_root/bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
set -eu
r="$SAFETY_ROOT"
echo "$*" >>"$r/sysctl.log"
case "$1" in
  -n)
    if [[ "$2" == net.ipv4.tcp_available_congestion_control ]]; then echo 'reno cubic bbr'; exit; fi
    cat "$r/runtime/$2" ;;
  --system)
    [[ ! -f "$r/fail-system" ]] || exit 1
    if [[ -f "$r/etc/sysctl.d/99-flaretuner.conf" ]]; then
    while read -r key eq value; do
      [[ "$key" == net.* && "$eq" == = ]] || continue
      [[ ! -f "$r/skip-key" || "$key" != "$(cat "$r/skip-key")" ]] || continue
      printf '%s\n' "$value" >"$r/runtime/$key"
    done <"$r/etc/sysctl.d/99-flaretuner.conf"
    fi
    if [[ -f "$r/drift-runtime-system" ]]; then echo reno >"$r/runtime/net.ipv4.tcp_congestion_control"; exit 1; fi
    if [[ -f "$r/remove-config-system" ]]; then rm "$r/etc/sysctl.d/99-flaretuner.conf"; exit 1; fi
    if [[ -f "$r/drift-config" ]]; then echo '# external modification' >>"$r/etc/sysctl.d/99-flaretuner.conf"; exit 1; fi
    if [[ -f "$r/signal-system" ]]; then sig="$(cat "$r/signal-system")"; rm "$r/signal-system"; kill -"$sig" "$PPID"; fi
    if [[ -f "$r/fail-after-system" ]]; then exit 1; fi
    if [[ -f "$r/fail-once-system" ]]; then rm "$r/fail-once-system"; exit 1; fi
    if [[ -f "$r/hold" ]]; then touch "$r/ready"; read -r _ <"$r/release"; fi
    ;;
  -w)
    if [[ -f "$r/fail-write-key" && "${2%%=*}" == "$(cat "$r/fail-write-key")" ]]; then exit 1; fi
    printf '%s\n' "${2#*=}" >"$r/runtime/${2%%=*}" ;;
  *) exit 1 ;;
esac
MOCK
  cat >"$safety_root/bin/tc" <<'MOCK'
#!/usr/bin/env bash
set -eu
r="$SAFETY_ROOT"
echo "$*" >>"$r/tc.log"
iface="$4"
q="$r/$iface.qdisc"; c="$r/$iface.class"
case "$1 $2" in
 'qdisc show') cat "$q" ;;
 'class show') cat "$c" ;;
 'filter show') [[ ! -f "$r/foreign-filter" ]] || echo 'filter parent 1: protocol ip pref 1 bpf'; exit 0 ;;
 *)
    step="$(cat "$r/step")"; step=$((step + 1)); echo "$step" >"$r/step"
    [[ ! -f "$r/fail-step" || "$step" != "$(cat "$r/fail-step")" ]] || exit 1
    case "$1 $2" in
      'qdisc add'|'qdisc replace')
        if [[ "$5" == root ]]; then
          echo 'qdisc htb 1: root refcnt 2 r2q 10 default 0x10 direct_packets_stat 0 direct_qlen 1000' >"$q"
        else sed -i '/qdisc pfifo /d' "$q"; echo 'qdisc fq 10: parent 1:10 limit 10000p flow_limit 100p buckets 1024 orphan_mask 1023 quantum 3028b initial_quantum 15140b low_rate_threshold 550Kbit refill_delay 40ms' >>"$q"; fi ;;
      'class add'|'class change')
        echo "class htb 1:10 root rate ${11%mbit}Mbit ceil ${13%mbit}Mbit burst 1600b cburst 1600b" >"$c"
        if [[ "$2" == add && ! -f "$r/hide-pfifo" ]]; then echo 'qdisc pfifo 8001: parent 1:10 limit 1000p' >>"$q"; fi ;;
      'qdisc del')
        [[ ! -f "$r/fail-delete" ]] || exit 1
        echo 'qdisc noqueue 0: root refcnt 2' >"$q"; : >"$c"
        if [[ "$2" == add && ! -f "$r/hide-pfifo" ]]; then echo 'qdisc pfifo 8001: parent 1:10 limit 1000p' >>"$q"; fi ;;
      *) exit 1 ;;
    esac
    if [[ -f "$r/drift-step" && "$step" == "$(cat "$r/drift-step")" ]]; then echo 'qdisc cake 8001: root bandwidth unlimited' >"$q"; exit 1; fi
    if [[ -f "$r/signal-step" && "$step" == "$(cat "$r/signal-step")" ]]; then rm "$r/signal-step"; kill -TERM "$PPID"; fi
    ;;
esac
MOCK
  chmod +x "$safety_root/bin/"*
  printf '0\n' >"$safety_root/step"
  for iface in eth0 eth1; do
    printf 'qdisc noqueue 0: root refcnt 2\n' >"$safety_root/$iface.qdisc"
    : >"$safety_root/$iface.class"
  done
  FLARETUNER_TESTING=1 FLARETUNER_ETC_DIR="$safety_root/etc" \
    FLARETUNER_SYSCTL_ROOT="$safety_root" FLARETUNER_STATE_DIR="$safety_root/state" \
    FLARETUNER_OS_RELEASE="$safety_root/os-release" FLARETUNER_NET_CLASS_DIR="$safety_root/net" \
    FLARETUNER_BOOT_ID="$safety_root/boot-id" FLARETUNER_SYSCTL_CMD="$safety_root/bin/sysctl" \
    FLARETUNER_ID_CMD=fixture_root_id FLARETUNER_TC_CMD="$safety_root/bin/tc" source "$SCRIPT"
  safety_config="$(render_config web 1g-4g 100m-500m balanced)"
  while read -r key eq value; do
    [[ "$key" == net.* && "$eq" == = ]] || continue
    printf '%s\n' "$value" >"$safety_root/runtime/$key"
  done <<<"$safety_config"
}

must_fail() {
  local result
  if result="$( ( "$@" ) 2>&1)"; then fail "expected failure: $* ($result)"; fi
  safety_error="$result"
}

test_safety_sysctl_conflict() {
  safety_fixture
  echo 'net/core/default_qdisc = cake' >"$safety_root/etc/sysctl.conf"
  must_fail apply_config "$safety_config"
  [[ ! -e "$MANAGED_CONF" && ! -e "$LATEST_BACKUP_FILE" ]] || fail 'conflict wrote managed state'
  assert_contains "$safety_error" 'different' 'conflict diagnostic'
}

test_safety_tc_foreign() {
  safety_fixture
  echo 'qdisc cake 8001: root bandwidth unlimited' >"$safety_root/eth0.qdisc"
  must_fail apply_tc_egress_limit eth0 90
  assert_equals "$(cat "$safety_root/step")" 0 'no tc mutations on foreign root'
}

mock_profile_value() {
  render_config web 1g-4g 100m-500m balanced | awk -v key="$1" '$1==key {sub(/^[^=]*= */, ""); print}'
}

seed_restore_evidence() {
  # New backups must carry the applied digest and the saved runtime snapshot.
  render_config web 1g-4g 100m-500m balanced >"$MANAGED_CONF"
  mkdir -p "$BACKUP_DIR"
  render_config web 1g-4g 100m-500m balanced >"$BACKUP_DIR/runtime.test"
  printf 'APPLIED_HASH=%s\nRUNTIME_PATH=%s\nRUNTIME_HASH=%s\n' "$(sha256sum "$MANAGED_CONF" | cut -d ' ' -f 1)" "$BACKUP_DIR/runtime.test" "$(sha256sum "$BACKUP_DIR/runtime.test" | cut -d ' ' -f 1)" >>"$LATEST_BACKUP_FILE"
  local previous_backup
  previous_backup="$(sed -n 's/^BACKUP_PATH=//p' "$LATEST_BACKUP_FILE")"
  printf 'BACKUP_HASH=%s\n' "$(if [[ -n "$previous_backup" ]]; then sha256sum "$previous_backup" | cut -d ' ' -f 1; else echo absent; fi)" >>"$LATEST_BACKUP_FILE"
}

assert_no_journal() {
  local journals=("$STATE_DIR"/transaction.*)
  [[ ! -e "${journals[0]}" ]] || fail 'unexpected unfinished transaction'
}

assert_retained_journal() {
  local journals=("$STATE_DIR"/transaction.*)
  [[ -f "${journals[0]}/operation" ]] || fail 'missing recovery journal'
  must_fail clear_tc_egress_limit
  assert_contains "$safety_error" 'unfinished transaction' 'recovery gate'
}

test_safety_sysctl_same_and_masking() {
  safety_fixture
  mkdir -p "$safety_root/usr/lib/sysctl.d" "$safety_root/run/sysctl.d"
  echo 'net.core.default_qdisc = cake' >"$safety_root/usr/lib/sysctl.d/10-vendor.conf"
  printf '# Managed by sing-box-vps\nnet.core.default_qdisc = fq\n' >"$safety_root/etc/sysctl.d/10-vendor.conf"
  echo 'net.ipv4.tcp_congestion_control = bbr' >"$safety_root/etc/sysctl.conf"
  local output
  output="$(apply_config "$safety_config")"
  assert_contains "$output" 'same net.core.default_qdisc (tool-managed:' 'tool ownership classification'
  assert_contains "$output" 'same net.ipv4.tcp_congestion_control' 'sysctl.conf equal declaration'
  assert_file_contains "$safety_root/usr/lib/sysctl.d/10-vendor.conf" cake 'masked vendor preserved'
}

test_safety_sysctl_sources() {
  local dir
  for dir in run usr/local/lib usr/lib lib; do
    safety_fixture
    mkdir -p "$safety_root/$dir/sysctl.d"
    echo 'net.ipv4.tcp_congestion_control = cubic' >"$safety_root/$dir/sysctl.d/00-before.conf"
    must_fail apply_config "$safety_config"
    [[ ! -e "$MANAGED_CONF" ]] || fail "source $dir was ignored"
    assert_contains "$safety_error" "$dir/sysctl.d/00-before.conf" 'source path reported'
  done
}

test_safety_sysctl_unknown() {
  local syntax
  for syntax in 'net.ipv4.tcp_* = 1' '-net.ipv4.tcp_congestion_control' 'unrecognized syntax'; do
    safety_fixture
    echo "$syntax" >"$safety_root/etc/sysctl.d/90-unknown.conf"
    must_fail apply_config "$safety_config"
    [[ ! -e "$MANAGED_CONF" ]] || fail 'uncertain source was accepted'
  done
}

test_safety_sysctl_mask_and_reserved() {
  safety_fixture
  mkdir -p "$safety_root/usr/lib/sysctl.d"
  echo 'net.core.default_qdisc = cake' >"$safety_root/usr/lib/sysctl.d/10-masked.conf"
  ln -s /dev/null "$safety_root/etc/sysctl.d/10-masked.conf"
  apply_config "$safety_config"
  echo '# foreign config' >"$safety_root/usr/lib/sysctl.d/99-flaretuner.conf"
  must_fail apply_config "$safety_config"
  assert_contains "$safety_error" 'reserved basename' 'basename shadowing rejected'
}

test_safety_sysctl_idempotent() {
  safety_fixture
  apply_config "$safety_config"
  local before metadata_count
  before="$(stat -c '%i:%Y' "$MANAGED_CONF")"
  cp "$LATEST_BACKUP_FILE" "$safety_root/metadata.before"
  metadata_count="$(find "$BACKUP_DIR" -type f | wc -l)"
  : >"$safety_root/sysctl.log"
  apply_config "$safety_config"
  assert_equals "$(stat -c '%i:%Y' "$MANAGED_CONF")" "$before" 'no config publication on repeat'
  cmp -s "$LATEST_BACKUP_FILE" "$safety_root/metadata.before" || fail 'repeat replaced backup metadata'
  assert_equals "$(find "$BACKUP_DIR" -type f | wc -l)" "$metadata_count" 'no repeat backup'
  if grep -q -- '--system' "$safety_root/sysctl.log"; then fail 'repeat reloaded sysctl'; fi
}

test_safety_sysctl_full_verification() {
  safety_fixture
  echo 1234 >"$safety_root/runtime/net.core.rmem_max"
  echo net.core.rmem_max >"$safety_root/skip-key"
  must_fail apply_config "$safety_config"
  [[ ! -e "$MANAGED_CONF" && ! -e "$LATEST_BACKUP_FILE" ]] || fail 'verification failure committed configuration'
  assert_equals "$(cat "$safety_root/runtime/net.core.rmem_max")" 1234 'runtime restored'
  assert_no_journal
}

test_safety_sysctl_partial_failure() {
  safety_fixture
  echo cubic >"$safety_root/runtime/net.ipv4.tcp_congestion_control"
  touch "$safety_root/fail-once-system"
  must_fail apply_config "$safety_config"
  assert_equals "$(cat "$safety_root/runtime/net.ipv4.tcp_congestion_control")" cubic 'partial reload restored runtime snapshot'
  [[ ! -e "$MANAGED_CONF" && ! -e "$LATEST_BACKUP_FILE" ]] || fail 'failed apply committed state'
  assert_no_journal
}

test_safety_sysctl_reload_rollback_failure() {
  safety_fixture
  touch "$safety_root/fail-system"
  must_fail apply_config "$safety_config"
  assert_contains "$safety_error" 'Recovery incomplete' 'rollback failure distinct'
  assert_retained_journal
}

test_safety_sysctl_external_drift() {
  safety_fixture
  touch "$safety_root/drift-config"
  must_fail apply_config "$safety_config"
  assert_file_contains "$MANAGED_CONF" 'external modification' 'rollback preserves external config'
  assert_retained_journal
}

test_safety_restore_roundtrip() {
  safety_fixture
  echo cubic >"$safety_root/runtime/net.ipv4.tcp_congestion_control"
  apply_config "$safety_config"
  restore_latest_backup
  [[ ! -e "$MANAGED_CONF" && ! -e "$LATEST_BACKUP_FILE" ]] || fail 'restore did not remove first applied state'
  assert_equals "$(cat "$safety_root/runtime/net.ipv4.tcp_congestion_control")" cubic 'restore pre-apply runtime'
}

test_safety_restore_rejects_drift_and_corruption() {
  local damage
  for damage in config runtime backup symlink metadata; do
    safety_fixture
    apply_config "$safety_config"
    load_backup_metadata
    case "$damage" in
      config) echo '# external change' >>"$MANAGED_CONF" ;;
      runtime) echo cubic >"$safety_root/runtime/net.ipv4.tcp_congestion_control" ;;
      backup) echo 'bad backup' >"$PARSED_RUNTIME_PATH" ;;
      symlink) mv "$PARSED_RUNTIME_PATH" "$safety_root/real-runtime"; ln -s "$safety_root/real-runtime" "$PARSED_RUNTIME_PATH" ;;
      metadata) echo 'EXTRA=$(touch bad)' >>"$LATEST_BACKUP_FILE" ;;
    esac
    cp "$MANAGED_CONF" "$safety_root/before-restore"
    : >"$safety_root/sysctl.log"
    must_fail restore_latest_backup
    cmp -s "$MANAGED_CONF" "$safety_root/before-restore" || fail "restore overwrote drift: $damage"
    if grep -q -- '--system' "$safety_root/sysctl.log"; then fail "unsafe restore reloaded: $damage"; fi
  done
}

test_safety_filesystem_guards() {
  local attack
  for attack in config-link config-hardlink state-link state-mode foreign-owner metadata-link tc-link; do
    safety_fixture
    echo 'keep me' >"$safety_root/victim"
    case "$attack" in
      config-link) ln -s "$safety_root/victim" "$MANAGED_CONF" ;;
      config-hardlink) ln "$safety_root/victim" "$MANAGED_CONF" ;;
      state-link) rmdir "$STATE_DIR"; mkdir "$safety_root/outside"; ln -s "$safety_root/outside" "$STATE_DIR" ;;
      state-mode) chmod 777 "$STATE_DIR" ;;
      foreign-owner) fixture_nonroot_stat() { printf '1000 700 1\n'; }; STAT_CMD=fixture_nonroot_stat ;;
      metadata-link) ln -s "$safety_root/victim" "$LATEST_BACKUP_FILE" ;;
      tc-link) ln -s "$safety_root/victim" "$TC_LIMIT_FILE" ;;
    esac
    if [[ "$attack" == tc-link ]]; then must_fail apply_tc_egress_limit eth0 90; else must_fail apply_config "$safety_config"; fi
    assert_equals "$(cat "$safety_root/victim")" 'keep me' 'victim preserved'
    assert_equals "$(cat "$safety_root/step")" 0 'unsafe state never changes tc'
  done
}

test_safety_tc_steps_fail() {
  local step
  for step in 1 2 3; do
    safety_fixture
    echo "$step" >"$safety_root/fail-step"
    must_fail apply_tc_egress_limit eth0 90
    [[ ! -e "$TC_LIMIT_FILE" ]] || fail "step $step committed metadata"
    assert_file_contains "$safety_root/eth0.qdisc" 'noqueue 0:' "step $step rolled back kernel"
    [[ ! -s "$safety_root/eth0.class" ]] || fail "step $step left a class"
    assert_no_journal
  done
}

inject_commit_failure() {
  eval "$(declare -f atomic_publish | sed '1s/atomic_publish/original_atomic_publish/')"
  atomic_publish() {
    if [[ "$2" == "$TC_LIMIT_FILE" || "$2" == "$LATEST_BACKUP_FILE" ]]; then return 1; fi
    original_atomic_publish "$@"
  }
}

test_safety_tc_metadata_failure() {
  safety_fixture
  inject_commit_failure
  must_fail apply_tc_egress_limit eth0 90
  [[ ! -e "$TC_LIMIT_FILE" ]] || fail 'metadata failure committed tc metadata'
  assert_file_contains "$safety_root/eth0.qdisc" 'noqueue 0:' 'metadata failure removed our partial tc'
  assert_no_journal
}

test_safety_sysctl_metadata_failure() {
  safety_fixture
  inject_commit_failure
  must_fail apply_config "$safety_config"
  [[ ! -e "$LATEST_BACKUP_FILE" && ! -e "$MANAGED_CONF" ]] || fail 'metadata failure kept managed config'
  assert_no_journal
}

test_safety_tc_update_and_repeat() {
  safety_fixture
  apply_tc_egress_limit eth0 90
  cp "$TC_LIMIT_FILE" "$safety_root/metadata.before"
  apply_tc_egress_limit eth0 90
  assert_equals "$(cat "$safety_root/step")" 3 'repeat made no kernel mutations'
  cmp -s "$TC_LIMIT_FILE" "$safety_root/metadata.before" || fail 'repeat wrote metadata'
  apply_tc_egress_limit eth0 80
  assert_equals "$(cat "$safety_root/step")" 4 'update only changes owned class'
  assert_file_contains "$TC_LIMIT_FILE" 'RATE_MBPS=80' 'updated rate committed'
  assert_file_contains "$safety_root/eth0.class" 'rate 80Mbit' 'updated runtime rate'
  clear_tc_egress_limit
  clear_tc_egress_limit
  assert_equals "$(cat "$safety_root/step")" 5 'repeat clear never deletes again'
}

test_safety_tc_update_rollback() {
  safety_fixture
  apply_tc_egress_limit eth0 90
  cp "$TC_LIMIT_FILE" "$safety_root/metadata.before"
  inject_commit_failure
  must_fail apply_tc_egress_limit eth0 80
  assert_file_contains "$safety_root/eth0.class" 'rate 90Mbit' 'failed update restored prior class'
  cmp -s "$TC_LIMIT_FILE" "$safety_root/metadata.before" || fail 'failed update overwrote metadata'
  assert_no_journal
}

test_safety_tc_stale() {
  local stale
  for stale in reboot deleted absent; do
    safety_fixture
    apply_tc_egress_limit eth0 90
    echo 'qdisc noqueue 0: root refcnt 2' >"$safety_root/eth0.qdisc"; : >"$safety_root/eth0.class"
    if [[ "$stale" == reboot ]]; then echo new-boot >"$safety_root/boot-id"; fi
    if [[ "$stale" == absent ]]; then rm -r "$safety_root/net/eth0"; fi
    clear_tc_egress_limit
    assert_equals "$(cat "$safety_root/step")" 3 'stale metadata never causes root deletion'
    [[ ! -e "$TC_LIMIT_FILE" ]] || fail 'stale metadata not removed'
    clear_tc_egress_limit
  done
}

test_safety_tc_external_changes() {
  local change
  for change in root class child filter identity; do
    safety_fixture
    apply_tc_egress_limit eth0 90
    case "$change" in
      root) echo 'qdisc cake 1: root bandwidth unlimited' >"$safety_root/eth0.qdisc" ;;
      class) sed -i s/90Mbit/80Mbit/g "$safety_root/eth0.class" ;;
      child) sed -i s/'qdisc fq '/'qdisc fq_codel '/ "$safety_root/eth0.qdisc" ;;
      filter) touch "$safety_root/foreign-filter" ;;
      identity) echo 9 >"$safety_root/net/eth0/ifindex" ;;
    esac
    must_fail clear_tc_egress_limit
    must_fail apply_tc_egress_limit eth0 80
    assert_equals "$(cat "$safety_root/step")" 3 "no mutations after $change drift"
    [[ -e "$TC_LIMIT_FILE" ]] || fail 'drift lost diagnostic metadata'
  done
}

test_safety_tc_partial_drift_and_rollback_failure() {
  local damage
  for damage in drift delete; do
    safety_fixture
    if [[ "$damage" == drift ]]; then echo 2 >"$safety_root/drift-step";
    else echo 3 >"$safety_root/fail-step"; touch "$safety_root/fail-delete"; fi
    must_fail apply_tc_egress_limit eth0 90
    assert_retained_journal
    [[ ! -e "$TC_LIMIT_FILE" ]] || fail 'incomplete tc falsely committed metadata'
    if [[ "$damage" == drift ]]; then assert_file_contains "$safety_root/eth0.qdisc" cake 'foreign policy preserved during rollback'; fi
  done
}

test_safety_tc_interface_switch() {
  safety_fixture
  must_fail apply_tc_egress_limit missing0 90
  assert_equals "$(cat "$safety_root/step")" 0 'missing interface never mutated'
  apply_tc_egress_limit eth0 90
  must_fail apply_tc_egress_limit eth1 80
  assert_equals "$(cat "$safety_root/step")" 3 'switch refuses loss of previous ownership'
  clear_tc_egress_limit
  apply_tc_egress_limit eth1 80
  assert_file_contains "$TC_LIMIT_FILE" IFACE=eth1 'explicit clear permits interface switch'
}

test_safety_tc_legacy_and_corrupt_metadata() {
  local line
  for line in '' 'IFACE=eth0' 'EXTRA=bad' 'RATE_MBPS=0009'; do
    safety_fixture
    printf 'IFACE=eth0\nRATE_MBPS=90\n%s\n' "$line" >"$TC_LIMIT_FILE"
    must_fail clear_tc_egress_limit
    must_fail apply_tc_egress_limit eth0 90
    assert_equals "$(cat "$safety_root/step")" 0 'untrusted metadata never authorizes deletion'
  done
}

test_safety_sysctl_signals() {
  local sig
  for sig in INT TERM HUP; do
    safety_fixture
    echo cubic >"$safety_root/runtime/net.ipv4.tcp_congestion_control"
    echo "$sig" >"$safety_root/signal-system"
    must_fail apply_config "$safety_config"
    [[ ! -e "$MANAGED_CONF" && ! -e "$LATEST_BACKUP_FILE" ]] || fail "$sig committed sysctl state"
    assert_equals "$(cat "$safety_root/runtime/net.ipv4.tcp_congestion_control")" cubic "$sig restored runtime"
    assert_no_journal
  done
}

test_safety_tc_signal() {
  safety_fixture
  echo 2 >"$safety_root/signal-step"
  must_fail apply_tc_egress_limit eth0 90
  [[ ! -e "$TC_LIMIT_FILE" ]] || fail 'interrupted tc committed metadata'
  assert_retained_journal
  assert_contains "$safety_error" 'unfinished transaction' 'interrupted uncertain tc blocked'
}

test_safety_concurrency() {
  safety_fixture
  touch "$safety_root/hold"
  mkfifo "$safety_root/release"
  apply_config "$safety_config" >"$safety_root/first.log" 2>&1 &
  local first=$! n
  for n in {1..100}; do [[ ! -e "$safety_root/ready" ]] || break; sleep 0.02; done
  if [[ ! -e "$safety_root/ready" ]]; then kill "$first"; wait "$first" || true; fail 'first operation did not reach hold point'; fi
  must_fail apply_config "$safety_config"
  assert_contains "$safety_error" 'another FlareTuner operation' 'sysctl lock exclusion'
  must_fail apply_tc_egress_limit eth0 90
  assert_contains "$safety_error" 'another FlareTuner operation' 'shared tc/sysctl lock'
  rm "$safety_root/hold"
  echo continue >"$safety_root/release"
  wait "$first" || fail 'first operation failed'
  assert_no_journal
}

test_safety_status() {
  safety_fixture
  apply_config "$safety_config"
  apply_tc_egress_limit eth0 90
  local output
  output="$(show_status)"
  assert_contains "$output" 'Managed runtime: consistent' 'status consistent'
  assert_contains "$output" 'Managed file ownership: consistent' 'status file digest'
  echo '# external comment' >>"$MANAGED_CONF"
  output="$(show_status)"
  assert_contains "$output" 'Managed file ownership: drift' 'status managed file drift'
  sed -i '$d' "$MANAGED_CONF"
  assert_contains "$output" 'TC egress limit: active and verified' 'status live tc'
  assert_contains "$output" 'not device root state' 'default is distinct from device qdisc'
  echo cubic >"$safety_root/runtime/net.ipv4.tcp_congestion_control"
  echo 'qdisc noqueue 0: root refcnt 2' >"$safety_root/eth0.qdisc"; : >"$safety_root/eth0.class"
  echo 'net.core.default_qdisc = cake' >"$safety_root/etc/sysctl.conf"
  output="$(show_status)"
  assert_contains "$output" 'Managed runtime: drift/unknown' 'status sysctl drift'
  assert_contains "$output" 'Sysctl conflict: detected/unknown' 'status sysctl conflict'
  assert_contains "$output" 'stale metadata; no managed qdisc' 'status stale tc'
  echo 'qdisc cake 8001: root bandwidth unlimited' >"$safety_root/eth0.qdisc"
  output="$(show_status)"
  assert_contains "$output" 'TC egress limit: drift/ownership conflict' 'status foreign tc'
  echo 'BAD=1' >"$TC_LIMIT_FILE"; echo 'BAD=1' >"$LATEST_BACKUP_FILE"
  output="$(show_status 2>/dev/null)"
  assert_contains "$output" 'TC egress limit: invalid/unsafe metadata' 'status corrupt metadata is nonfatal'
}

test_safety_sysctl_update_restore_and_failure() {
  safety_fixture
  apply_config "$safety_config"
  local updated
  updated="$(render_config low-memory under-512m under-100m conservative)"
  apply_config "$updated"
  cp "$MANAGED_CONF" "$safety_root/updated.conf"
  cp "$LATEST_BACKUP_FILE" "$safety_root/metadata.before"
  touch "$safety_root/fail-once-system"
  must_fail restore_latest_backup
  cmp -s "$MANAGED_CONF" "$safety_root/updated.conf" || fail 'failed restore did not recover applied file'
  cmp -s "$LATEST_BACKUP_FILE" "$safety_root/metadata.before" || fail 'failed restore lost metadata'
  assert_no_journal
  restore_latest_backup
  assert_file_contains "$MANAGED_CONF" 'net.core.rmem_max = 16777216' 'restore previous profile'
  assert_equals "$(cat "$safety_root/runtime/net.core.rmem_max")" 16777216 'previous profile active'
}

test_safety_managed_alias_and_drift() {
  safety_fixture
  apply_config "$safety_config"
  ln -s "$MANAGED_CONF" "$safety_root/etc/sysctl.d/10-alias.conf"
  must_fail apply_config "$safety_config"
  assert_contains "$safety_error" 'managed config alias' 'managed alias rejected before mutation'
  rm "$safety_root/etc/sysctl.d/10-alias.conf"
  echo '# external edit' >>"$MANAGED_CONF"
  must_fail apply_config "$safety_config"
  assert_contains "$safety_error" 'managed config drift' 'existing config drift refused'
  assert_file_contains "$MANAGED_CONF" 'external edit' 'external managed-file changes preserved'
}

test_safety_backup_path_rejection() {
  local attack
  for attack in outside missing symlink parent-link; do
    safety_fixture
    apply_config "$safety_config"
    local path="$safety_root/outside"
    case "$attack" in
      outside) echo bad >"$path" ;;
      missing) path="$BACKUP_DIR/missing" ;;
      symlink) echo bad >"$path"; ln -s "$path" "$BACKUP_DIR/link"; path="$BACKUP_DIR/link" ;;
      parent-link) mkdir "$safety_root/foreign"; echo bad >"$safety_root/foreign/runtime"; ln -s "$safety_root/foreign" "$BACKUP_DIR/linkdir"; path="$BACKUP_DIR/linkdir/runtime" ;;
    esac
    sed -i "s|^RUNTIME_PATH=.*|RUNTIME_PATH=$path|" "$LATEST_BACKUP_FILE"
    must_fail restore_latest_backup
    assert_file_contains "$MANAGED_CONF" 'net.core.default_qdisc = fq' 'unsafe backup did not change current config'
  done
}

test_safety_signal_after_metadata_commit() {
  local operation
  for operation in sysctl tc; do
    safety_fixture
    eval "$(declare -f atomic_publish | sed '1s/atomic_publish/original_atomic_publish/')"
    atomic_publish() {
      original_atomic_publish "$@" || return 1
      if [[ "$2" == "$LATEST_BACKUP_FILE" || "$2" == "$TC_LIMIT_FILE" ]]; then kill -TERM "$BASHPID"; fi
    }
    if [[ "$operation" == sysctl ]]; then must_fail apply_config "$safety_config";
    else must_fail apply_tc_egress_limit eth0 90; fi
    [[ ! -e "$TC_LIMIT_FILE" && ! -e "$LATEST_BACKUP_FILE" && ! -e "$MANAGED_CONF" ]] || fail 'interruption after metadata commit left new ownership records'
    assert_no_journal
  done
}

test_safety_menu_paths() {
  safety_fixture
  local output
  output="$(printf '5\neth0\n90\nyes\n6\n4\n7\n' | main)"
  assert_contains "$output" 'Applied and verified tc egress limit' 'menu apply'
  assert_contains "$output" 'Cleared tc egress limit' 'menu clear'
  [[ ! -e "$TC_LIMIT_FILE" ]] || fail 'menu clear left metadata'
  if output="$(printf '5\nmissing0\n90\nyes\n7\n' | main 2>&1)"; then fail 'menu hid operation failure with zero status'; fi
  assert_contains "$output" 'Operation failed or cancelled' 'menu error distinct from success'
}

test_safety_removed_config_keeps_runtime_evidence() {
  safety_fixture
  echo cubic >"$safety_root/runtime/net.ipv4.tcp_congestion_control"
  touch "$safety_root/remove-config-system"
  must_fail apply_config "$safety_config"
  [[ ! -e "$MANAGED_CONF" && ! -e "$LATEST_BACKUP_FILE" ]] || fail 'external removal was overwritten'
  assert_equals "$(cat "$safety_root/runtime/net.ipv4.tcp_congestion_control")" bbr 'runtime change remains visible for manual recovery'
  assert_retained_journal
}

test_safety_restore_intermediate_config_values() {
  safety_fixture
  apply_config "$safety_config"
  # The pre-B runtime snapshot intentionally differs from profile A on disk.
  echo 1234 >"$safety_root/runtime/net.core.rmem_max"
  local updated
  updated="$(render_config low-memory under-512m under-100m conservative)"
  apply_config "$updated"
  cp "$MANAGED_CONF" "$safety_root/profile-b.conf"
  cp "$LATEST_BACKUP_FILE" "$safety_root/metadata.before"
  touch "$safety_root/fail-once-system"
  must_fail restore_latest_backup
  cmp -s "$MANAGED_CONF" "$safety_root/profile-b.conf" || fail 'failed restore did not recover profile B from intermediate A values'
  cmp -s "$LATEST_BACKUP_FILE" "$safety_root/metadata.before" || fail 'failed restore changed latest metadata'
  assert_equals "$(cat "$safety_root/runtime/net.core.rmem_max")" 4194304 'failed restore recovered profile B runtime'
  assert_no_journal
}

test_safety_persistent_reload_restores_runtime() {
  safety_fixture
  echo cubic >"$safety_root/runtime/net.ipv4.tcp_congestion_control"
  touch "$safety_root/fail-after-system"
  must_fail apply_config "$safety_config"
  assert_equals "$(cat "$safety_root/runtime/net.ipv4.tcp_congestion_control")" cubic 'persistent reload failure still restores saved keys'
  assert_file_contains "$safety_root/sysctl.log" '-w net.ipv4.tcp_congestion_control=cubic' 'saved runtime write attempted'
  [[ ! -e "$MANAGED_CONF" ]] || fail 'persistent reload failure did not restore managed file state'
  assert_retained_journal
}

test_safety_unrelated_exclusion() {
  safety_fixture
  printf '%s\n' '  -net.ipv4.conf.all.rp_filter  ' >"$safety_root/etc/sysctl.d/50-default.conf"
  apply_config "$safety_config"
  assert_file_contains "$MANAGED_CONF" 'net.core.default_qdisc = fq' 'valid unrelated exclusion permits apply'
}

test_safety_failed_runtime_write_continues_recovery() {
  safety_fixture
  echo 1234 >"$safety_root/runtime/net.core.rmem_max"
  echo 4321 >"$safety_root/runtime/net.core.wmem_max"
  touch "$safety_root/fail-after-system"
  echo net.core.rmem_max >"$safety_root/fail-write-key"
  must_fail apply_config "$safety_config"
  assert_equals "$(cat "$safety_root/runtime/net.core.wmem_max")" 4321 'recovery continues after another key fails'
  assert_equals "$(cat "$safety_root/runtime/net.core.rmem_max")" 16777216 'failed key stays visible for manual recovery'
  assert_retained_journal
}

test_safety_external_runtime_blocks_recovery() {
  safety_fixture
  echo cubic >"$safety_root/runtime/net.ipv4.tcp_congestion_control"
  touch "$safety_root/drift-runtime-system"
  must_fail apply_config "$safety_config"
  assert_equals "$(cat "$safety_root/runtime/net.ipv4.tcp_congestion_control")" reno 'unexpected runtime change preserved'
  if grep -q -- '^-w ' "$safety_root/sysctl.log"; then fail 'recovery overwrote externally drifted runtime'; fi
  assert_retained_journal
}

test_safety_implicit_leaf_not_dumped() {
  safety_fixture
  touch "$safety_root/hide-pfifo"
  apply_tc_egress_limit eth0 90
  clear_tc_egress_limit
  assert_no_journal
  safety_fixture
  touch "$safety_root/hide-pfifo"
  echo 3 >"$safety_root/fail-step"
  must_fail apply_tc_egress_limit eth0 90
  assert_file_contains "$safety_root/eth0.qdisc" 'noqueue 0:' 'invisible implicit leaf failure rollback'
  assert_no_journal
}

test_safety_hidden_sysctl_sources() {
  local name
  for name in .provider.conf .conf; do
    safety_fixture
    echo 'net.ipv4.tcp_congestion_control = cubic' >"$safety_root/etc/sysctl.d/$name"
    must_fail apply_config "$safety_config"
    [[ ! -e "$MANAGED_CONF" ]] || fail 'hidden conflict published managed config'
    assert_contains "$safety_error" "$name" 'hidden source reported'
  done
  safety_fixture
  mkdir -p "$safety_root/usr/lib/sysctl.d"
  echo 'net.core.default_qdisc = cake' >"$safety_root/usr/lib/sysctl.d/.provider.conf"
  echo 'net.core.default_qdisc = fq' >"$safety_root/etc/sysctl.d/.provider.conf"
  apply_config "$safety_config"
  local before
  before="$(source_fingerprint)"
  echo 'net.core.default_qdisc = cake' >"$safety_root/etc/sysctl.d/.provider.conf"
  [[ "$(source_fingerprint)" != "$before" ]] || fail 'hidden change missing from source fingerprint'
}

run_safety_tests() {
  run_test 'hidden sysctl sources obey masking and enter fingerprints' test_safety_hidden_sysctl_sources
  run_test 'HTB implicit leaf may be absent from tc dump' test_safety_implicit_leaf_not_dumped
  run_test 'failed runtime write does not skip remaining recovery keys' test_safety_failed_runtime_write_continues_recovery
  run_test 'unexpected runtime drift prevents automatic recovery writes' test_safety_external_runtime_blocks_recovery
  run_test 'persistent reload failure still restores saved managed runtime' test_safety_persistent_reload_restores_runtime
  run_test 'unrelated valid sysctl exclusion permits apply' test_safety_unrelated_exclusion
  run_test 'removed managed file cannot discard changed runtime evidence' test_safety_removed_config_keeps_runtime_evidence
  run_test 'failed restore recognizes its intermediate configured values' test_safety_restore_intermediate_config_values
  run_test 'sysctl conflicting sysctl.conf refuses before publication' test_safety_sysctl_conflict
  run_test 'tc foreign root is never replaced' test_safety_tc_foreign
  run_test 'equal declarations and directory basename masking' test_safety_sysctl_same_and_masking
  run_test 'all procps/systemd source directories are inspected' test_safety_sysctl_sources
  run_test 'unknown syntax and globs fail closed' test_safety_sysctl_unknown
  run_test 'dev-null mask and reserved basename conflict' test_safety_sysctl_mask_and_reserved
  run_test 'sysctl repeat skips publication backup and reload' test_safety_sysctl_idempotent
  run_test 'verify buffer key beyond BBR and fq' test_safety_sysctl_full_verification
  run_test 'partial sysctl reload restores runtime snapshot' test_safety_sysctl_partial_failure
  run_test 'failed sysctl rollback retains journal and blocks mutations' test_safety_sysctl_reload_rollback_failure
  run_test 'rollback preserves externally modified managed file' test_safety_sysctl_external_drift
  run_test 'restore verifies saved pre-apply runtime' test_safety_restore_roundtrip
  run_test 'restore rejects config/runtime drift and damaged snapshots' test_safety_restore_rejects_drift_and_corruption
  run_test 'symlink hardlink and permissions guards' test_safety_filesystem_guards
  run_test 'each tc creation step failure rolls back' test_safety_tc_steps_fail
  run_test 'tc metadata commit failure rolls back first apply' test_safety_tc_metadata_failure
  run_test 'sysctl metadata commit failure rolls back' test_safety_sysctl_metadata_failure
  run_test 'tc repeat update and repeated clear' test_safety_tc_update_and_repeat
  run_test 'tc failed update restores old class and metadata' test_safety_tc_update_rollback
  run_test 'reboot deleted qdisc and absent interface stale metadata' test_safety_tc_stale
  run_test 'tc root class child filter and identity drift reject mutations' test_safety_tc_external_changes
  run_test 'partial tc drift and rollback failure retain evidence' test_safety_tc_partial_drift_and_rollback_failure
  run_test 'missing interface and explicit clear before switching targets' test_safety_tc_interface_switch
  run_test 'legacy corrupt and duplicate tc metadata fail closed' test_safety_tc_legacy_and_corrupt_metadata
  run_test 'INT TERM and HUP restore sysctl snapshot' test_safety_sysctl_signals
  run_test 'uncertain interrupted tc state retains journal' test_safety_tc_signal
  run_test 'shared lock serializes sysctl and tc operations' test_safety_concurrency
  run_test 'status distinguishes runtime metadata defaults and corruption' test_safety_status
  run_test 'sysctl updated profile restore and failed restore recovery' test_safety_sysctl_update_restore_and_failure
  run_test 'managed aliases and edited managed configs refuse overwrite' test_safety_managed_alias_and_drift
  run_test 'valid metadata with unsafe runtime backup paths is rejected' test_safety_backup_path_rejection
  run_test 'signal after metadata publication rolls back ownership records' test_safety_signal_after_metadata_commit
  run_test 'interactive tc status clear and nonzero failure paths' test_safety_menu_paths
}
