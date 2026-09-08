#!/bin/bash
# Dual-threshold egress verdict.  The 2026-09-08 Washington 503 storm
# showed the single-threshold probe conflates two user-visible states:
# "slow but usable" (requests 5-15s, LAN users still browse) and "dead"
# (every fresh dial times out).  The old 8s max-time sat exactly on the
# degradation line, so the streak flapped 1->2->0->1->2 and every 4th
# flap bought a rotation -- the only real outage a LAN user saw all day.
#
# New contract:
#   _check_tunnel_egress classifies each probe attempt:
#     0 = healthy  (any target answered within EGRESS_DEAD_TIMEOUT)
#     2 = degraded (answered, but slower than EGRESS_DEGRADED_TIMEOUT)
#     1 = dead     (no target answered within EGRESS_DEAD_TIMEOUT)
#   The egress streak counts ONLY dead exits.  A degraded tunnel logs
#   (observability) but never increments the streak, so degradation
#   never causes a rotation on its own.
#
# Ground truth (2026-09-08 live measurement, N100 + z66):
#   z66 LAN user path 4/4 OK at 5-10s while N100 egress probe alternated
#   pass/fail at the 8s line -- users were up, watchdog kept rotating.
#   surflare ping reported 6.3ms RTT relay-local responses 13/13 while
#   the data plane was hard down -- relay-local TCP answers tell you
#   nothing about forwarding; it stays out of the verdict chain.

set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# --- constants under test ---
CONSTS=$(grep -E '^EGRESS_STREAK_THRESHOLD=|^EGRESS_STREAK_WINDOW=|^EGRESS_DEGRADED_TIMEOUT=|^EGRESS_DEAD_TIMEOUT=' "$WATCHDOG")
echo "$CONSTS" | grep -q '^EGRESS_DEGRADED_TIMEOUT=' \
	|| { echo "FATAL: EGRESS_DEGRADED_TIMEOUT missing"; exit 1; }
echo "$CONSTS" | grep -q '^EGRESS_DEAD_TIMEOUT=' \
	|| { echo "FATAL: EGRESS_DEAD_TIMEOUT missing"; exit 1; }

# run_egress CURL_OUTPUT -> exercise _check_tunnel_egress with a curl PATH-shim
# CURL_OUTPUT: what every curl invocation prints on stdout
# ("204 1.5" = code 204 in 1.5s; "000 30.0" = timeout).
run_egress() {
	local curl_out="$1"
	local d rc
	d=$(mktemp -d)
	mkdir -p "$d/bin"
	cat > "$d/bin/curl" <<SHIM
#!/bin/sh
echo "$curl_out"
SHIM
	chmod +x "$d/bin/curl"
	PATH="$d/bin:$PATH" bash -c "
		$CONSTS
		log() { :; }
		$(sed -n '/^_check_tunnel_egress() {/,/^}/p' "$WATCHDOG")
		$(sed -n '/^_float_lte() {/,/^}/p' "$WATCHDOG")
		_check_tunnel_egress
	" 2>/dev/null
	rc=$?
	rm -rf "$d"
	return $rc
}

# --- extract the egress-streak tail of check_vpn_health (same harness trick as test_egress_streak) ---
extract_tail() {
	awk '
		/# Probe 7 tests a single target/ { in_blk=1 }
		in_blk { print }
		in_blk && /echo "\$result"/ { exit }
	' "$1"
}
TAIL=$(extract_tail "$WATCHDOG")
[ -n "$TAIL" ] || { echo "FATAL: tail extract empty"; exit 1; }

# run_tail RESULT EGRESS_RC STREAK_STATE -- egress_rc: 0 healthy, 2 degraded, 1 dead
run_tail() {
	local result_in="$1" egress_rc="$2" streak="$3"
	local d sp tmp_proxy
	d=$(mktemp -d)
	sp="$d/streak"
	tmp_proxy="$d/proxy"
	printf 'OK\n' > "$tmp_proxy"
	if [ -n "$streak" ]; then
		printf '%s\n' "$streak" > "$sp"
	fi
	bash -c "
		$CONSTS
		EGRESS_STREAK_STATE='$sp'
		tmp_proxy='$tmp_proxy'
		result='$result_in'
		log() { :; }
		_check_tunnel_egress() { return $egress_rc; }
		run() {
$(extract_tail "$WATCHDOG")
		}
		run
	" 2>/dev/null
	rm -rf "$d"
}

NOW=$(date +%s)

echo "T1: fast answer (1.5s) -> healthy (exit 0)"
run_egress "204 1.5"
RC=$?
[ "$RC" = "0" ] && ok "T1 fast healthy" || bad "T1 rc=$RC want 0"

echo "T2: slow answer (12s) -> degraded (exit 2), not dead"
run_egress "204 12.0"
RC=$?
[ "$RC" = "2" ] && ok "T2 slow=degraded" || bad "T2 rc=$RC want 2"

echo "T3: no answer (000, 30s) -> dead (exit 1)"
run_egress "000 30.0"
RC=$?
[ "$RC" = "1" ] && ok "T3 timeout=dead" || bad "T3 rc=$RC want 1"

echo "T4: degraded never increments streak -> verdict stays OK"
OUT=$(run_tail OK 2 "")
[ "$OUT" = "OK" ] && ok "T4 degraded no flip" || bad "T4 got $OUT want OK"

echo "T5: degraded does not reset streak (dead count must survive)"
d=$(mktemp -d); sp5="$d/sp"
printf '1 %s\n' "$NOW" > "$sp5"
OUT=$(bash -c "
	$CONSTS
	EGRESS_STREAK_STATE='$sp5'
	tmp_proxy='$sp5.proxy'
	result='OK'
	log() { :; }
	_check_tunnel_egress() { return 2; }
	run() {
$(extract_tail "$WATCHDOG")
	}
	run
" 2>/dev/null)
read -r cnt _ < "$sp5"
[ "$cnt" = "1" ] && ok "T5 degraded preserves streak count" || bad "T5 streak count got $cnt want 1"
rm -rf "$d"

echo "T6: 3rd dead in window -> PROXY_BROKEN flip intact"
OUT=$(run_tail OK 1 "2 $NOW")
[ "$OUT" = "PROXY_BROKEN" ] && ok "T6 dead streak flips" || bad "T6 got $OUT want PROXY_BROKEN"

echo "T7: auth-bump guard still wired (dead with auth noise -> auth counted)"
# covered by test_egress_streak T7 equivalent; here verify _egress_auth_bump exists
grep -q '_egress_auth_bump' "$WATCHDOG" && ok "T7 auth bump present" || bad "T7 auth bump missing"

echo "T8: injection - degraded counted as dead must be caught"
INJ=$(mktemp /tmp/dt_inj_XXXXXX)
cp "$WATCHDOG" "$INJ"
python3 - "$WATCHDOG" "$INJ" << 'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# Break the dead-only guard: treat degraded (rc 2) the same as dead.
old = '\t\telif [ "$_es_rc" -eq 2 ]; then'
new = '\t\telif false; then'
assert old in s, "degraded branch missing"
s = s.replace(old, new, 1)
open(dst, 'w').write(s)
PY
# With the guard broken, degraded must increment the streak file.
d8=$(mktemp -d); sp8="$d8/sp"
printf '1 %s\n' "$NOW" > "$sp8"
INJ_OUT=$(bash -c "
	$CONSTS
	EGRESS_STREAK_STATE='$sp8'
	tmp_proxy='$d8/proxy'
	result='OK'
	log() { :; }
	_check_tunnel_egress() { return 2; }
	run() {
$(extract_tail "$INJ")
	}
	run
" 2>/dev/null)
read -r cnt8 _ < "$sp8"
INJ_OUT=$(cat "$sp8" 2>/dev/null)
if [ "$cnt8" = "2" ]; then
	ok "T8 injection incremented streak (T5 detects this bug), state=${INJ_OUT:-empty}"
else
	bad "T8 injection not detectable: broken guard left streak at $cnt8"
fi
rm -rf "$d8"
rm -f "$INJ"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
