#!/bin/bash
# Tests for the congestion-aware diagnosis gate (Zone C).
# _line_congested and the main-loop PROXY_BROKEN branch are EXTRACTED
# from the real watchdog script so a pass proves the production logic,
# not a copy.

set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

CONSTS=$(grep -E "^CONGESTION_PROBE_TARGETS=|^CONGESTION_RTT_MAX=|^CONGESTION_LOSS_MAX=|^CONGESTION_HOLD_MAX=" "$WATCHDOG")

extract_fn() {
	awk '/^_line_congested\(\)/,/^}/' "$1"
}

# Extract the main-loop PROXY_BROKEN branch. The branch lives in the
# main loop's if/elif chain, so its end is the NEXT elif, not a fi --
# nesting counting would stop at the first inner fi and lose the
# reconnect tail. Print from the PROXY_BROKEN elif up to (excluding)
# the following OK elif; internals are balanced.
extract_branch() {
	awk '
		/elif \[ "\$health" = "PROXY_BROKEN" \]/ { in_blk=1 }
		in_blk && /elif \[ "\$health" = "OK" \]/ { exit }
		in_blk { print }
	' "$1"
}

# The child shell defines its own ping() stub from env; PING_OUT/PING_RC
# carry the fake output through the environment (env prefixes on bash
# -c / ash -c both export into the child).
PING_GOOD='5 packets transmitted, 5 received, 0% packet loss
round-trip min/avg/max = 8.4/9.2/12.1 ms'
PING_BLOAT='5 packets transmitted, 5 received, 0% packet loss
round-trip min/avg/max = 780.4/812.9/890.1 ms'
PING_LOSSY='5 packets transmitted, 2 received, 60% packet loss
round-trip min/avg/max = 12.4/14.2/18.1 ms'
PING_DEAD='5 packets transmitted, 0 received, 100% packet loss'

run_fn() {
	# $1 = fake ping output for 223.5.5.5, $2 = fake ping output for
	# 114.114.114.114, $3 = fake ping rc; prints the fn's rc
	# production calls ping -c 3 -W 1 <target>, so the target is $5
	PING_A="$1" PING_B="$2" PING_RC="$3" bash -c '
		ping() { case "$5" in 223.5.5.5) printf "%s\n" "$PING_A" ;; *) printf "%s\n" "$PING_B" ;; esac; return "$PING_RC"; }
		'"$CONSTS"'
		'"$(extract_fn "$WATCHDOG")"'
		_line_congested
	' 2>/dev/null
}

echo "T1: clean line (0% loss, avg 9ms) -> not congested"
run_fn "$PING_GOOD" "$PING_GOOD" 0
rc=$?
[ "$rc" -ne 0 ] && ok "clean -> false" || bad "clean -> rc=0 (wrong)"

echo "T2: bufferbloat (0% loss, avg 813ms) -> congested"
run_fn "$PING_BLOAT" "$PING_BLOAT" 0
rc=$?
[ "$rc" -eq 0 ] && ok "bloat -> true" || bad "bloat -> rc!=0 (wrong)"

echo "T3: loss (60%) -> congested"
run_fn "$PING_LOSSY" "$PING_LOSSY" 0
rc=$?
[ "$rc" -eq 0 ] && ok "loss -> true" || bad "loss -> rc!=0 (wrong)"

echo "T4: total loss (100%, ping rc=1) -> congested"
run_fn "$PING_DEAD" "$PING_DEAD" 1
rc=$?
[ "$rc" -eq 0 ] && ok "dead -> true" || bad "dead -> rc!=0 (wrong)"

echo "T5: unparseable output (fail-open) -> not congested"
run_fn "" "" 1
rc=$?
[ "$rc" -ne 0 ] && ok "unparseable -> false" || bad "unparseable -> rc=0 (wrong)"

echo "T13: one target unparseable + other congested -> congested"
# unknown state on A is not evidence; B's congestion is the verdict
run_fn "" "$PING_BLOAT" 0
rc=$?
[ "$rc" -eq 0 ] && ok "single-source bloat -> true" || bad "single-source bloat -> rc!=0 (wrong)"

echo "T14: one target unparseable + other clean -> not congested"
run_fn "" "$PING_GOOD" 0
rc=$?
[ "$rc" -ne 0 ] && ok "single-source clean -> false" || bad "single-source clean -> rc=0 (wrong)"

PING_DEAD_BUSYBOX='3 packets transmitted, 0 packets received, 100% packet loss'
echo "T18: real busybox 100%-loss format -> congested (captured 2026-08-16 on N100)"
run_fn "$PING_DEAD_BUSYBOX" "$PING_DEAD_BUSYBOX" 1
rc=$?
[ "$rc" -eq 0 ] && ok "busybox dead -> true" || bad "busybox dead -> rc!=0 (wrong)"

PING_LOSS33='3 packets transmitted, 2 packets received, 33% packet loss
round-trip min/avg/max = 10.1/12.4/14.1 ms'
PING_RTT499='3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 10.1/499.9/520.1 ms'
PING_RTT500='3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 10.1/500.1/520.1 ms'

echo "T19: empty probe target list -> fail open (not congested)"
CONGESTION_PROBE_TARGETS="" bash -c "
	$(grep -E '^CONGESTION_RTT_MAX=|^CONGESTION_LOSS_MAX=' "$WATCHDOG")
	$(extract_fn "$WATCHDOG")
	_line_congested
" 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] && ok "empty targets -> false" || bad "empty targets -> rc=0 (wrong)"

echo "T20: ping binary absent -> fail open (not congested)"
PATH=/nonexistent bash -c "
	$(grep -E '^CONGESTION_PROBE_TARGETS=|^CONGESTION_RTT_MAX=|^CONGESTION_LOSS_MAX=' "$WATCHDOG")
	$(extract_fn "$WATCHDOG")
	_line_congested
" 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] && ok "ping absent -> false" || bad "ping absent -> rc=0 (wrong)"

echo "T21: loss boundary -- 33% (1 of 3, just past LOSS_MAX=30) -> congested"
run_fn "$PING_LOSS33" "$PING_LOSS33" 0
rc=$?
[ "$rc" -eq 0 ] && ok "loss 33% -> true" || bad "loss 33% -> rc!=0 (wrong)"

echo "T22: RTT boundary -- avg truncates to 499 vs 500"
run_fn "$PING_RTT499" "$PING_RTT499" 0
rc1=$?
run_fn "$PING_RTT500" "$PING_RTT500" 0
rc2=$?
if [ "$rc1" -ne 0 ] && [ "$rc2" -eq 0 ]; then
	ok "499 -> false, 500 -> true"
else
	bad "boundary wrong: 499.9->$rc1 500.1->$rc2"
fi

echo "T6: busybox ash compatibility of _line_congested"
PING_OUT="$PING_BLOAT" PING_RC=0 busybox ash -c '
	ping() { printf "%s\n" "$PING_OUT"; return "$PING_RC"; }
	'"$CONSTS"'
	'"$(extract_fn "$WATCHDOG")"'
	_line_congested
' 2>/dev/null
rc=$?
[ "$rc" -eq 0 ] && ok "ash: bloat -> true" || bad "ash failed"

# ---- wiring: the main-loop PROXY_BROKEN branch ----
STUBS='log() { LOG_BUF="$LOG_BUF|$1"; }
_send_alert() { :; }
_deliver_alert() { LOG_BUF="$LOG_BUF|deliver:$1"; }
_export_diag_state() { :; }
_run_advisory_diagnosis() { :; }
_send_diagnosis_alert() { :; }'

run_branch() {
	# $1 = _line_congested rc to force (0 congested, 1 clean)
	# $2 = _line_congested_since seed (0 = long ago -> hold expired)
	# $3 = watchdog file to extract from (defaults to $WATCHDOG)
	# $4 = _line_congested_active seed (1 = already active, no first-seen)
	# prints: fail_count hold skip recovered(1 if recovery log fired)
	local wd="${3:-$WATCHDOG}" blk
	blk=$(extract_branch "$wd")
	# Loud failure on a broken extraction: an empty block would make
	# T7 pass vacuously (the seeded values match its expectation).
	if [ -z "$blk" ] || ! printf '%s\n' "$blk" | grep -q "_line_congested"; then
		echo "EXTRACT_FAIL"
		return 99
	fi
	bash -c "
		$STUBS
		$CONSTS
		_line_congested() { return $1; }
		health=PROXY_BROKEN
		fail_count=1
		FAIL_THRESHOLD=4
		_hold_exit_node=0
		_line_congested_active=${4:-0}
		_line_congested_since=$2
		_skip_reconnect_this_cycle=0
		_auth_expired_this_cycle=0
		LOG_BUF=
		# the extracted block starts with elif; give it a false if-arm
		# so it parses standalone (the elif condition still runs)
		if false; then :
		$blk
		fi
		case \"\$LOG_BUF\" in *recovered*) _recovered=1 ;; *) _recovered=0 ;; esac
		echo \"\$fail_count \$_hold_exit_node \$_skip_reconnect_this_cycle \$_recovered\"
	" 2>/dev/null
}

echo "T7: congested line, hold not expired -> no reconnect (fail_count unchanged)"
# skip stays 1 for the rest of the cycle; the loop top resets it next
# iteration (wiring reset is covered by the loop-top init, not the branch)
OUT=$(run_branch 0 "$(date +%s)")
[ "$OUT" = "1 0 1 0" ] && ok "held: fail_count=1 hold=0 skip=1, no recovery log" || bad "held wrong: $OUT"

echo "T8: clean line -> reconnect fires + exit hold raised"
OUT=$(run_branch 1 0)
[ "$OUT" = "4 1 0 0" ] && ok "reconnect: fail_count=4 hold=1 skip=0" || bad "reconnect wrong: $OUT"

echo "T9: congestion past HOLD_MAX -> fail-open reconnect"
# active=1 so the first-seen block does not refresh the since timestamp
OUT=$(run_branch 0 0 "" 1)
[ "$OUT" = "4 0 0 0" ] && ok "expired: fail_count=4 reconnect runs, hold cleared" || bad "expired wrong: $OUT"

echo "T10: bug-inject -- bypassing the congestion guard must be caught"
INJ=$(mktemp /tmp/cong_inj_XXXXXX)
sed 's/if _line_congested; then/if false; then/' "$WATCHDOG" > "$INJ"
# With the guard faked clean, a congested verdict must reconnect (4 1 0),
# not hold: proves T7's hold came from the real guard.
OUT=$(run_branch 0 "$(date +%s)" "$INJ" 1)
# recovered=1: with the guard faked clean the branch sees a clean line
# and announces recovery -- the assertion is that reconnect fires
# (fail_count=4) instead of holding (fail_count=1).
[ "$OUT" = "4 1 0 1" ] && ok "injection caught: guard bypassed -> reconnect fires" || bad "injection NOT caught: $OUT"
rm -f "$INJ"

echo "T11: congested-then-recovered transition -> recovery log + reconnect"
# active=1 and the probe now reports clean: the else branch fires and
# announces recovery before reconnecting.
OUT=$(run_branch 1 0 "" 1)
[ "$OUT" = "4 1 0 1" ] && ok "recovery: reconnect + recovery announcement" || bad "recovery wrong: $OUT"

echo "T12: broken extraction anchor must fail loud, not pass vacuously"
INJ2=$(mktemp /tmp/cong_inj2_XXXXXX)
sed 's/elif \[ "\$health" = "PROXY_BROKEN" \]/elif [ "$health" = "PROXY_RENAMED" ]/' "$WATCHDOG" > "$INJ2"
OUT=$(run_branch 0 "$(date +%s)" "$INJ2" 1)
[ "$OUT" = "EXTRACT_FAIL" ] && ok "loud failure: EXTRACT_FAIL" || bad "vacuous pass: $OUT"
rm -f "$INJ2"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
