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

CONSTS=$(grep -E '^TPROXY_503_ROTATE_THRESHOLD=|^NODE_HEALTH_WINDOW=|^STORM_503_STATE=|^NODE_HEALTH_FILE=' "$WATCHDOG")

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

echo "V1: OK + urltest storm file + fresh tproxy http_503=0 -> stay OK"
# age=10: NODE_HEALTH_FILE exists, mtime inside NODE_HEALTH_WINDOW, http_503=0.
# Distinct from V5 (empty age = no health file).
OUT=$(run_tail "$WATCHDOG" OK OK 0 20 0 10)
[ "$OUT" = "OK" ] && ok "V1 storm file does not override with fresh http_503=0" || bad "V1 got $OUT want OK"

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
# Anchor on the live tproxy-override comment.
# Insert a STORM_503_STATE trip immediately before the result==OK
# gate that follows it.
cp "$WATCHDOG" "$INJ"
python3 - "$WATCHDOG" "$INJ" << 'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# Anchor on the live tproxy-override comment (unique in check_vpn_health
# tail). Insert a STORM_503_STATE trip immediately before the result==OK
# gate that follows it -- not rfind on the whole file.
anchor = s.find("# tproxy 503 override")
assert anchor >= 0, "tproxy override comment missing"
gate = 'if [ "$result" = "OK" ] || [ "$result" = "TUNNEL_OK" ]; then'
last = s.find(gate, anchor)
assert last > anchor, "OK/TUNNEL_OK gate missing after tproxy override"
inject = '''if [ -f "$STORM_503_STATE" ]; then
		result="PROXY_BROKEN"
	fi
	'''
s2 = s[:last] + inject + s[last:]
assert s2 != s, "V-inject did not change the source"
open(dst, "w").write(s2)
PY
OUT=$(run_tail "$INJ" OK OK 0 20 0 10)
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
# Production no longer raises fail_count here. Splice it back at the
# start of the cur_err-threshold body so R1 would go 4. Identity copy
# is not an injection -- refuse it.
rot = s.split("_handle_proactive_node_rotation()", 1)[1].split("\nconnect_vpn() {", 1)[0]
assert "fail_count=$FAIL_THRESHOLD" not in rot, \
    "production already raises fail_count; R-inject would be a no-op"
n = s.find('if [ "${_cur_err:-0}" -ge "$NODE_ERR_ROTATE_THRESHOLD" ]; then')
assert n > 0, "rotation threshold gate missing"
brace = s.find("\n", n)
s2 = s[:brace+1] + '\t\tfail_count=$FAIL_THRESHOLD\n' + s[brace+1:]
assert s2 != s, "R-inject did not change the source"
open(dst, "w").write(s2)
PY
OUT=$(run_rot "$INJ" 50 0)
[ "$OUT" = "4" ] && ok "R-inject restore rotate flips R1" || bad "R-inject got $OUT want 4"
rm -f "$INJ"

# H1: OK-path tproxy rotate must read .tproxy.categories.http_503,
# not the last "http_503" in the file (nodes also carry that key).
extract_tproxy_ok() {
	awk '
		/# Tproxy health check:/ { in_blk=1 }
		in_blk { print }
		in_blk && /# Proactive node-error rotation:/ { exit }
	' "$1"
}
run_tproxy_ok() {
	local wd="$1" json="$2"
	local d nh
	d=$(mktemp -d)
	nh="$d/nh.json"
	printf '%s\n' "$json" > "$nh"
	bash -c "
		NODE_HEALTH_WINDOW=600
		TPROXY_503_ROTATE_THRESHOLD=5
		TPROXY_503_COOLDOWN=660
		NODE_HEALTH_FILE='$nh'
		fail_count=0
		FAIL_THRESHOLD=4
		_tproxy_503_cooldown_until=0
		_tproxy_503_rotate_ts=0
		log() { :; }
		run() {
$(extract_tproxy_ok "$wd")
		}
		run
		echo \$fail_count
	" 2>/dev/null
	rm -rf "$d"
}
# tproxy has no http_503 key; nodes does. grep -o last-match would
# rotate on 9; jq .tproxy.categories.http_503 must stay 0.
MIXED='{"tproxy":{"categories":{"loopback_reject":0}},"nodes":{"x":{"http_503":9}}}'
REAL='{"tproxy":{"categories":{"http_503":5}},"nodes":{"x":{"http_503":0}}}'
echo "H1a: tproxy=0 + nodes.http_503=9 -> fail_count stays 0"
OUT=$(run_tproxy_ok "$WATCHDOG" "$MIXED")
[ "$OUT" = "0" ] && ok "H1a ignores nodes http_503" || bad "H1a got $OUT want 0"
echo "H1b: tproxy=5 -> fail_count=4"
OUT=$(run_tproxy_ok "$WATCHDOG" "$REAL")
[ "$OUT" = "4" ] && ok "H1b tproxy 503 still rotates" || bad "H1b got $OUT want 4"

echo "H2: rotation comment must not teach fail_count raise"
rot_hdr=$(sed -n '/^# Proactive node-error rotation:/,/^_handle_proactive_node_rotation()/{p;}' "$WATCHDOG")
if printf '%s\n' "$rot_hdr" | grep -q 'raising fail_count'; then
	bad "H2 comment still says raising fail_count"
else
	ok "H2 rotation comment matches body"
fi

echo "H3: dead storm-override constants are not live assignments"
if grep -E '^STORM_503_OVERRIDE_COUNT=|^STORM_503_HOLD_MAX=|^STORM_503_OVERRIDE_WINDOW=' "$WATCHDOG" | grep -v '^#'; then
	bad "H3 dead constants still assigned"
else
	ok "H3 dead constants gone"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
