#!/bin/bash
# Egress streak verdict: user-path death signature from repeated
# _check_tunnel_egress failures.  A single egress miss must NOT flip the
# verdict (transient CDN blip); N consecutive misses within the streak
# window DO flip OK/TUNNEL_OK -> PROXY_BROKEN, because every health
# check re-dials through the same sing-box user path the LAN rides.
#
# Ground truth (2026-09-07 P0, /var/log/surflare + logread):
#   outage 18:29-20:53 -> "Tunnel egress check failed" every ~60s for 2.4h
#   healthy days       -> isolated single misses, max streak 1-2
# The dead-axis guard (2026-09-04) stays: one miss = log only.
#
# Also: surflare_log_health.sh must expose a user_path axis so the
# observability layer can see what the verdict acts on.

set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PARSER=surflare_log_health.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# --- extract the egress-streak tail of check_vpn_health ---
extract_tail() {
	awk '
		/# Probe 7 tests a single target/ { in_blk=1 }
		in_blk { print }
		in_blk && /echo "\$result"/ { exit }
	' "$1"
}

TAIL=$(extract_tail "$WATCHDOG")
[ -n "$TAIL" ] || { echo "FATAL: tail extract empty"; exit 1; }
printf '%s\n' "$TAIL" | grep -q '_check_tunnel_egress' \
	|| { echo "FATAL: tail missing egress call"; exit 1; }

CONSTS=$(grep -E '^EGRESS_STREAK_THRESHOLD=|^EGRESS_STREAK_WINDOW=' "$WATCHDOG")
[ -n "$CONSTS" ] || { echo "FATAL: EGRESS_STREAK_* constants missing"; exit 1; }

# run_tail WD RESULT EGRESS_RC STREAK_STATE
# EGRESS_RC 0 = egress probe passes; STREAK_STATE = "3 1788600000" (count, ts)
# or "" / "0 0" for fresh.
run_tail() {
	local wd="$1" result_in="$2" egress_rc="$3" streak="$4"
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
$(extract_tail "$wd")
		}
		run
	" 2>/dev/null
	rm -rf "$d"
}

echo "T1: OK + egress pass -> OK, streak reset"
OUT=$(run_tail "$WATCHDOG" OK 0 "")
[ "$OUT" = "OK" ] && ok "T1 egress pass keeps OK" || bad "T1 got $OUT want OK"

echo "T2: OK + 1 egress miss -> stays OK (anti-jitter guard intact)"
OUT=$(run_tail "$WATCHDOG" OK 1 "")
[ "$OUT" = "OK" ] && ok "T2 single miss no flip" || bad "T2 got $OUT want OK"

echo "T3: OK + 3rd consecutive miss (threshold) -> PROXY_BROKEN"
# streak file pre-seeded with 2 prior misses, ts fresh
NOW=$(date +%s)
OUT=$(run_tail "$WATCHDOG" OK 1 "2 $NOW")
[ "$OUT" = "PROXY_BROKEN" ] && ok "T3 streak threshold flips" || bad "T3 got $OUT want PROXY_BROKEN"

echo "T4: OK + 3 misses but oldest outside window -> stays OK"
OUT=$(run_tail "$WATCHDOG" OK 1 "2 $((NOW - 9999))")
[ "$OUT" = "OK" ] && ok "T4 stale streak expires" || bad "T4 got $OUT want OK"

echo "T5: TUNNEL_OK + threshold streak -> PROXY_BROKEN"
OUT=$(run_tail "$WATCHDOG" TUNNEL_OK 1 "2 $NOW")
[ "$OUT" = "PROXY_BROKEN" ] && ok "T5 TUNNEL_OK flips too" || bad "T5 got $OUT want PROXY_BROKEN"

echo "T6: CN verdict + threshold streak -> stays CN"
# CN verdict must not be re-classified by egress; caller handles CN separately
OUT=$(run_tail "$WATCHDOG" CN 1 "2 $NOW")
[ "$OUT" = "CN" ] && ok "T6 CN not overridden" || bad "T6 got $OUT want CN"

echo "T7: streak file grows across misses (state machine sanity)"
d=$(mktemp -d)
sp="$d/sp"
printf '1 %s\n' "$(date +%s)" > "$sp"
OUT=$(bash -c "
	$CONSTS
	EGRESS_STREAK_STATE='$sp'
	result='OK'
	log() { :; }
	_check_tunnel_egress() { return 1; }
	run() {
$(extract_tail "$WATCHDOG")
	}
	run
" 2>/dev/null)
read -r cnt _ < "$sp"
[ "$cnt" = "2" ] && ok "T7 streak count 1->2 persisted" || bad "T7 streak count got $cnt want 2"
rm -rf "$d"

echo "T8: injection - remove the streak flip -> T3 must fail"
INJ=$(mktemp /tmp/es_inj_XXXXXX)
cp "$WATCHDOG" "$INJ"
python3 - "$WATCHDOG" "$INJ" << 'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
flip = 'result="PROXY_BROKEN"'
# The streak flip is the ONLY assignment after the tproxy-override block;
# find it inside the egress-streak block and delete that line.
anchor = s.find("# Egress-streak override")
assert anchor > 0, "egress-streak block missing"
seg = s[anchor:]
assert flip in seg, "flip assignment missing in streak block"
s2 = s[:anchor] + seg.replace(flip, 'result="$result"  # removed by T8 injection', 1)
assert s2 != s, "T8 injection is a no-op"
open(dst, "w").write(s2)
PY
NOW=$(date +%s)
OUT=$(run_tail "$INJ" OK 1 "2 $NOW")
[ "$OUT" = "OK" ] && ok "T8 inject: no flip -> stays OK (test catches removal)" || bad "T8 inject got $OUT want OK"
rm -f "$INJ"

# --- parser axis: surflare_log_health.sh user_path counters ---
echo "P1: parser counts user-path socks errors, not urltest/direct"
d=$(mktemp -d)
LF="$d/proxy.log"
NOW_H=$(TZ=Asia/Shanghai date +%H:%M:%S)
NOW_D=$(TZ=Asia/Shanghai date +%Y-%m-%d)
OLD_H=$(TZ=Asia/Shanghai date -d '2 hours ago' +%H:%M:%S)
OLD_D=$(TZ=Asia/Shanghai date -d '2 hours ago' +%Y-%m-%d)
cat > "$LF" << EOF
+0800 $NOW_D $NOW_H ERROR [111 1.0s] outbound/urltest[mh_via_Washington_to_private_576]: unexpected status: 503 Service Unavailable
+0800 $NOW_D $NOW_H ERROR [222 5.0s] connection: open connection to 54.186.46.130:80 using outbound/socks[last_hop_public_29_to_private_576]: authentication required
+0800 $NOW_D $NOW_H ERROR [333 2.0s] connection: open connection to 172.217.117.4:443 using outbound/direct[direct]: dial tcp 172.217.117.4:443: i/o timeout
+0800 $NOW_D $NOW_H ERROR [444 0ms] connection: open connection to 127.0.0.1:10800 using outbound/direct[direct]: dial tcp 127.0.0.1:10800: operation was canceled
+0800 $NOW_D $NOW_H ERROR [555 3.0s] connection: open connection to 61.155.167.47:80 using outbound/socks[last_hop_public_29_to_private_576]: dial tcp 152.32.224.1:443: i/o timeout
+0800 $OLD_D $OLD_H ERROR [666 3.0s] connection: open connection to 61.155.167.47:80 using outbound/socks[last_hop_public_29_to_private_576]: dial tcp 152.32.224.1:443: i/o timeout
EOF
bash "$PARSER" --log "$LF" --window-minutes 30 --out "$d/nh.json" >/dev/null 2>&1
UP_SOCKS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user_path"]["socks_errors"])' "$d/nh.json" 2>/dev/null)
UP_AUTH=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user_path"]["auth_required"])' "$d/nh.json" 2>/dev/null)
[ "$UP_SOCKS" = "2" ] && ok "P1 socks_errors=2 (auth + socks dial timeout, windowed)" || bad "P1 socks_errors got '$UP_SOCKS' want 2"
[ "$UP_AUTH" = "1" ] && ok "P1 auth_required=1 (windowed, old line excluded)" || bad "P1 auth_required got '$UP_AUTH' want 1"
rm -rf "$d"

echo "P2: parser handles empty log / empty axis"
d=$(mktemp -d)
: > "$d/empty.log"
bash "$PARSER" --log "$d/empty.log" --window-minutes 10 --out "$d/nh.json" >/dev/null 2>&1
[ -f "$d/nh.json" ] && ok "P2 parser writes output for empty log" || bad "P2 no output"
UP_SOCKS0=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user_path"]["socks_errors"])' "$d/nh.json" 2>/dev/null)
[ "$UP_SOCKS0" = "0" ] && ok "P2 empty axis = 0" || bad "P2 socks_errors got '$UP_SOCKS0' want 0"
rm -rf "$d"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
