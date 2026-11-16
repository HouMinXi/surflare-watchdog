#!/bin/bash
# The Zoro primary switch lives in a manual nft rule that the Surflare
# watchdog's destroy+reload removes. The watchdog puts the switch back
# itself now (Zoro is the fixed primary): it runs zoro-exit ensure, which
# does not probe the uplink; listener recovery is a separate explicit call.
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
# A runaway guard, not a size contract: the body grows as the restore path
# gains steps, and a number that tracks the real length only ever gets raised.
if [ ! -s "$TMP/func.sh" ] || [ "$(wc -l < "$TMP/func.sh")" -gt 200 ]; then
	bad "could not extract _zoro_mode_loss_alert"
	echo "RESULT: $pass passed, $fail failed"
	exit 1
fi

cat > "$TMP/zoro-exit" <<'EOF'
#!/bin/bash
printf 'zoro-exit %s\n' "$*" >> "$TMP_DIR/zoro_calls"
# The daemon asks `status` for the DNS verdict instead of counting rules
# itself, so the stub has to answer that shape.
if [ "${1:-}" = status ]; then
	if [ "${FAKE_NFT_ABSENT:-0}" = 1 ]; then
		printf 'mode=lost\nnft=missing\nreason=no-table\n'; exit 4
	fi
	if [ "${Nft_rc:-0}" -ne 0 ]; then
		printf 'mode=unknown\nnft=unreadable\n'; exit 3
	fi
	if [ "${Nft_table_rc:-0}" -ne 0 ]; then
		printf 'mode=lost\nnft=missing\nreason=no-table\n'; exit 4
	fi
	if [ "${FAKE_ZORO_SILENT:-0}" = 1 ]; then
		printf 'mode=on\nnft=ok\n'; exit 0
	fi
	mode=on; order=${FAKE_ZORO_ORDER:-ok}
	case "$Nft_output" in *'comment "zoro-exit"'*) : ;;
	*) mode=lost; order=missing ;; esac
	printf 'mode=%s\nnft=ok\ndns=%s\nroute=%s\norder=%s\nxray_listening=%s\n' \
		"$mode" "${FAKE_ZORO_DNS:-ok}" "${FAKE_ZORO_ROUTE:-ok}" \
		"$order" "${FAKE_ZORO_LISTENER:-yes}"
	exit 0
fi
if [ "${1:-}" = ensure ]; then
	printf 'health=%s\nreason=%s\n' "${FAKE_ZORO_HEALTH:-repaired}" "${FAKE_ZORO_WHY:-none}"
	exit "${FAKE_ZORO_ENSURE_RC:-${ZORO_EXIT_RC:-0}}"
fi
printf 'health=%s\nreason=xray\n' "${FAKE_RECOVERY_HEALTH:-repaired}"
exit "${FAKE_RECOVERY_RC:-0}"
EOF
chmod +x "$TMP/zoro-exit"

_complete_pre='meta nfproto ipv4 meta l4proto udp meta mark 0x00000002 tproxy ip to :7895 meta mark set 0x00000002 accept comment "zoro-exit" # handle 24
meta nfproto ipv4 meta l4proto tcp meta mark 0x00000002 tproxy ip to :7895 meta mark set 0x00000002 accept comment "zoro-exit" # handle 25'
_complete_out='meta nfproto ipv4 udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 26
meta nfproto ipv4 tcp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 27'
_complete_ks='meta mark 0x00000002 accept comment "zoro-exit" # handle 87'

run_case() {
	: > "$TMP/alerts"
	: > "$TMP/log"
	Nft_rc="$1"
	Nft_output="$2"
	ZORO_EXIT_RC="${3:-0}"
	ZORO_STATE_FILE="$TMP/state"
	ZORO_ALERT_STAMP_DIR="$TMP/surflare"
	ZORO_EXIT_BIN="${ZORO_EXIT_BIN_OVERRIDE:-$TMP/zoro-exit}"
	TMP_DIR="$TMP"
	# A switch that is fully installed carries two catches, two dport-53 mark
	# rules and one killswitch accept; the daemon counts them, so the fixture
	# has to model the real set rather than one line per chain.  Pass `none`
	# to wipe a chain.
	case "${4:-}" in
	"") Nft_sf_pre="$_complete_pre" ;;
	none) Nft_sf_pre="" ;;
	*) Nft_sf_pre="$4" ;;
	esac
	case "${5:-}" in
	"") Nft_sf_out="$_complete_out" ;;
	none) Nft_sf_out="" ;;
	*) Nft_sf_out="$5" ;;
	esac
	case "${6:-}" in
	"") Nft_ks_out="$_complete_ks" ;;
	none) Nft_ks_out="" ;;
	*) Nft_ks_out="$6" ;;
	esac
	Nft_table_rc="${7:-0}"
	export Nft_rc Nft_output ZORO_EXIT_RC ZORO_STATE_FILE ZORO_ALERT_STAMP_DIR ZORO_EXIT_BIN TMP TMP_DIR Nft_sf_pre Nft_sf_out Nft_ks_out Nft_table_rc
	export Nft_complete_pre="$_complete_pre" Nft_complete_out="$_complete_out" Nft_complete_ks="$_complete_ks"
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
							printf "%s\n" "${Nft_sf_pre-$Nft_complete_pre}"
						else
							printf "%s\n" "${Nft_sf_out-$Nft_complete_out}"
						fi ;;
					killswitch) printf "%s\n" "${Nft_ks_out-$Nft_complete_ks}" ;;
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
	&& [ "$(grep -c 'zoro-exit ensure' "$TMP/zoro_calls")" -eq 1 ] \
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
calls_after_first=$(grep -c 'zoro-exit ensure' "$TMP/zoro_calls")
run_case 0 'iifname "br-lan" tproxy ip to :10800' 1
calls_after_second=$(grep -c 'zoro-exit ensure' "$TMP/zoro_calls")
grep -q 'restore suppressed' "$TMP/log" && _saw_suppress=1 || _saw_suppress=0
touch -d '6 minutes ago' "$TMP/surflare/zoro_mode_restore.stamp"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 1
calls_after_third=$(grep -c 'zoro-exit ensure' "$TMP/zoro_calls")
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
if [ "$(grep -c 'zoro-exit ensure' "$TMP/zoro_calls")" -eq 1 ] \
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
if ! grep -q 'zoro-exit ensure' "$TMP/zoro_calls" \
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
if ! grep -q "zoro-exit ensure" "$TMP/zoro_calls" && [ ! -s "$TMP/alerts" ] && [ ! -s "$TMP/log" ]; then
	ok "a complete switch is never touched"
else
	bad "a complete switch was disturbed [calls=$(cat "$TMP/zoro_calls" 2>/dev/null)]"
fi

# 5e: a killswitch-only wipe (data rule survives, DNS rules gone) restores
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"
FAKE_ZORO_DNS=missing run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 0 \
	'' '' 'oif "lo" accept'
if [ "$(grep -c 'zoro-exit ensure' "$TMP/zoro_calls")" -eq 1 ] \
	&& grep -q 'missing: DNS rules' "$TMP/log"; then
	ok "a killswitch-only wipe restores with the DNS piece named"
else
	bad "a killswitch-only wipe did not restore [calls=$(cat "$TMP/zoro_calls" 2>/dev/null)]"
fi

# 5f: missing parent state reaches the same counted defer path as a repair
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
FAKE_ZORO_HEALTH=deferred FAKE_ZORO_WHY=no-table \
	run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 4 \
	'oif "lo" accept' 'oif "lo" accept' 'oif "lo" accept' 1
if grep -q "zoro-exit ensure" "$TMP/zoro_calls" && [ ! -s "$TMP/alerts" ] &&
	[ "$(cat "$TMP/surflare/zoro_busy.count")" = 'no-table 1' ]; then
	ok "a missing surflare table is counted as a deferred repair"
else
	bad "a missing surflare table bypassed the owner verdict"
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

# 5h: half of a DNS pair is still a loss -- presence per chain read it healthy
# and the repair never ran.
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
FAKE_ZORO_DNS=missing run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 0 \
	'meta nfproto ipv4 meta l4proto udp meta mark 0x00000002 tproxy ip to :7895 meta mark set 0x00000002 accept comment "zoro-exit" # handle 24'
if [ "$(grep -c 'zoro-exit ensure' "$TMP/zoro_calls")" -eq 1 ] \
	&& grep -q 'missing: DNS rules' "$TMP/log"; then
	ok "a half-installed DNS pair is restored"
else
	bad "a half-installed DNS pair read as healthy [calls=$(cat "$TMP/zoro_calls" 2>/dev/null)]"
fi

# 6b: a busy helper is a deferral, not a failure -- no page, and the throttle
# is dropped so the next tick sees whatever the other writer left behind.
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
run_case 0 'iifname "br-lan" tproxy ip to :10800' 4
if [ ! -s "$TMP/alerts" ] && grep -q 'restore deferred' "$TMP/log" \
	&& [ ! -f "$TMP/surflare/zoro_mode_restore.stamp" ]; then
	ok "a busy helper defers without paging"
else
	bad "a busy helper was treated as a failure [alerts=$(wc -l < "$TMP/alerts") stamp=$([ -f "$TMP/surflare/zoro_mode_restore.stamp" ] && echo kept || echo gone)]"
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

# 8: a helper that ignores TERM must not hold the health loop: the -k bound
# has to end it.
printf 'on\n' > "$TMP/state"
rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
cat > "$TMP/zoro-hang" <<'EOF'
#!/bin/bash
[ "${1:-}" != status ] || {
	printf 'mode=lost\nnft=missing\nreason=no-table\n'; exit 4
}
trap '' TERM
sleep 30
EOF
chmod +x "$TMP/zoro-hang"
_start=$(date +%s)
FAKE_ZORO_DNS=missing ZORO_RESTORE_TIMEOUT=2 ZORO_EXIT_BIN_OVERRIDE="$TMP/zoro-hang" \
	run_case 0 'iifname "br-lan" tproxy ip to :10800'
_elapsed=$(( $(date +%s) - _start ))
[ "$_elapsed" -le 8 ] && ok "a TERM-ignoring helper is killed at the bound [${_elapsed}s]" \
	|| bad "a TERM-ignoring helper held the loop for ${_elapsed}s"

# A verdict that could not be read is not evidence of a loss.  The helper prints
# no dns= line here, which is what a slow nft or a killed call looks like, and a
# healthy switch must not be paged about.
: > "$TMP/alerts"
rm -f "$TMP/surflare/zoro_mode_restore.stamp"
FAKE_ZORO_SILENT=1 run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"' 
[ ! -s "$TMP/alerts" ] && ! grep -q "zoro-exit ensure" "$TMP/zoro_calls" 2>/dev/null \
	&& ok "an unreadable DNS verdict triggers no restore and no page" \
	|| bad "an unreadable verdict was read as a lost switch [alerts=$(wc -l < "$TMP/alerts" 2>/dev/null)]"

# A misplaced pair is a real fault: the daemon has to repair it, not accept any
# non-empty verdict as fine.
: > "$TMP/alerts"
# Earlier cases may have written the restore stamp; a 300 s throttle would hide
# the repair this case is about.
rm -f "$TMP/surflare/zoro_mode_restore.stamp"
FAKE_ZORO_DNS=misplaced run_case 0 'iifname "br-lan" tproxy ip to :7895 comment "zoro-exit"'
grep -q "zoro-exit ensure" "$TMP/zoro_calls" 2>/dev/null \
	&& ok "a misplaced DNS pair is repaired through ensure" \
	|| bad "a misplaced pair was left alone [calls=$(tr '\n' ' ' < "$TMP/zoro_calls" 2>/dev/null)]"


# Distinct zero-exit verdicts must never turn an off/cleanup into a restore.
for health in off cleaned; do
	rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
	FAKE_ZORO_HEALTH="$health" run_case 0 'tproxy ip to :10800'
	if ! grep -q 'primary restored' "$TMP/log" &&
		grep -q 'switch is off' "$TMP/log" && [ ! -s "$TMP/alerts" ]; then
		ok "daemon honors the $health verdict"
	else bad "daemon called $health a restore"; fi
done

# The twentieth consecutive same-cause defer pages; the nineteenth does not.
for cause in lock no-table; do
	rm -rf "$TMP/surflare"; mkdir "$TMP/surflare"
	printf '%s 18\n' "$cause" > "$TMP/surflare/zoro_busy.count"
	if [ "$cause" = lock ]; then health=busy; why=none
	else health=deferred; why=no-table; fi
	FAKE_ZORO_HEALTH="$health" FAKE_ZORO_WHY="$why" \
		run_case 0 'tproxy ip to :10800' 4
	first=$(wc -l < "$TMP/alerts")
	FAKE_ZORO_HEALTH="$health" FAKE_ZORO_WHY="$why" \
		run_case 0 'tproxy ip to :10800' 4
	if [ "$first" -eq 0 ] && [ -s "$TMP/alerts" ] &&
		grep -q "cause=$cause attempts=20" "$TMP/log"; then
		ok "repeated $cause defer pages with the actual cause at 20"
	else bad "wrong threshold or cause for $cause"; fi
done

rm -rf "$TMP/surflare"; mkdir "$TMP/surflare"
printf 'lock 19\n' > "$TMP/surflare/zoro_busy.count"
FAKE_ZORO_HEALTH=deferred FAKE_ZORO_WHY=no-table \
	run_case 0 'tproxy ip to :10800' 4
if [ ! -s "$TMP/alerts" ] &&
	[ "$(cat "$TMP/surflare/zoro_busy.count")" = 'no-table 1' ]; then
	ok 'a new defer cause starts its own consecutive count'
else bad 'unrelated defer causes were counted together'; fi

rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
FAKE_ZORO_HEALTH=deferred FAKE_ZORO_WHY=xray \
	run_case 0 'tproxy ip to :10800' 4
if grep -q '^zoro-exit on --repair$' "$TMP/zoro_calls" &&
	grep -q 'listener recovered' "$TMP/log" && [ ! -s "$TMP/alerts" ]; then
	ok 'xray deferral invokes the explicit listener recovery path'
else bad 'dead listener was mistaken for a busy lock'; fi

rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
FAKE_ZORO_LISTENER=no FAKE_ZORO_HEALTH=deferred FAKE_ZORO_WHY=xray \
	run_case 0 'tproxy ip to :7895 comment "zoro-exit"' 4
if grep -q '^zoro-exit on --repair$' "$TMP/zoro_calls"; then
	ok 'a dead listener is detected even with all rules present'
else bad 'presence checks hid the dead listener'; fi

rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
FAKE_ZORO_ORDER=misplaced run_case 0 'tproxy ip to :7895 comment "zoro-exit"'
if grep -q '^zoro-exit ensure$' "$TMP/zoro_calls"; then
	ok 'misordered data triggers ensure even when its tag is present'
else bad 'tag-only presence hid incorrect ordering'; fi

# Missing state is valid absence, unlike failed reads; neither missing
# parent table may bypass the same-cause defer threshold.
for missing in data dns; do
	rm -rf "$TMP/surflare"; : > "$TMP/zoro_calls"
	pages=0
	for _attempt in $(seq 1 21); do
		if [ "$missing" = data ]; then
			FAKE_NFT_ABSENT=1 FAKE_ZORO_HEALTH=deferred FAKE_ZORO_WHY=no-table \
				run_case 1 '' 4
		else
			FAKE_ZORO_HEALTH=deferred FAKE_ZORO_WHY=no-table \
				run_case 0 'tproxy ip to :7895 comment "zoro-exit"' 4 '' '' '' 1
		fi
		[ "$_attempt" -ge 20 ] || [ ! -s "$TMP/alerts" ] || pages=99
		[ ! -s "$TMP/alerts" ] || pages=$((pages+1))
	done
	if [ "$pages" -eq 1 ] &&
		[ "$(cat "$TMP/surflare/zoro_busy.count")" = 'no-table 20' ]; then
		ok "actual missing $missing parent reaches the counted threshold"
	else bad "missing $missing parent bypassed defer handling [pages=$pages]"; fi
done

# 9: the count is pinned, so a silently skipped case cannot pass as green
if [ "$pass" -eq 31 ]; then
	ok "the daemon case count is pinned"
else
	bad "the daemon case count moved to $pass"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
