#!/bin/bash
# The Zoro primary switch lives in a manual nft rule that the Surflare
# watchdog's destroy+reload removes. The watchdog puts the switch back
# itself now (Zoro is the fixed primary): it re-runs zoro-exit on, which
# re-probes the uplink, and only pages when the restore fails.
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
if [ ! -s "$TMP/func.sh" ] || [ "$(wc -l < "$TMP/func.sh")" -gt 90 ]; then
	bad "could not extract _zoro_mode_loss_alert"
	echo "RESULT: $pass passed, $fail failed"
	exit 1
fi

cat > "$TMP/zoro-exit" <<'EOF'
#!/bin/bash
printf 'zoro-exit %s\n' "$*" >> "$TMP_DIR/zoro_calls"
exit "${ZORO_EXIT_RC:-0}"
EOF
chmod +x "$TMP/zoro-exit"

run_case() {
	: > "$TMP/alerts"
	: > "$TMP/log"
	Nft_rc="$1"
	Nft_output="$2"
	ZORO_EXIT_RC="${3:-0}"
	ZORO_STATE_FILE="$TMP/state"
	ZORO_ALERT_STAMP_DIR="$TMP/surflare"
	ZORO_EXIT_BIN="$TMP/zoro-exit"
	TMP_DIR="$TMP"
	if [ -n "${4:-}" ]; then Nft_sf_pre="$4"; else unset Nft_sf_pre; fi
	if [ -n "${5:-}" ]; then Nft_sf_out="$5"; else unset Nft_sf_out; fi
	if [ -n "${6:-}" ]; then Nft_ks_out="$6"; else unset Nft_ks_out; fi
	Nft_table_rc="${7:-0}"
	export Nft_rc Nft_output ZORO_EXIT_RC ZORO_STATE_FILE ZORO_ALERT_STAMP_DIR ZORO_EXIT_BIN TMP TMP_DIR Nft_sf_pre Nft_sf_out Nft_ks_out Nft_table_rc
	bash -c '
			. "$1"
			nft() {
				case "$1" in
				list)
					if [ "$2" = table ]; then return "${Nft_table_rc:-0}"; fi
					case "$4" in
					sw_lan_tproxy) printf "%s\n" "$Nft_output" ;;
					surflare)
						if [ "$5" = prerouting ]; then
							printf "%s\n" "${Nft_sf_pre-$Nft_output}"
						else
							printf "%s\n" "${Nft_sf_out-$Nft_output}"
						fi ;;
					killswitch) printf "%s\n" "${Nft_ks_out-$Nft_output}" ;;
					esac
					return "$Nft_rc" ;;
				*) return 1 ;;
				esac
			}
			log() { printf "%s\n" "$*" >> "$TMP/log"; }
			_deliver_alert() { printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" >> "$TMP/alerts"; }
			_zoro_mode_loss_alert
			# the page is a backgrounded subshell: poll instead of a fixed
			# sleep so a slow alert cannot race the assertions
			for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
				21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
				41 42 43 44 45 46 47 48 49 50; do
				[ -s "$TMP/alerts" ] || [ -s "$TMP/zoro_calls" ] && break
				sleep 0.1
			done
			sleep 0.1
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

# 3: on and the rule is gone; the watchdog restores it, no page
printf 'on\n' > "$TMP/state"
: > "$TMP/zoro_calls"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 0
if [ ! -s "$TMP/alerts" ] \
	&& [ "$(grep -c 'zoro-exit on' "$TMP/zoro_calls")" -eq 1 ] \
	&& grep -q 'restored (was missing: data rule)' "$TMP/log"; then
	ok "mode loss is restored without a page"
else
	bad "mode loss did not restore cleanly [alerts=$(wc -l < "$TMP/alerts") calls=$(cat "$TMP/zoro_calls" 2>/dev/null)]"
fi

# 3b: a failed restore raises one actionable alert
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 1
if [ "$(grep -c "^surflare: Zoro primary mode lost|" "$TMP/alerts")" -eq 1 ] \
	&& grep -q 'fault:zoro-mode-lost' "$TMP/alerts" \
	&& grep -q 'could not restore the Zoro switch' "$TMP/alerts" \
	&& ! grep -q 'DNS exit rules were dropped' "$TMP/alerts" \
	&& grep -q '|yes|' "$TMP/alerts"; then
	ok "a failed restore raises one actionable alert with the class in arg 4"
else
	bad "a failed restore did not raise the expected alert"
fi

# 3c: the restore stamp throttles a repeat attempt for five minutes,
# and an aged stamp lets the restore run again
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 1
calls_after_first=$(grep -c 'zoro-exit on' "$TMP/zoro_calls")
run_case 0 'iifname "br-lan" tproxy ip to :10800' 1
calls_after_second=$(grep -c 'zoro-exit on' "$TMP/zoro_calls")
grep -q 'restore suppressed' "$TMP/log" && _saw_suppress=1 || _saw_suppress=0
touch -d '6 minutes ago' "$TMP/surflare/zoro_mode_restore.stamp"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 1
calls_after_third=$(grep -c 'zoro-exit on' "$TMP/zoro_calls")
if [ "$calls_after_first" -eq 1 ] && [ "$calls_after_second" -eq 1 ] \
	&& [ "$calls_after_third" -eq 2 ] && [ "$_saw_suppress" -eq 1 ]; then
	ok "the restore stamp throttles for five minutes and an aged stamp retries"
else
	bad "the restore stamp boundary is wrong [first=$calls_after_first second=$calls_after_second third=$calls_after_third]"
fi

# 4: on and the rule survived
printf 'on\r\n' > "$TMP/state"
run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"'
if [ ! -s "$TMP/alerts" ]; then ok "surviving Zoro rule is silent after CR/LF normalization"; else bad "surviving rule alerted"; fi

# 5: an unreadable chain is not proof of loss
printf 'on\n' > "$TMP/state"
run_case 1 ''
if [ ! -s "$TMP/alerts" ]; then ok "unreadable nft is silent"; else bad "unreadable nft alerted"; fi

# 5b: a missing zoro-exit binary still pages, with the right reason
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"
chmod -x "$TMP/zoro-exit"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 0
chmod +x "$TMP/zoro-exit"
if [ "$(grep -c "^surflare: Zoro primary mode lost|" "$TMP/alerts")" -eq 1 ] 	&& grep -q 'not installed; cannot restore' "$TMP/log"; then
	ok "a missing binary pages with the right reason"
else
	bad "a missing binary did not page correctly"
fi

# 5c: a future-dated stamp (clock stepped back) restores now, never stalls
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
mkdir -p "$TMP/surflare"
touch -d '1 hour' "$TMP/surflare/zoro_mode_restore.stamp"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 0
if [ "$(grep -c 'zoro-exit on' "$TMP/zoro_calls")" -eq 1 ] \
	&& grep -q 'restored (was missing: data rule)' "$TMP/log"; then
	ok "a future-dated stamp restores instead of stalling"
else
	bad "a future-dated stamp stalled the restore"
fi

# 5d: an unwritable stamp dir skips the restore but still pages
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"
mkdir -p "$TMP/surflare"
chmod 555 "$TMP/surflare"
: > "$TMP/zoro_calls"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 0
chmod 755 "$TMP/surflare"
if [ ! -s "$TMP/zoro_calls" ] \
	&& grep -q 'cannot write' "$TMP/log" \
	&& [ "$(grep -c "^surflare: Zoro primary mode lost|" "$TMP/alerts")" -eq 1 ]; then
	ok "an unwritable stamp dir skips restore and still pages"
else
	bad "an unwritable stamp dir misbehaved [calls=$(wc -l < "$TMP/zoro_calls")]"
fi

# 5g: everything present means total silence -- no restore, no page
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 0
if [ ! -s "$TMP/zoro_calls" ] && [ ! -s "$TMP/alerts" ] && [ ! -s "$TMP/log" ]; then
	ok "a complete switch is never touched"
else
	bad "a complete switch was disturbed [calls=$(cat "$TMP/zoro_calls" 2>/dev/null)]"
fi

# 5e: a killswitch-only wipe (data rule survives, DNS rules gone) restores
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"
run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 0 \
	'x comment "zoro-exit"' 'x comment "zoro-exit"' 'oif "lo" accept'
if [ "$(grep -c 'zoro-exit on' "$TMP/zoro_calls")" -eq 1 ] \
	&& grep -q 'missing: DNS rules' "$TMP/log"; then
	ok "a killswitch-only wipe restores with the DNS piece named"
else
	bad "a killswitch-only wipe did not restore [calls=$(cat "$TMP/zoro_calls" 2>/dev/null)]"
fi

# 5f: with the surflare table gone there are no anchors; stay silent
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 0 \
	'oif "lo" accept' 'oif "lo" accept' 'oif "lo" accept' 1
if [ ! -s "$TMP/zoro_calls" ] && [ ! -s "$TMP/alerts" ]; then
	ok "a missing surflare table neither restores nor pages"
else
	bad "a missing surflare table misbehaved"
fi

# 6: the one-hour alert stamp suppresses a repeat page even when the
# restore is retried and fails again
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 1
first_alerts=$(grep -c "^surflare: Zoro primary mode lost|" "$TMP/alerts")
rm -f "$TMP/surflare/zoro_mode_restore.stamp"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 1
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
_call=$(grep -n '^[[:space:]]*_zoro_mode_loss_alert$' "$WD" | cut -d: -f1 | head -1)
_tick=$(grep -A1 '^[[:space:]]*_zoro_uplink_alert$' "$WD" | grep -c '_zoro_mode_loss_alert')
_load=$(grep -n '_load_tproxy_cn_direct$' "$WD" | cut -d: -f1)
_guard=$(grep -n 'if \[ "\$_load_ok" -eq 1 \]; then' "$WD" | cut -d: -f1)
if [ -n "$_call" ] && [ -n "$_load" ] && [ -n "$_guard" ] \
	&& [ "$_load" -lt "$_guard" ] && [ "$_guard" -lt "$_call" ] \
	&& [ "$_tick" -ge 1 ]; then
	ok "_restore_tproxy and the healthy tick both call the check"
else
	bad "_restore_tproxy or the healthy tick lost the check call"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
