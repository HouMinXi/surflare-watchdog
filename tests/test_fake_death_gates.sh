#!/bin/bash
# Tests for the fake-death redesign gates: the backend-503-storm hold,
# the PROXY_BROKEN grace window, the scoped conntrack flush, the tproxy
# ct-mark, and the bpftool probe fix. All logic is EXTRACTED from the
# real watchdog script so a pass proves the production logic, not a copy.
#
# shellcheck disable=SC2015  # `[ cond ] && ok x || bad x` is safe here:
# ok()/bad() always return 0, so bad never runs after a successful ok.
# This is the house idiom across all tests in this repo.
# shellcheck disable=SC2016  # single quotes around stub/harness bodies
# are intentional -- the inner $VARS must expand in the CHILD shell.

set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

CONSTS=$(grep -E "^STORM_503_HOLD_MAX=|^STORM_503_RECENT=|^PROXY_BROKEN_GRACE=|^STORM_503_STATE=" "$WATCHDOG" | grep -v "^#")

STUBS='log() { LOG_BUF="$LOG_BUF|$1"; }
_send_alert() { :; }
_export_diag_state() { :; }
_run_advisory_diagnosis() { :; }
_send_diagnosis_alert() { :; }'

extract_branch() {
	awk '
		/elif \[ "\$health" = "PROXY_BROKEN" \]/ { in_blk=1 }
		in_blk && /elif \[ "\$health" = "OK" \]/ { exit }
		in_blk { print }
	' "$1"
}

# run_branch: env seeds STORM_FILE (503-state file, default absent),
# STORM_ACTIVE, STORM_SINCE, PB_GRACE. Prints
# "fail_count hold skip" plus 1 marker chars for storm/grace logs.
run_branch() {
	local wd="${1:-$WATCHDOG}" blk
	blk=$(extract_branch "$wd")
	if [ -z "$blk" ] || ! printf '%s\n' "$blk" | grep -q "_line_congested"; then
		echo "EXTRACT_FAIL"
		return 99
	fi
	STORM_FILE="${STORM_FILE:-/nonexistent_503_state}" \
	STORM_ACTIVE="${STORM_ACTIVE:-0}" \
	STORM_SINCE="${STORM_SINCE:-0}" \
	PB_GRACE="${PB_GRACE:-0}" \
	bash -c "
		$STUBS
		$CONSTS
		STORM_503_STATE=\"\$STORM_FILE\"
		_line_congested() { return 1; }   # clean line: isolate downstream gates
		health=PROXY_BROKEN
		fail_count=1
		FAIL_THRESHOLD=4
		_hold_exit_node=0
		_line_congested_active=0
		_line_congested_since=0
		_storm_hold_active=\$STORM_ACTIVE
		_storm_hold_since=\$STORM_SINCE
		_pb_grace_since=\$PB_GRACE
		_skip_reconnect_this_cycle=0
		_auth_expired_this_cycle=0
		LOG_BUF=
		if false; then :
		$blk
		fi
		case \"\$LOG_BUF\" in *storm\ live*) _s=1 ;; *) _s=0 ;; esac
		case \"\$LOG_BUF\" in *first\ seen*) _g=1 ;; *) _g=0 ;; esac
		case \"\$LOG_BUF\" in *quieted*) _q=1 ;; *) _q=0 ;; esac
		echo \"\$fail_count \$_hold_exit_node \$_skip_reconnect_this_cycle \$_s \$_g \$_q\"
	" 2>/dev/null
}

NOW=$(date +%s)
STORM_F=$(mktemp /tmp/fd_storm_XXXXXX)

echo "T1: urltest storm file must NOT announce storm-live; grace absorbs"
printf '5 1600000000 %s\n' "$NOW" > "$STORM_F"
OUT=$(STORM_FILE=$STORM_F run_branch)
# fail_count 1, hold_exit 1 (PROXY_BROKEN always pins exit), skip=1
# from grace first-seen; s=0 (no storm-live); g=1; q=0
[ "$OUT" = "1 1 1 0 1 0" ] && ok "urltest storm -> grace, no storm-live" || bad "T1 wrong: $OUT"

echo "T2: STORM_ACTIVE seed + fresh file still no storm-live"
OUT=$(STORM_FILE=$STORM_F STORM_ACTIVE=1 STORM_SINCE=$NOW run_branch)
[ "$OUT" = "1 1 1 0 1 0" ] && ok "active-seed -> grace, no storm-live" || bad "T2 wrong: $OUT"

echo "T3: expired grace + storm file -> reconnect (hold_exit stays 1)"
# prefix assignment: a bare PB_GRACE=x OUT=$(...) would persist into later tests
OUT=$(PB_GRACE=$((NOW - 99999)) STORM_FILE=$STORM_F STORM_ACTIVE=1 STORM_SINCE=$((NOW - 99999)) run_branch)
[ "$OUT" = "4 1 0 0 0 0" ] && ok "expired grace reconnects despite storm file" || bad "T3 wrong: $OUT"

echo "T4: stale last-epoch storm file -> same as no-storm, grace first-seen"
printf '5 1600000000 %s\n' "$((NOW - 3600))" > "$STORM_F"
OUT=$(STORM_FILE=$STORM_F STORM_ACTIVE=1 STORM_SINCE=$NOW run_branch)
[ "$OUT" = "1 1 1 0 1 0" ] && ok "stale storm file -> grace, no quieted/storm-live" || bad "T4 wrong: $OUT"
rm -f "$STORM_F"

echo "T5: no storm file, grace first sighting -> hold + first-seen log"
OUT=$(run_branch)
[ "$OUT" = "1 1 1 0 1 0" ] && ok "grace first-seen -> held" || bad "T5 wrong: $OUT"

echo "T6: grace mid-window -> still holding, sustained log"
OUT=$(PB_GRACE=$((NOW - 100)) run_branch)
# g=0: mid-window logs "still holding", not "first seen"
[ "$OUT" = "1 1 1 0 0 0" ] && ok "grace mid-window -> held" || bad "T6 wrong: $OUT"

echo "T7: grace expired, no storm -> reconnect fires"
OUT=$(PB_GRACE=$((NOW - 99999)) run_branch)
[ "$OUT" = "4 1 0 0 0 0" ] && ok "grace expired -> reconnect" || bad "T7 wrong: $OUT"

echo "T8: bug-inject -- restoring skip on urltest 503 must flip T1"
INJ=$(mktemp /tmp/fd_inj_XXXXXX)
python3 - "$WATCHDOG" "$INJ" << 'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = '\t\t\t\tlog "urltest 503 noise (count=${_storm_count}): not holding reconnect"'
new = '''\t\t\t\tlog "503 storm live (count=${_storm_count}): reconnect held -- backend storms pass without one"
\t\t\t\t_skip_reconnect_this_cycle=1'''
assert old in s, "noise-log anchor missing"
open(dst, 'w').write(s.replace(old, new, 1))
PYEOF
STORM_F2=$(mktemp /tmp/fd_storm2_XXXXXX)
printf '5 1600000000 %s\n' "$NOW" > "$STORM_F2"
OUT=$(PB_GRACE=0 STORM_FILE=$STORM_F2 run_branch "$INJ")
# skip restored -> storm-live, grace never reached
[ "$OUT" = "1 1 1 1 0 0" ] && ok "skip restored on urltest 503 -> storm-live (caught)" || bad "T8 NOT caught: $OUT"
rm -f "$INJ" "$STORM_F2"

echo "T9: bug-inject -- deleting the grace first-seen hold must flip T5"
INJ=$(mktemp /tmp/fd_inj2_XXXXXX)
# remove the first-seen branch's skip so a fresh verdict falls straight
# through to the reconnect (the exact regression the grace exists for)
python3 - "$WATCHDOG" "$INJ" << 'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# delete the hold's EXECUTION, not its timestamp: the first-seen branch
# must stop setting the one-shot skip so a fresh verdict falls straight
# through to the reconnect trigger (the exact regression this test
# exists to catch). Anchor includes the unique alert call preceding it.
old = '''_send_diagnosis_alert "$health"
				_skip_reconnect_this_cycle=1'''
new = '''_send_diagnosis_alert "$health"'''
assert old in s, "anchor missing"
open(dst, 'w').write(s.replace(old, new, 1))
PYEOF
OUT=$(PB_GRACE=0 run_branch "$INJ")
# injected: first sighting pretends the grace already elapsed ->
# reconnect fires immediately instead of holding
[ "$OUT" = "4 1 0 0 1 0" ] && ok "grace deleted -> reconnect fires (caught)" || bad "T9 NOT caught: $OUT"
rm -f "$INJ"

echo "T10: scoped flush -- loopback, ct-mark, server IPs; never -F"
FLUSH_CALLS=$(mktemp /tmp/fd_flush_XXXXXX)
bash -c '
	CONNTRACE_OUT=
	conntrack() { echo "conntrack $*" >> '"$FLUSH_CALLS"'; }
	nft() {
		case "$*" in
			*"list set inet killswitch server_ips"*)
				echo "elements = { 38.34.12.160, 103.255.209.7 }" ;;
		esac
		return 0
	}
	'"$(awk '/^_scoped_conntrack_flush\(\)/,/^}/' "$WATCHDOG")"'
	_scoped_conntrack_flush
' 2>/dev/null
_grep_calls() {
	local n
	n=$(grep -c "$1" "$FLUSH_CALLS" 2>/dev/null || true)
	case "$n" in ''|*[!0-9]*) n=0 ;; esac
	printf '%s' "$n"
}
LB=$(_grep_calls '\-s 127.0.0.1'); LBD=$(_grep_calls '\-d 127.0.0.1')
MK=$(_grep_calls '\-m 256'); S1=$(_grep_calls '\-d 38.34.12.160'); S2=$(_grep_calls '\-d 103.255.209.7')
FF=$(_grep_calls '^\S* -F$\|conntrack -F')
if [ "$LB" -ge 1 ] && [ "$LBD" -ge 1 ] && [ "$MK" -ge 1 ] && [ "$S1" -ge 1 ] && [ "$S2" -ge 1 ] && [ "$FF" -eq 0 ]; then
	ok "all scoped classes called, zero -F"
else
	bad "flush calls wrong: lb=$LB lbd=$LBD mark=$MK s1=$S1 s2=$S2 fullF=$FF"
fi
rm -f "$FLUSH_CALLS"

echo "T10b: scoped-flush failure must NOT fall back to unscoped -F"
# the redesign forbids a full-table flush anywhere in the script;
# comments mentioning the old behavior are fine, commands are not
if grep -vE '^[[:space:]]*#' surflare_watchdog.sh | grep -n "conntrack -F"; then
	bad "conntrack -F still present in live code (full-table fallback)"
else
	ok "zero conntrack -F in live code"
fi
# and the failure path of each inline scoped site must be log-only
for _anchor in "stale output-chain flows may persist" "pre-existing connections may persist"; do
	grep -q "$_anchor" surflare_watchdog.sh \
		&& ok "failure-path WARN present: $_anchor" \
		|| bad "failure-path WARN missing: $_anchor"
done

echo "T11: tproxy rules carry ct mark 0x100 in both nft variants"
for f in router/rule/surflare-lan-tproxy.nft router/global/surflare-lan-tproxy.nft; do
	n=$(grep -c "ct mark set 0x00000100" "$f" 2>/dev/null || echo 0)
	case "$n" in 2) ok "$f: both tproxy rules marked" ;; *) bad "$f: $n ct-mark lines (want 2)" ;; esac
done

echo "T12: bpftool probe -- the double-zero pattern is gone"
if grep -q 'grep -c "loaded_at" || echo 0' "$WATCHDOG"; then
	bad "old || echo 0 pattern still present"
else
	ok "no || echo 0 after grep -c loaded_at"
fi
grep -q 'case "\$_bp_count" in' "$WATCHDOG" && ok "non-numeric case guard present" || bad "case guard missing"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
