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
#     0 = healthy  (some target answered within EGRESS_DEGRADED_TIMEOUT)
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
WATCHDOG="${WATCHDOG:-surflare_watchdog.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# --- constants under test ---
CONSTS=$(grep -E '^EGRESS_STREAK_THRESHOLD=|^EGRESS_STREAK_WINDOW=|^EGRESS_DEGRADED_TIMEOUT=|^EGRESS_DEAD_TIMEOUT=' "$WATCHDOG")
echo "$CONSTS" | grep -q '^EGRESS_DEGRADED_TIMEOUT=' \
	|| { echo "FATAL: EGRESS_DEGRADED_TIMEOUT missing"; exit 1; }
echo "$CONSTS" | grep -q '^EGRESS_DEAD_TIMEOUT=' \
	|| { echo "FATAL: EGRESS_DEAD_TIMEOUT missing"; exit 1; }

EGRESS_FN=$(sed -n '/^_check_tunnel_egress() {/,/^}/p' "$WATCHDOG")
FLOAT_FN=$(sed -n '/^_float_lte() {/,/^}/p' "$WATCHDOG")
UPGRADE_FN=$(sed -n '/^_verify_surflare_upgrade() {/,/^}/p' "$WATCHDOG")
[ -n "$EGRESS_FN" ] || { echo "FATAL: egress extract empty"; exit 1; }
[ -n "$FLOAT_FN" ] || { echo "FATAL: float extract empty"; exit 1; }
[ -n "$UPGRADE_FN" ] || { echo "FATAL: upgrade extract empty"; exit 1; }

# run_egress CURL_OUTPUT -> exercise _check_tunnel_egress with a curl PATH-shim
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
		$EGRESS_FN
		$FLOAT_FN
		_check_tunnel_egress
	" 2>/dev/null
	rc=$?
	rm -rf "$d"
	return $rc
}

# --- extract the egress-streak tail of check_vpn_health ---
extract_tail() {
	awk '
		/rm -f "\$tmp_g"/ { in_blk=1 }
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
$TAIL
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
$TAIL
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
grep -q '_egress_auth_bump' "$WATCHDOG" && ok "T7 auth bump present" || bad "T7 auth bump missing"

echo "T8: injection - degraded counted as dead must be caught"
INJ=$(mktemp /tmp/dt_inj_XXXXXX)
cp "$WATCHDOG" "$INJ"
python3 - "$WATCHDOG" "$INJ" << 'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = '\t\telif [ "$_es_rc" -eq 2 ]; then'
new = '\t\telif false; then'
assert old in s, "degraded branch missing"
s = s.replace(old, new, 1)
open(dst, 'w').write(s)
PY
INJ_TAIL=$(extract_tail "$INJ")
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
$INJ_TAIL
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

# =========================================================================
# Consolidated Argv Setup Budget Tests (T9..T14)
# =========================================================================

run_egress_argv() {
	local setup_time="$1"
	local d rc
	d=$(mktemp -d)
	mkdir -p "$d/bin"
	cat > "$d/bin/curl" <<SHIM
#!/bin/sh
ct=999
mt=999
prev=""
for arg in "\$@"; do
	case "\$prev" in
		--connect-timeout) ct="\$arg" ;;
		--max-time) mt="\$arg" ;;
	esac
	prev=""
	case "\$arg" in
		--connect-timeout) prev="--connect-timeout" ;;
		--max-time) prev="--max-time" ;;
	esac
done
sim_time=$setup_time
if awk -v s="\$sim_time" -v c="\$ct" 'BEGIN { exit !(s > c) }'; then
	echo "000 \$sim_time"
	exit 28
fi
if awk -v s="\$sim_time" -v m="\$mt" 'BEGIN { exit !(s > m) }'; then
	echo "000 \$sim_time"
	exit 28
fi
echo "204 \$sim_time"
exit 0
SHIM
	chmod +x "$d/bin/curl"
	PATH="$d/bin:$PATH" bash -c "
		$CONSTS
		log() { :; }
		$EGRESS_FN
		$FLOAT_FN
		_check_tunnel_egress
	" 2>/dev/null
	rc=$?
	rm -rf "$d"
	return $rc
}

echo "T9: argv setup 4s -> healthy (exit 0)"
run_egress_argv 4.0; RC=$?
if [ "$RC" = "0" ]; then ok "T9 setup 4s healthy"; else bad "T9 rc=$RC want 0"; fi

echo "T10: argv setup 8s -> degraded (exit 2)"
run_egress_argv 8.0; RC=$?
if [ "$RC" = "2" ]; then ok "T10 setup 8s degraded"; else bad "T10 rc=$RC want 2"; fi

echo "T11: argv setup 2s -> healthy (exit 0)"
run_egress_argv 2.0; RC=$?
if [ "$RC" = "0" ]; then ok "T11 setup 2s healthy"; else bad "T11 rc=$RC want 0"; fi

echo "T12: argv setup 16s with total 15 -> dead (exit 1)"
run_egress_argv 16.0; RC=$?
if [ "$RC" = "1" ]; then ok "T12 setup 16s dead"; else bad "T12 rc=$RC want 1"; fi

echo "T13: argv setup 5s (threshold boundary) -> healthy (exit 0)"
run_egress_argv 5.0; RC=$?
if [ "$RC" = "0" ]; then ok "T13 setup 5s boundary healthy"; else bad "T13 rc=$RC want 0"; fi

echo "T14: argv setup 12s -> degraded (exit 2)"
run_egress_argv 12.0; RC=$?
if [ "$RC" = "2" ]; then ok "T14 setup 12s degraded"; else bad "T14 rc=$RC want 2"; fi

# =========================================================================
# Consolidated _verify_surflare_upgrade Consumer Tests (T15..T22)
# =========================================================================

run_upgrade() {
	local local_rc="$1"; shift
	local egress_rcs=("$@")
	local d
	d=$(mktemp -d)
	local poll_file="$d/poll_count"
	echo 0 > "$poll_file"
	local egress_file="$d/egress_codes"
	printf '%s\n' "${egress_rcs[@]}" > "$egress_file"
	local egress_called="$d/egress_called"
	local rc=0
	bash -c "
		SURFLARE_UPGRADE_VERIFY=90
		SURFLARE_UPGRADE_POLL=10
		log() { :; }
		sleep() {
			local n=\${1:-0}
			local cur=\$(cat '$poll_file' 2>/dev/null || echo 0)
			echo \$((cur + n)) > '$poll_file'
		}
		check_vpn_local_state() { return $local_rc; }
		_check_tunnel_egress() {
			touch '$egress_called'
			local idx=\$(cat '$poll_file' 2>/dev/null || echo 0)
			local pick=\$(( idx / 10 ))
			local lines=\$(wc -l < '$egress_file')
			[ \"\$lines\" -gt 0 ] || return 1
			pick=\$(( pick % lines ))
			local code
			code=\$(sed -n \"\$((pick + 1))p\" '$egress_file')
			return \"\${code:-1}\"
		}
		$UPGRADE_FN
		_verify_surflare_upgrade
	" 2>/dev/null
	rc=$?
	if [ -f "$egress_called" ]; then
		EGRESS_INVOKED=1
	else
		EGRESS_INVOKED=0
	fi
	rm -rf "$d"
	return $rc
}

echo "T15: upgrade all degraded (rc=2) -> pass (exit 0)"
run_upgrade 0 2 2 2 2 2 2 2 2 2; RC=$?
if [ "$RC" = "0" ]; then ok "T15 upgrade all degraded passes"; else bad "T15 rc=$RC want 0"; fi

echo "T16: upgrade sequence 1/2/1/2 (degraded resets counter) -> pass (exit 0)"
run_upgrade 0 1 2 1 2 1 2 1 2 1; RC=$?
if [ "$RC" = "0" ]; then ok "T16 upgrade 1/2/1/2 passes"; else bad "T16 rc=$RC want 0"; fi

echo "T17: upgrade all healthy (rc=0) -> pass (exit 0)"
run_upgrade 0 0 0 0 0 0 0 0 0 0; RC=$?
if [ "$RC" = "0" ]; then ok "T17 upgrade all healthy passes"; else bad "T17 rc=$RC want 0"; fi

echo "T18: upgrade all dead (rc=1) -> rollback (exit 1)"
run_upgrade 0 1 1 1 1 1 1 1 1 1; RC=$?
if [ "$RC" = "1" ]; then ok "T18 upgrade all dead rolls back"; else bad "T18 rc=$RC want 1"; fi

echo "T19: upgrade local failure rc=1 -> immediate rollback (exit 1) without calling egress"
EGRESS_INVOKED=0
run_upgrade 1 0 0 0 0 0 0 0 0 0; RC=$?
if [ "$RC" = "1" ] && [ "$EGRESS_INVOKED" = "0" ]; then
	ok "T19 upgrade local fail rc=1 rolls back without egress"
else
	bad "T19 rc=$RC (want 1) egress_invoked=$EGRESS_INVOKED (want 0)"
fi

echo "T20: upgrade local failure rc=2 -> immediate rollback (exit 1) without calling egress"
EGRESS_INVOKED=0
run_upgrade 2 0 0 0 0 0 0 0 0 0; RC=$?
if [ "$RC" = "1" ] && [ "$EGRESS_INVOKED" = "0" ]; then
	ok "T20 upgrade local fail rc=2 rolls back without egress"
else
	bad "T20 rc=$RC (want 1) egress_invoked=$EGRESS_INVOKED (want 0)"
fi

echo "T21: upgrade sequence 1/1 (two consecutive dead) -> rollback (exit 1)"
run_upgrade 0 1 1 0 0 0 0 0 0 0; RC=$?
if [ "$RC" = "1" ]; then ok "T21 upgrade 1/1 rolls back"; else bad "T21 rc=$RC want 1"; fi

echo "T22: upgrade unknown nonzero egress (rc=3) -> rollback (exit 1)"
run_upgrade 0 3 3 3 3 3 3 3 3 3; RC=$?
if [ "$RC" = "1" ]; then ok "T22 upgrade unknown nonzero rolls back"; else bad "T22 rc=$RC want 1"; fi

# =========================================================================
# Consolidated G1 Blindspot Detection Tests (T23..T25)
# =========================================================================

extract_g1() {
	awk '
		/# G1 blindspot detection:/ { in_blk=1 }
		in_blk {
			if (/^\tif /) depth++
			if (depth > 0) print
			if (/^\tfi$/) { depth--; if (depth == 0) exit }
		}
	' "$1"
}
G1_BLOCK=$(extract_g1 "$WATCHDOG")
[ -n "$G1_BLOCK" ] || { echo "FATAL: G1 extract empty"; exit 1; }

run_g1() {
	local result_in="$1" egress_rc="$2"
	local d tmp_proxy
	d=$(mktemp -d)
	tmp_proxy="$d/proxy"
	printf 'FAIL\n' > "$tmp_proxy"
	bash -c "
		result='$result_in'
		tmp_proxy='$tmp_proxy'
		_check_tunnel_egress() { return $egress_rc; }
		log() { echo \"LOG: \$*\"; }
		run() {
$G1_BLOCK
		}
		run
		echo \"FINAL_RESULT=\$result\"
	" 2>/dev/null
	rm -rf "$d"
}

echo "T23: G1 dead (rc=1) -> logs miss and preserves verdict"
OUT23=$(run_g1 TUNNEL_OK 1)
if echo "$OUT23" | grep -q 'LOG:.*miss' && echo "$OUT23" | grep -q 'FINAL_RESULT=TUNNEL_OK'; then
	ok "T23 G1 dead logs miss and preserves verdict"
else
	bad "T23 G1 dead failed: output was $OUT23"
fi

echo "T24: G1 degraded (rc=2) -> NO miss log and preserves verdict"
OUT24=$(run_g1 TUNNEL_OK 2)
if echo "$OUT24" | grep -q 'LOG:.*miss'; then
	bad "T24 G1 degraded logged miss (should not log miss)"
elif ! echo "$OUT24" | grep -q 'FINAL_RESULT=TUNNEL_OK'; then
	bad "T24 G1 degraded changed verdict: output was $OUT24"
else
	ok "T24 G1 degraded no miss log and preserves verdict"
fi

echo "T25: G1 healthy (rc=0) -> NO miss log and preserves verdict"
OUT25=$(run_g1 TUNNEL_OK 0)
if echo "$OUT25" | grep -q 'LOG:.*miss'; then
	bad "T25 G1 healthy logged miss (should not log miss)"
elif ! echo "$OUT25" | grep -q 'FINAL_RESULT=TUNNEL_OK'; then
	bad "T25 G1 healthy changed verdict: output was $OUT25"
else
	ok "T25 G1 healthy no miss log and preserves verdict"
fi

# Edge-only degraded logging: log on enter and on leave, not every slow
# probe.  A 75h soak at 5-7s currently reprints "egress degraded" each
# health cycle; the band itself is working (T2/T10/T14).  These cases
# exercise the product helper twice in one process so the latch is visible.
run_egress_pair() {
	local first="$1" second="$2"
	local d
	d=$(mktemp -d)
	mkdir -p "$d/bin"
	cat > "$d/bin/curl" <<SHIM
#!/bin/sh
n=0
[ -f "$d/n" ] && n=\$(cat "$d/n")
n=\$((n + 1))
echo "\$n" > "$d/n"
# One _check_tunnel_egress call probes 3 URLs and keeps the fastest.
# First three curls belong to the first call, the rest to the second.
if [ "\$n" -le 3 ]; then
	echo "$first"
	exit 0
fi
echo "$second"
exit 0
SHIM
	chmod +x "$d/bin/curl"
	PATH="$d/bin:$PATH" bash -c "
		$CONSTS
		log() { echo \"LOG: \$*\"; }
		$EGRESS_FN
		$FLOAT_FN
		_check_tunnel_egress
		echo RC1=\$?
		_check_tunnel_egress
		echo RC2=\$?
	" 2>/dev/null
	rm -rf "$d"
}

run_egress_triple() {
	local first="$1" second="$2" third="$3"
	local d
	d=$(mktemp -d)
	mkdir -p "$d/bin"
	cat > "$d/bin/curl" <<SHIM
#!/bin/sh
n=0
[ -f "$d/n" ] && n=\$(cat "$d/n")
n=\$((n + 1))
echo "\$n" > "$d/n"
# Call 1: 3 curls. Call 2: up to 6 (empty _best_t retries a second
# pass). Call 3: the rest.
if [ "\$n" -le 3 ]; then
	echo "$first"
	exit 0
fi
if [ "\$n" -le 9 ]; then
	echo "$second"
	exit 0
fi
echo "$third"
exit 0
SHIM
	chmod +x "$d/bin/curl"
	PATH="$d/bin:$PATH" bash -c "
		$CONSTS
		log() { echo \"LOG: \$*\"; }
		$EGRESS_FN
		$FLOAT_FN
		_check_tunnel_egress
		echo RC1=\$?
		_check_tunnel_egress
		echo RC2=\$?
		_check_tunnel_egress
		echo RC3=\$?
	" 2>/dev/null
	rm -rf "$d"
}

echo "T26: two slow answers in one process -> one enter log, two rc=2"
OUT26=$(run_egress_pair "204 12.0" "204 12.0")
enter_n=$(printf '%s\n' "$OUT26" | grep -c 'LOG: egress degraded: best target' || true)
leave_n=$(printf '%s\n' "$OUT26" | grep -c 'LOG: egress recovered:' || true)
if echo "$OUT26" | grep -q 'RC1=2' && echo "$OUT26" | grep -q 'RC2=2' \
	&& [ "$enter_n" = "1" ] && [ "$leave_n" = "0" ]; then
	ok "T26 stay-degraded logs once"
else
	bad "T26 stay-degraded: enter=$enter_n leave=$leave_n out=$OUT26"
fi

echo "T27: slow then fast in one process -> enter then recovered"
OUT27=$(run_egress_pair "204 12.0" "204 1.5")
enter_n=$(printf '%s\n' "$OUT27" | grep -c 'LOG: egress degraded: best target' || true)
leave_n=$(printf '%s\n' "$OUT27" | grep -c 'LOG: egress recovered:' || true)
if echo "$OUT27" | grep -q 'RC1=2' && echo "$OUT27" | grep -q 'RC2=0' \
	&& [ "$enter_n" = "1" ] && [ "$leave_n" = "1" ]; then
	ok "T27 leave-degraded logs recovered"
else
	bad "T27 leave-degraded: enter=$enter_n leave=$leave_n out=$OUT27"
fi

echo "T28: slow then dead in one process -> enter, no recovered, rc=1"
OUT28=$(run_egress_pair "204 12.0" "000 30.0")
enter_n=$(printf '%s\n' "$OUT28" | grep -c 'LOG: egress degraded: best target' || true)
leave_n=$(printf '%s\n' "$OUT28" | grep -c 'LOG: egress recovered:' || true)
if echo "$OUT28" | grep -q 'RC1=2' && echo "$OUT28" | grep -q 'RC2=1' \
	&& [ "$enter_n" = "1" ] && [ "$leave_n" = "0" ]; then
	ok "T28 leave-to-dead clears latch without recovered"
else
	bad "T28 leave-to-dead: enter=$enter_n leave=$leave_n out=$OUT28"
fi

echo "T29: slow then dead then fast -> no recovered (latch cleared on dead)"
OUT29=$(run_egress_triple "204 12.0" "000 30.0" "204 1.5")
enter_n=$(printf '%s\n' "$OUT29" | grep -c 'LOG: egress degraded: best target' || true)
leave_n=$(printf '%s\n' "$OUT29" | grep -c 'LOG: egress recovered:' || true)
if echo "$OUT29" | grep -q 'RC1=2' && echo "$OUT29" | grep -q 'RC2=1' \
	&& echo "$OUT29" | grep -q 'RC3=0' \
	&& [ "$enter_n" = "1" ] && [ "$leave_n" = "0" ]; then
	ok "T29 dead clears latch; healthy stays silent"
else
	bad "T29 dead-then-healthy: enter=$enter_n leave=$leave_n out=$OUT29"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
