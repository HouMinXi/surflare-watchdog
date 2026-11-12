#!/bin/bash
# Zoro primary is manual. While the requested state is on and the nft rule is
# still present, a dead SOCKS uplink must be reported. It must not be switched
# off by the watchdog: that decision stays with the operator.
#
# The function is extracted from the production script and driven against
# nft/curl/alert stubs. A pass proves the production body, not a copy.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

awk '/^_zoro_uplink_alert\(\) \{/ { i = 1 }
	i { print }
	i && /^}$/ { exit }' "$WD" > "$TMP/func.sh"
if [ ! -s "$TMP/func.sh" ] || [ "$(wc -l < "$TMP/func.sh")" -gt 110 ]; then
	bad "could not extract _zoro_uplink_alert"
	echo "RESULT: $pass passed, $fail failed"
	exit 1
fi

run_case() {
	: > "$TMP/alerts"
	: > "$TMP/log"
	: > "$TMP/off_calls"
	Nft_rc="$1"
	Nft_output="$2"
	Probe_code="$3"
	ZORO_STATE_FILE="$TMP/state"
	ZORO_ALERT_STAMP_DIR="$TMP/surflare"
	export Nft_rc Nft_output Probe_code ZORO_STATE_FILE ZORO_ALERT_STAMP_DIR TMP
	bash -c '
			. "$1"
			nft() {
				case "$1" in
				list) printf "%s\n" "$Nft_output"; return "$Nft_rc" ;;
				*) return 1 ;;
				esac
			}
			curl() { printf "%s" "$Probe_code"; return 0; }
			switch_cmd() { printf "%s\n" "$*" >> "$TMP/off_calls"; }
			log() { printf "%s\n" "$*" >> "$TMP/log"; }
			_deliver_alert() { printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" >> "$TMP/alerts"; }
			_zoro_uplink_alert
			sleep 0.2
		' _ "$TMP/func.sh" >/dev/null 2>&1
}

# 1: requested off is not an uplink to watch
printf 'off\n' > "$TMP/state"
run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 000
if [ ! -s "$TMP/alerts" ] && [ ! -s "$TMP/off_calls" ]; then
	ok "requested off is silent and does not switch"
else
	bad "requested off was not silent"
fi

# 2: on, rule present, probe 000 -> one alert, no off
printf 'on\n' > "$TMP/state"
rm -f "$TMP/surflare/zoro_uplink_down.stamp"
run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 000
if [ "$(grep -c '^surflare: Zoro uplink down|' "$TMP/alerts")" -eq 1 ] \
	&& grep -q 'fault:zoro-uplink-down' "$TMP/alerts" \
	&& grep -q 'return to Surflare by hand' "$TMP/alerts" \
	&& grep -q '|yes|' "$TMP/alerts" \
	&& [ ! -s "$TMP/off_calls" ]; then
	ok "dead uplink raises one alert and does not switch off"
else
	bad "dead uplink did not raise the expected alert-only page"
fi

# 3: on, rule present, probe 204 -> silent
printf 'on\r\n' > "$TMP/state"
run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 204
if [ ! -s "$TMP/alerts" ] && [ ! -s "$TMP/off_calls" ]; then
	ok "HTTP 204 is healthy after CR/LF normalization"
else
	bad "healthy probe alerted or switched"
fi

# 4: private stamp suppresses a repeat within one hour
printf 'on\n' > "$TMP/state"
mkdir -p "$TMP/surflare"
rm -f "$TMP/surflare/zoro_uplink_down.stamp"
run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 000
first=$(grep -c '^surflare: Zoro uplink down|' "$TMP/alerts")
run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 000
second=$(grep -c '^surflare: Zoro uplink down|' "$TMP/alerts")
if [ "$first" -eq 1 ] && [ "$second" -eq 0 ]; then
	ok "private stamp suppresses a repeat downlink page"
else
	bad "private stamp did not suppress the repeat"
fi

# 5: no rule means mode-loss owns the page; uplink stays quiet
printf 'on\n' > "$TMP/state"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 000
if [ ! -s "$TMP/alerts" ]; then
	ok "missing Zoro rule is not an uplink fault"
else
	bad "missing Zoro rule raised an uplink alert"
fi

# 5b: a last-probe time in the future must not starve the probe
printf 'on\n' > "$TMP/state"
: > "$TMP/alerts"
rm -f "$TMP/surflare/zoro_uplink_down.stamp"
bash -c '
		CURLS=$5
		. "$1"
		nft() { printf "%s\n" "comment \"zoro-exit\""; return 0; }
		curl() {
			printf 000
			printf "now=%s last=%s\n" "${_now:-}" "${_last:-}" >> "$CURLS"
		}
		_deliver_alert() { printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" >> "$TMP/alerts"; }
		: > "$CURLS"
		_zoro_uplink_last=$(($(date +%s) + 3600))
		ZORO_STATE_FILE="$3"
		ZORO_ALERT_STAMP_DIR="$4"
		ZORO_UPLINK_SUPPRESS=0
		WALL=$(command date +%s)
		_zoro_uplink_alert
		sleep 0.2
		date() { echo $((WALL + 301)); }
		_zoro_uplink_alert
		sleep 0.2
	' _ "$TMP/func.sh" "$TMP/alerts" "$TMP/state" "$TMP/surflare" "$TMP/curls" >/dev/null 2>&1
second_last=$(sed -n '2s/.*last=//p' "$TMP/curls" | tr -cd '0-9')
# The second probe's _last is the value read from the first write (~WALL).
# A hardcoded _last=0 never reaches curl with last in [WALL-5, WALL+5],
# because  (WALL+301) - 0 is huge but the read value itself is 0.
if [ "$(grep -c '^surflare: Zoro uplink down|' "$TMP/alerts")" -eq 2 ] \
	&& [ -n "$second_last" ] && [ "$second_last" -ge $(( $(date +%s) - 30)) ]; then
	ok "second probe read the time the first probe stored"
else
	bad "second probe did not read the stored time (last=$second_last)"
fi

echo "RESULT: $pass passed, $fail failed"
# 6: the healthy branch of the production loop calls the probe
_call=$(grep -n '^[[:space:]]*_zoro_uplink_alert$' "$WD" | cut -d: -f1)
_hb=$(grep -n 'VPN healthy: exit=' "$WD" | cut -d: -f1)
if [ -n "$_call" ] && [ -n "$_hb" ] && [ "$_hb" -lt "$_call" ]; then
	ok "healthy branch calls the uplink probe"
else
	bad "healthy branch does not call the uplink probe"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
