#!/bin/bash
# User-path verdict: PROXY_BROKEN only from tproxy 503, never urltest
# storm files or N100 egress-curl failure. Extracted from production.
#
# shellcheck disable=SC2015
# shellcheck disable=SC2016
set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Tail of check_vpn_health: Probe 7 confirm + egress + 503 override
# through echo "$result". Must stay inside a function (uses local).
extract_tail() {
	awk '
		/# Probe 7 tests a single target/ { in_blk=1 }
		in_blk { print }
		in_blk && /echo "\$result"/ { exit }
	' "$1"
}

TAIL=$(extract_tail "$WATCHDOG")
printf '%s\n' "$TAIL" | grep -q '_check_tunnel_egress' || { echo "FATAL: tail extract missing egress"; exit 1; }
printf '%s\n' "$TAIL" | grep -q 'echo "\$result"' || { echo "FATAL: tail extract missing echo"; exit 1; }

CONSTS=$(grep -E '^STORM_503_OVERRIDE_COUNT=|^STORM_503_OVERRIDE_WINDOW=|^TPROXY_503_ROTATE_THRESHOLD=|^NODE_HEALTH_WINDOW=|^STORM_503_STATE=|^NODE_HEALTH_FILE=' "$WATCHDOG")

# run_tail WD RESULT TMP_PROXY EGRESS_RC STORM_COUNT TP503 AGE
# EGRESS_RC 0 = _check_tunnel_egress succeeds
# AGE = seconds ago NODE_HEALTH_FILE mtime (empty = no file)
run_tail() {
	local wd="${1:-$WATCHDOG}" result_in="$2" proxy_val="$3" egress_rc="$4"
	local storm_n="${5:-0}" tp503="${6:-0}" age="${7:-}"
	local d storm nh tmp_proxy
	d=$(mktemp -d)
	storm="$d/storm"
	nh="$d/nh.json"
	tmp_proxy="$d/proxy"
	printf '%s\n' "$proxy_val" > "$tmp_proxy"
	if [ "$storm_n" -gt 0 ]; then
		printf '%s %s %s\n' "$storm_n" "1600000000" "$(date +%s)" > "$storm"
	fi
	if [ -n "$age" ]; then
		printf '{"tproxy":{"categories":{"http_503":%s}},"nodes":{}}\n' "$tp503" > "$nh"
		touch -d "$age seconds ago" "$nh" 2>/dev/null || touch -t "$(date -d "$age seconds ago" +%Y%m%d%H%M.%S 2>/dev/null || echo 202001010000.00)" "$nh"
	fi
	local tail_src
	tail_src=$(extract_tail "$wd")
	bash -c "
		$CONSTS
		STORM_503_STATE='$storm'
		NODE_HEALTH_FILE='$nh'
		tmp_proxy='$tmp_proxy'
		result='$result_in'
		log() { :; }
		_check_tunnel_egress() { return $egress_rc; }
		run() {
$tail_src
		}
		run
	" 2>/dev/null
	rm -rf "$d"
}

echo "V1: OK + urltest storm file + tproxy 0 -> stay OK"
OUT=$(run_tail "$WATCHDOG" OK OK 0 20 0 "")
[ "$OUT" = "OK" ] && ok "V1 storm file does not override" || bad "V1 got $OUT want OK"

echo "V2: OK + tproxy http_503=5 -> PROXY_BROKEN"
OUT=$(run_tail "$WATCHDOG" OK OK 0 0 5 10)
[ "$OUT" = "PROXY_BROKEN" ] && ok "V2 tproxy 503 overrides" || bad "V2 got $OUT want PROXY_BROKEN"

echo "V3: OK + proxy FAIL + egress fail + tproxy 0 -> stay OK"
OUT=$(run_tail "$WATCHDOG" OK FAIL 1 0 0 "")
[ "$OUT" = "OK" ] && ok "V3 egress curl fail does not break" || bad "V3 got $OUT want OK"

echo "V4: TUNNEL_OK + old 5-clause storm + tproxy 0 -> stay TUNNEL_OK"
OUT=$(run_tail "$WATCHDOG" TUNNEL_OK OK 0 20 0 "")
[ "$OUT" = "TUNNEL_OK" ] && ok "V4 storm file does not override TUNNEL_OK" || bad "V4 got $OUT want TUNNEL_OK"

echo "V5: missing NODE_HEALTH_FILE + storm file -> stay OK"
OUT=$(run_tail "$WATCHDOG" OK OK 0 20 0 "")
[ "$OUT" = "OK" ] && ok "V5 missing health file fail-closed" || bad "V5 got $OUT want OK"

echo "V6: stale NODE_HEALTH_FILE (age>window) + http_503=5 -> stay OK"
OUT=$(run_tail "$WATCHDOG" OK OK 0 0 5 9999)
[ "$OUT" = "OK" ] && ok "V6 stale health file ignored" || bad "V6 got $OUT want OK"

echo "V-inject: restoring STORM_503_STATE override must flip V1"
INJ=$(mktemp /tmp/upv_inj_XXXXXX)
# identity copy -- injection asserts current code still uses STORM file;
# after the fix this block will splice the OLD 5-clause back in.
cp "$WATCHDOG" "$INJ"
# If production still reads STORM_503_STATE to set PROXY_BROKEN, V1
# already failed above. After the fix, splice the old clause in:
python3 - "$WATCHDOG" "$INJ" << 'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# After the fix the override reads NODE_HEALTH_FILE. Re-insert a
# STORM_503_STATE trip so V1 goes PROXY_BROKEN -- proves the test
# would catch a regression that restores the old gate.
old = 'if [ "$result" = "OK" ] || [ "$result" = "TUNNEL_OK" ]; then'
# only first occurrence in check_vpn_health tail is unique enough
idx = s.find('# 503 storm override')
if idx < 0:
    idx = s.find('if [ "$result" = "OK" ] || [ "$result" = "TUNNEL_OK" ]; then')
assert idx >= 0, "override anchor missing"
# prepend an unconditional storm-file override immediately before
# the result==OK gate in the tail (last occurrence before echo result)
last = s.rfind('if [ "$result" = "OK" ] || [ "$result" = "TUNNEL_OK" ]; then')
assert last > 0
inject = '''if [ -f "$STORM_503_STATE" ]; then
		result="PROXY_BROKEN"
	fi
	'''
s = s[:last] + inject + s[last:]
open(dst, "w").write(s)
PY
OUT=$(run_tail "$INJ" OK OK 0 20 0 "")
[ "$OUT" = "PROXY_BROKEN" ] && ok "inject storm-file override flips V1" || bad "V-inject got $OUT want PROXY_BROKEN"
rm -f "$INJ"

# --- Task 3: urltest error_count must not raise fail_count ---
extract_rot() {
	awk '
		/^_handle_proactive_node_rotation\(\)/ { in_blk=1 }
		in_blk { print }
		in_blk && /^}$/ { exit }
	' "$1"
}
printf '%s\n' "$(extract_rot "$WATCHDOG")" | grep -q 'NODE_ERR_ROTATE_THRESHOLD' \
	|| { echo "FATAL: rotation extract empty"; exit 1; }

ROT_CONSTS=$(grep -E '^NODE_ERR_ROTATE_THRESHOLD=|^NODE_ERR_HEALTHY_MAX=|^NODE_ERR_COOLDOWN=|^NODE_ERR_STORM_CONSECUTIVE=|^NODE_HEALTH_WINDOW=|^NODE_HEALTH_FILE=' "$WATCHDOG")

run_rot() {
	local wd="${1:-$WATCHDOG}" cur_err="${2:-50}" other_err="${3:-0}"
	local d nh now
	d=$(mktemp -d)
	nh="$d/nh.json"
	now=$(date +%s)
	printf '{"nodes":{"mh_via_Washington_to_Dallas":{"error_count":%s},"mh_via_Washington_to_Chicago":{"error_count":%s}},"tproxy":{"categories":{"http_503":0}}}\n' \
		"$cur_err" "$other_err" > "$nh"
	bash -c "
		$ROT_CONSTS
		NODE_HEALTH_FILE='$nh'
		_active_node='Dallas'
		_effective_transit='Washington'
		NODE_CANDIDATES=(Dallas Chicago)
		fail_count=0
		FAIL_THRESHOLD=4
		_node_err_cooldown_until=0
		_node_err_rotate_ts=0
		_node_err_consecutive=0
		log() { :; }
		_refresh_effective_transit() { :; }
		_enter_storm_cooldown() { :; }
		$(extract_rot "$wd")
		_handle_proactive_node_rotation $now
		echo \$fail_count
	" 2>/dev/null
	rm -rf "$d"
}

echo "R1: urltest error_count=50 + healthy candidate + tproxy 0 -> fail_count stays 0"
OUT=$(run_rot "$WATCHDOG" 50 0)
[ "$OUT" = "0" ] && ok "R1 no rotate on urltest count" || bad "R1 got $OUT want 0"

echo "R-inject: restoring fail_count=\$FAIL_THRESHOLD must flip R1"
INJ=$(mktemp /tmp/upv_rot_XXXXXX)
python3 - "$WATCHDOG" "$INJ" << 'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = 'log "urltest all-unhealthy consecutive=${_node_err_consecutive}/${NODE_ERR_STORM_CONSECUTIVE} (not rotating on probe counts)"'
# Before the production change the rotate line still exists. After the
# change we splice fail_count assignment back onto the healthy-candidate
# branch. Handle both trees:
if "fail_count=\$FAIL_THRESHOLD" in s.split("_handle_proactive_node_rotation")[1].split("connect_vpn")[0]:
    # current (pre-fix) tree already rotates -- injection is identity
    open(dst, "w").write(s)
else:
    needle = 'if [ "${_other_healthy:-0}" -ge 1 ]; then'
    # may be gone; inject after the cur_err threshold
    n = s.find("if [ \"${_cur_err:-0}\" -ge \"$NODE_ERR_ROTATE_THRESHOLD\" ]; then")
    assert n > 0
    # insert fail_count raise at start of that if-body
    brace = s.find("\n", n)
    s = s[:brace+1] + '\t\tfail_count=$FAIL_THRESHOLD\n' + s[brace+1:]
    open(dst, "w").write(s)
PY
OUT=$(run_rot "$INJ" 50 0)
[ "$OUT" = "4" ] && ok "R-inject restore rotate flips R1" || bad "R-inject got $OUT want 4"
rm -f "$INJ"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
