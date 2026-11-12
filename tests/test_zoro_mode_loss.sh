#!/bin/bash
# The Zoro primary switch lives in a manual nft rule that the Surflare
# watchdog's destroy+reload removes. The watchdog cannot re-apply it (that is
# the operator's decision), but it must not lose it silently: /etc records the
# requested state, so a missing rule with "on" is a reportable mode loss.
#
# The function is extracted from the production script and driven against nft
# and alert stubs; a pass proves the production body, not a copy.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

awk '/^_zoro_mode_loss_alert\(\) \{/ { i = 1 }
	i { print }
	i && /^}$/ { exit }' "$WD" > "$TMP/func.sh"
if [ ! -s "$TMP/func.sh" ] || [ "$(wc -l < "$TMP/func.sh")" -gt 50 ]; then
	bad "could not extract _zoro_mode_loss_alert"
	echo "RESULT: $pass passed, $fail failed"
	exit 1
fi

run_case() {
	: > "$TMP/alerts"
	: > "$TMP/log"
	Nft_rc="$1"
	Nft_output="$2"
	ZORO_STATE_FILE="$TMP/state"
	ZORO_ALERT_STAMP_DIR="$TMP/surflare"
	export Nft_rc Nft_output ZORO_STATE_FILE ZORO_ALERT_STAMP_DIR TMP
	bash -c '
			. "$1"
			nft() {
				case "$1" in
				list) printf "%s\n" "$Nft_output"; return "$Nft_rc" ;;
				*) return 1 ;;
				esac
			}
			log() { printf "%s\n" "$*" >> "$TMP/log"; }
			_deliver_alert() { printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" >> "$TMP/alerts"; }
			_zoro_mode_loss_alert
			sleep 0.2
		' _ "$TMP/func.sh" >/dev/null 2>&1
}

# 1: no requested state
rm -f "$TMP/state"
run_case 0 'iifname "br-lan" tproxy ip to :10800'
if [ ! -s "$TMP/alerts" ]; then ok "no state file is silent"; else bad "no state file alerted"; fi

# 2: deliberate off
printf 'off\n' > "$TMP/state"
run_case 0 'iifname "br-lan" tproxy ip to :10800'
if [ ! -s "$TMP/alerts" ]; then ok "requested off is silent"; else bad "requested off alerted"; fi

# 3: on and the rule is gone; the private stamp must not swallow it
printf 'on\n' > "$TMP/state"
run_case 0 'iifname "br-lan" tproxy ip to :10800'
if [ "$(grep -c "^surflare: Zoro primary mode lost|" "$TMP/alerts")" -eq 1 ] \
	&& grep -q 'fault:zoro-mode-lost' "$TMP/alerts" \
	&& grep -q 'Run: zoro-exit on' "$TMP/alerts" \
	&& grep -q '|yes|' "$TMP/alerts"; then
	ok "mode loss raises one actionable alert with the class in arg 4"
else
	bad "mode loss did not raise the expected alert"
fi

# 4: on and the rule survived
printf 'on\r\n' > "$TMP/state"
run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"'
if [ ! -s "$TMP/alerts" ]; then ok "surviving Zoro rule is silent after CR/LF normalization"; else bad "surviving rule alerted"; fi

# 5: an unreadable chain is not proof of loss
printf 'on\n' > "$TMP/state"
run_case 1 ''
if [ ! -s "$TMP/alerts" ]; then ok "unreadable nft is silent"; else bad "unreadable nft alerted"; fi

# 6: the private stamp suppresses a repeat loss within one hour
printf 'on\n' > "$TMP/state"
mkdir -p "$TMP/surflare"
rm -f "$TMP/surflare/zoro_mode_lost.stamp"
run_case 0 'iifname "br-lan" tproxy ip to :10800'
first_alerts=$(grep -c "^surflare: Zoro primary mode lost|" "$TMP/alerts")
run_case 0 'iifname "br-lan" tproxy ip to :10800'
second_alerts=$(grep -c "^surflare: Zoro primary mode lost|" "$TMP/alerts")
if [ "$first_alerts" -eq 1 ] && [ "$second_alerts" -eq 0 ]; then
	ok "private stamp suppresses repeat loss for one hour"
else
	bad "private stamp did not suppress the repeat loss"
fi

# 7: the production state path is pinned to the persistent file
if grep -qF 'ZORO_STATE_FILE="/etc/zoro-exit.requested"' "$WD"; then
	ok "production state path stays on /etc"
else
	bad "production state path drifted from /etc"
fi

# 8: the call sits after the reload and inside the successful-load guard
_call=$(grep -n '^[[:space:]]*_zoro_mode_loss_alert$' "$WD" | cut -d: -f1)
_load=$(grep -n '_load_tproxy_cn_direct$' "$WD" | cut -d: -f1)
_guard=$(grep -n 'if \[ "\$_load_ok" -eq 1 \]; then' "$WD" | cut -d: -f1)
if [ -n "$_call" ] && [ -n "$_load" ] && [ -n "$_guard" ] \
	&& [ "$_load" -lt "$_guard" ] && [ "$_guard" -lt "$_call" ]; then
	ok "_restore_tproxy calls the check after a successful reload"
else
	bad "_restore_tproxy does not call the check after a successful reload"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
