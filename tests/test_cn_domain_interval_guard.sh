#!/usr/bin/env bash
# cn_domain_ips interval guard.
#
# The set is a DNS cache: SmartDNS adds individual resolved addresses.  A
# wide interval there makes tproxy return the whole span as domestic while
# the killswitch set does not carry the same range, blackholing traffic.  The
# guard rebuilds the affected sets in one transaction: flush every readable
# copy, then add back the union of the healthy entries, so both tables end up
# holding the same elements.
set -u
cd "$(dirname "$0")/.." || exit 1
WD="surflare_watchdog.sh"
[ -f "$WD" ] || { echo "FAIL: $WD not found"; exit 1; }
fail=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A source-only driver with a fake nft.  Each table has a fixture file; its
# presence means the table exists.
cat > "$TMP/drive.sh" <<'EOF'
#!/usr/bin/env bash
set -u
export TMP
export CN_DOMAIN_TEST_MODE=1
source ./surflare_watchdog.sh --source-only
PLATFORM=router

nft() {
	case "$*" in
		"list tables")
			local f t
			if [ "${Nft_fail_tables:-}" = "1" ]; then
				echo "Operation not permitted" >&2
				return 1
			fi
			for f in "$TMP"/*.*.set; do
				[ -e "$f" ] || continue
				t=$(basename "$f")
				t=${t%%.*}
				echo "table inet $t"
			done | sort -u
			;;
		"list table inet "*)
			local t
			for t in "$@"; do :; done
			# The table is the last argument.
			if [ "${Nft_fail_table:-}" = "$t" ]; then
				echo "Operation not permitted" >&2
				return 1
			fi
			compgen -G "$TMP/$t.*.set" >/dev/null && return 0
			echo "Error: No such file or directory" >&2
			return 1
			;;
		"list set inet "*)
			local t="${4}" s="${5}"
			[ "${Nft_fail_set:-}" = "$t/$s" ] && return 1
			if [ "${Nft_missing_set:-}" = "$t/$s" ]; then
				echo "Error: No such file or directory" >&2
				return 1
			fi
			if [ -f "$TMP/$t.$s.set" ]; then
				[ -n "${Nft_stderr:-}" ] && printf '%s\n' "$Nft_stderr" >&2
				cat "$TMP/$t.$s.set"
				return 0
			fi
			echo "Error: No such file or directory" >&2
			return 1
			;;
		"-f -")
			if [ "${Nft_timeout:-}" = "1" ]; then
				return 124
			fi
			local -a lines
			local line t s
			while IFS= read -r line; do lines+=("$line"); done
			printf '%s\n' "${lines[@]}" >> "$TMP/rawbatch"
			for line in "${lines[@]}"; do
				read -r _ _ _ t s _rest <<< "$line"
				[ "${Nft_fail_change:-}" = "$t/$s" ] && return 1
			done
			for line in "${lines[@]}"; do
				read -r _kind _ _ t s _rest <<< "$line"
				local _el
				_el=$(printf '%s' "$_rest" | sed 's/^ *{ *//; s/ *} *$//; s/ timeout .*$//')
				case "$_kind" in
					delete)
						echo "$t/$s=$_el" >> "$TMP/entries"
						echo "$t/$s" >> "$TMP/changes"
						: > "$TMP/$t.$s.set"
						;;
					flush)
						echo "FLUSH:$t/$s" >> "$TMP/changes"
						echo "$t/$s" >> "$TMP/changes"
						: > "$TMP/$t.$s.set"
						;;
					add)
						echo "$t/$s=$_el" >> "$TMP/entries"
						[ -f "$TMP/$t.$s.set" ] && sed -i "s/elements = {/elements = { $_el,/" "$TMP/$t.$s.set"
						;;
				esac
			done
			;;
		"delete element inet "*)
			local t="${4}" s="${5}" el="${6}"
			[ "${Nft_fail_change:-}" = "$t/$s" ] && return 1
			echo "$t/$s" >> "$TMP/changes"
			echo "$t/$s=$el" >> "$TMP/entries"
			;;
		"flush set inet "*)
			local t="${4}" s="${5}"
			[ "${Nft_fail_change:-}" = "$t/$s" ] && return 1
			echo "FLUSH:$t/$s" >> "$TMP/changes"
			: > "$TMP/$t.$s.set"
			;;
		"add element inet "*)
			local t="${4}" s="${5}" el="${6}"
			echo "$t/$s=$el" >> "$TMP/entries"
			;;
		*) return 0 ;;
	esac
}
log() { printf '%s\n' "$*" >> "$TMP/log"; }
_deliver_alert() { printf '%s\n' "$*" >> "$TMP/alerts"; }

if [ "${DRIVE_MODE:-}" = "loop" ]; then
	if _cn_domain_guard_due "$(date +%s)"; then
		_guard_cn_domain_ranges
	fi
else
	_guard_cn_domain_ranges
fi
wait
EOF
chmod +x "$TMP/drive.sh"

set_named() {
	# $1 table, $2 set, $3 elements
	local _type=ipv4_addr
	case "$2" in cn6_domain_ips|gmail_smtp6) _type=ipv6_addr ;; esac
	cat > "$TMP/$1.$2.set" <<EOF2
table inet $1 {
	set $2 {
		type $_type
		flags interval,timeout
		timeout 1h
		elements = { $3 }
	}
}
EOF2
}

set_table() {
	# $1 table, $2 elements
	set_named "$1" cn_domain_ips "$2"
}

run_drive() {
	local tables="${1:-sw_lan_tproxy killswitch}"
	: > "$TMP/changes"; : > "$TMP/entries"; : > "$TMP/rawbatch"; : > "$TMP/log"; : > "$TMP/alerts"
	rm -rf "$TMP/stamps"; mkdir -p "$TMP/stamps"
	export TMP ZORO_ALERT_STAMP_DIR="$TMP/stamps" PLATFORM=router PLATFORM=router PLATFORM=router
	export Nft_stderr="${Nft_stderr:-}" Nft_missing="${Nft_missing:-}"
	CN_DOMAIN_GUARD_TABLES="$tables" bash "$TMP/drive.sh"
}

run_drive_again() {
	local tables="${1:-sw_lan_tproxy killswitch}"
	CN_DOMAIN_GUARD_TABLES="$tables" bash "$TMP/drive.sh"
}

# --- wide IPv4 range in tproxy ---
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221 expires 5m"
set_table killswitch "1.1.1.1"
run_drive sw_lan_tproxy
grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& ok "wide range: tproxy entry removed" \
	|| bad "wide range: tproxy not removed [$(cat "$TMP/changes")]"
grep -q "holds" "$TMP/log" \
	&& ok "wide range: logged" || bad "wide range: not logged"
grep -q "cn-domain-range" "$TMP/alerts" \
	&& ok "wide range: alert sent" || bad "wide range: alert missing"
# The alert reports what was seen, not a proved outage.
! grep -q 'blackholing traffic' "$TMP/alerts" \
	&& ok "alert does not claim an unobserved blackhole" \
	|| bad "alert overclaims blackhole"
# A v4 defect must not empty the healthy v6 cache.
! grep -q 'cn6_domain_ips' "$TMP/changes" \
	&& ok "v4 defect leaves v6 cache alone" \
	|| bad "v4 defect removed v6 [$(tr '\n' ' ' < "$TMP/changes")]"
# A persistent defect must not page again inside the private window.
_before=$(wc -l < "$TMP/alerts")
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
run_drive_again sw_lan_tproxy
[ "$(wc -l < "$TMP/alerts")" -eq "$_before" ] \
	&& ok "repeat detection does not page again" \
	|| bad "repeat detection paged again"
: > "$TMP/log"
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
run_drive_again sw_lan_tproxy
! grep -q 'holds' "$TMP/log" \
	&& ok "detailed log is written once per window" \
	|| bad "detailed log repeats [$(grep -c 'holds' "$TMP/log")]"
# A later un-repaired outcome is a different severity and must still page.
_before2=$(wc -l < "$TMP/alerts")
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
Nft_fail_set=killswitch/cn6_domain_ips run_drive_again "sw_lan_tproxy killswitch"
[ "$(wc -l < "$TMP/alerts")" -gt "$_before2" ] \
	&& grep -q 'cn-domain-unrepaired' "$TMP/alerts" \
	&& ok "unrepaired outcome pages after a repaired one" \
	|| bad "unrepaired outcome was hidden by the repaired stamp"

# --- a quiet run must not consume the log window ---
set_table sw_lan_tproxy "8.8.8.8"
run_drive sw_lan_tproxy
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
run_drive_again sw_lan_tproxy
grep -q 'holds' "$TMP/log" \
	&& ok "a quiet run does not silence the first finding" \
	|| bad "log window consumed by a quiet run"

# --- a page suppression window longer than a day still pages ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
CN_DOMAIN_GUARD_SUPPRESS=86401 run_drive sw_lan_tproxy
[ -s "$TMP/alerts" ] \
	&& ok "long suppression window still pages once" \
	|| bad "long suppression window silenced the first page"

# --- a zero suppression window pages every time ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
export CN_DOMAIN_GUARD_SUPPRESS=0
run_drive sw_lan_tproxy
_before3=$(wc -l < "$TMP/alerts")
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
run_drive_again sw_lan_tproxy
[ "$(wc -l < "$TMP/alerts")" -gt "$_before3" ] \
	&& ok "zero suppression window pages again" \
	|| bad "suppression window is not configurable"
unset CN_DOMAIN_GUARD_SUPPRESS

# --- a set that holds deliberate prefixes is refused ---
set_named sw_lan_tproxy ts_control "192.200.0.0/24"
CN_DOMAIN_GUARD_SETS="ts_control" run_drive sw_lan_tproxy
[ ! -s "$TMP/changes" ] && grep -q 'refusing unknown cache set' "$TMP/log" \
	&& ok "non-cache set is refused" \
	|| bad "non-cache set was modified"

# --- bare answers are not flagged ---
set_table sw_lan_tproxy "8.8.8.8, 140.82.113.5"
set_table killswitch "1.1.1.1"
run_drive sw_lan_tproxy
[ ! -s "$TMP/changes" ] && ok "normal cache: no removal" || bad "normal cache: changed [$(cat "$TMP/changes")]"
[ ! -s "$TMP/alerts" ] && ok "normal cache: no alert" || bad "normal cache: alert sent [$(cat "$TMP/alerts")]"

# --- a prefix is always flagged, however narrow ---
set_table sw_lan_tproxy "10.0.0.0/24"
run_drive sw_lan_tproxy
grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& ok "/24 prefix: removed" || bad "/24 prefix missed"

# --- a two-address interval is the narrowest flagged span ---
set_table sw_lan_tproxy "10.0.0.0-10.0.0.1"
run_drive sw_lan_tproxy
grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& ok "two-address interval: removed" || bad "two-address interval missed"

# --- /31 is a two-address prefix and is flagged ---
set_table sw_lan_tproxy "10.0.0.0/31"
run_drive sw_lan_tproxy
grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& ok "/31 prefix: removed" || bad "/31 prefix missed"

# --- a wide CIDR is caught too ---
set_table sw_lan_tproxy "10.0.0.0/8"
set_table killswitch "1.1.1.1"
run_drive sw_lan_tproxy
grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& ok "wide CIDR: removed" || bad "wide CIDR: not removed"

# --- both sets wide: both caches are repaired ---
set_table sw_lan_tproxy "10.0.0.0/8"
set_table killswitch "11.0.0.0/8"
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" && grep -q '^killswitch/cn_domain_ips$' "$TMP/changes" \
	&& ok "both sets: both removed" \
	|| bad "both sets: changes [$(tr '\n' ' ' < "$TMP/changes")]"

# --- a configured table that is gone blocks the rebuild ---
rm -f "$TMP/killswitch".*.set
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
run_drive "sw_lan_tproxy killswitch"
[ ! -s "$TMP/changes" ] && grep -q 'table killswitch is absent' "$TMP/alerts" \
	&& ok "missing table blocks the rebuild" \
	|| bad "rebuilt one copy while its peer table is gone [$(tr '\n' ' ' < "$TMP/changes")]"
! grep -q 'inspection failed' "$TMP/alerts" \
	&& ok "missing table is not a read failure" \
	|| bad "missing table paged as a read failure [$(cat "$TMP/alerts")]"

# --- a peer entry inside the detected span is removed with it ---
set_table sw_lan_tproxy "140.82.113.5"
set_table killswitch "139.196.16.27-150.138.220.221"
run_drive "sw_lan_tproxy killswitch"
grep -q '^killswitch/cn_domain_ips$' "$TMP/changes" \
	&& grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& grep -q '^sw_lan_tproxy/cn_domain_ips=140.82.113.5$' "$TMP/entries" \
	&& grep -q '^killswitch/cn_domain_ips=140.82.113.5$' "$TMP/entries" \
	&& ok "peer entry inside the span is carried into both copies" \
	|| bad "peer entry inside the span survived [$(tr '\n' ' ' < "$TMP/changes")]"

# --- containment works in the return direction too ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "140.82.113.5"
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& grep -q '^killswitch/cn_domain_ips$' "$TMP/changes" \
	&& ok "return-side span keeps the contained accept in both copies" \
	|| bad "contained accept missing from a copy [$(tr '\n' ' ' < "$TMP/changes")]"

# --- containment arithmetic also covers a CIDR span ---
set_table sw_lan_tproxy "10.0.0.0/16"
set_table killswitch "10.0.5.5"
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& grep -q '^killswitch/cn_domain_ips$' "$TMP/changes" \
	&& grep -q '^sw_lan_tproxy/cn_domain_ips=10.0.5.5$' "$TMP/entries" \
	&& grep -q '^killswitch/cn_domain_ips=10.0.5.5$' "$TMP/entries" \
	&& ok "CIDR span keeps the contained peer entry in both copies" \
	|| bad "contained peer entry under a CIDR missing from a copy [$(tr '\n' ' ' < "$TMP/changes")]"

# --- a whole /16 is flagged, and its two-address neighbour too ---
set_table sw_lan_tproxy "10.0.0.0-10.0.255.255"
run_drive sw_lan_tproxy
grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& ok "inclusive /16 range: removed" || bad "inclusive /16 range missed"

# --- /16 CIDR is suspicious too ---
set_table sw_lan_tproxy "10.0.0.0/16"
run_drive sw_lan_tproxy
grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& ok "/16 CIDR: removed" || bad "/16 CIDR missed"

# --- IPv6 wide entry resets only the IPv6 caches ---
set_table sw_lan_tproxy "8.8.8.8"
set_named sw_lan_tproxy cn6_domain_ips '2001:db8::/64'
run_drive sw_lan_tproxy
grep -q '^sw_lan_tproxy/cn6_domain_ips$' "$TMP/changes" \
	&& ! grep -q 'cn_domain_ips$' <(grep -v '^sw_lan_tproxy/cn6_domain_ips$' "$TMP/changes") \
	&& ok "IPv6 wide prefix: only v6 removed" \
	|| bad "IPv6 wide prefix removed the wrong family [$(tr '\n' ' ' < "$TMP/changes")]"

# --- an IPv6 interval is not a DNS answer either ---
set_table sw_lan_tproxy "8.8.8.8"
set_named sw_lan_tproxy cn6_domain_ips '2001:db8:1::5-2001:db8:1::9'
run_drive sw_lan_tproxy
grep -q '^sw_lan_tproxy/cn6_domain_ips$' "$TMP/changes" \
	&& ok "IPv6 interval: removed" || bad "IPv6 interval missed"

# --- a comment that looks like an address is not an entry ---
set_table sw_lan_tproxy '8.8.8.8 comment "10.0.0.0/8"'
run_drive sw_lan_tproxy
[ ! -s "$TMP/changes" ] && ok "comment text not parsed as an entry" \
	|| bad "comment text was removed as an entry"

# --- a multi-line element comment is not an entry source ---
set_named sw_lan_tproxy cn_domain_ips '8.8.8.8 comment "line1
192.168.0.0/16"'
run_drive sw_lan_tproxy
[ ! -s "$TMP/changes" ] && ok "multi-line comment not parsed" \
	|| bad "multi-line comment text was removed as an entry"

# --- the guard covers every SmartDNS cache set, not only the CN pair ---
set_named sw_lan_tproxy gmail_smtp "10.0.0.0/24"
run_drive sw_lan_tproxy
grep -q '^sw_lan_tproxy/gmail_smtp$' "$TMP/changes" \
	&& ok "gmail_smtp cache is inspected" || bad "gmail_smtp cache not inspected"

# --- a v6 span is rebuilt too, keeping the peer host in both copies ---
set_named sw_lan_tproxy cn6_domain_ips '2001:db8:1::/64, 2001:db8:1::abcd'
set_named killswitch cn6_domain_ips '2001:db8:1::abcd'
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/cn6_domain_ips=2001:db8:1::abcd$' "$TMP/entries" \
	&& grep -q '^killswitch/cn6_domain_ips=2001:db8:1::abcd$' "$TMP/entries" \
	&& ! grep -q '2001:db8:1::/64' "$TMP/entries" \
	&& grep -q '^killswitch/cn6_domain_ips$' "$TMP/changes" \
	&& ok "v6 span dropped, host kept in both copies" \
	|| bad "v6 rebuild kept the span or dropped the host [$(tr '\n' ' ' < "$TMP/entries")]"

# --- the same v6 interval in both tables is not treated as a peer host ---
set_named sw_lan_tproxy cn6_domain_ips '2408:8207::1-2408:8207::ffff'
set_named killswitch cn6_domain_ips '2408:8207::1-2408:8207::ffff'
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/cn6_domain_ips$' "$TMP/changes" \
	&& grep -q '^killswitch/cn6_domain_ips$' "$TMP/changes" \
	&& ! grep -q 'left in place' "$TMP/alerts" \
	&& ok "v6 interval in both tables is removed symmetrically" \
	|| bad "v6 interval handling asymmetric [$(tr '\n' ' ' < "$TMP/changes")]"

# --- detection still works under the router's busybox awk ---
mkdir -p "$TMP/bb"
ln -sf "$(command -v busybox)" "$TMP/bb/awk"
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
PATH="$TMP/bb:$PATH" run_drive "sw_lan_tproxy killswitch"
grep -q '^killswitch/cn_domain_ips$' "$TMP/changes" \
	&& grep -q '^sw_lan_tproxy/cn_domain_ips=8.8.8.8$' "$TMP/entries" \
	&& ! grep -q '139.196.16.27' "$TMP/entries" \
	&& ok "busybox awk still flags the span" \
	|| bad "busybox awk missed the span [$(tr '\n' ' ' < "$TMP/changes")]"

# --- a single IPv6 address and /128 are ordinary cache entries ---
set_table sw_lan_tproxy "8.8.8.8"
set_named sw_lan_tproxy cn6_domain_ips '2001:db8::1, 2001:db8::2/128'
run_drive sw_lan_tproxy
[ ! -s "$TMP/changes" ] && ok "IPv6 singleton: no removal" || bad "IPv6 singleton removed"

# --- an absent cache set with nothing to repair is quiet ---
set_table sw_lan_tproxy "8.8.8.8"
Nft_missing_set=sw_lan_tproxy/cn6_domain_ips run_drive sw_lan_tproxy
[ ! -s "$TMP/changes" ] && [ ! -s "$TMP/alerts" ] \
	&& ok "absent set: no removal, no alert" \
	|| bad "absent set reported as a failure"

# --- the repaired page stays off the emergency fallback channel ---
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
run_drive "sw_lan_tproxy killswitch"
grep -q 'DNS cache rebuilt' "$TMP/alerts" && grep -q ' no ' "$TMP/alerts" \
	&& ok "repaired page does not use the emergency fallback" \
	|| bad "repaired page may consume the fallback budget [$(head -1 "$TMP/alerts")]"

# --- a set missing from one configured table is never rebuilt alone ---
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
rm -f "$TMP/killswitch.cn_domain_ips.set"
cat > "$TMP/killswitch.cn6_domain_ips.set" <<'EOF2'
table inet killswitch {
	set cn6_domain_ips {
		type ipv6_addr
		flags interval,timeout
		timeout 1h
		elements = { 2001:db8::1 }
	}
}
EOF2
run_drive "sw_lan_tproxy killswitch"
[ ! -s "$TMP/changes" ] && grep -q 'left as it is this cycle' "$TMP/alerts" \
	&& ok "set missing from a peer table blocks the rebuild" \
	|| bad "rebuilt one copy while the other lacks the set [$(tr '\n' ' ' < "$TMP/changes")]"

# --- nft read failure is visible, not a clean cache ---
set_table sw_lan_tproxy "8.8.8.8"
Nft_fail_set=sw_lan_tproxy/cn_domain_ips run_drive sw_lan_tproxy
[ ! -s "$TMP/changes" ] && grep -q 'inspection failed' "$TMP/alerts" \
	&& ! grep -q 'held nothing but a wide range' "$TMP/alerts" \
	&& ok "read failure alerts without removing" \
	|| bad "read failure was silent, removed, or claimed a confirmed interval"

# --- an unreadable table is not a missing table ---
set_table sw_lan_tproxy "8.8.8.8"
Nft_fail_tables=1 run_drive sw_lan_tproxy
[ ! -s "$TMP/changes" ] && grep -q 'inspection failed' "$TMP/alerts" \
	&& ok "unreadable table list alerts" || bad "unreadable table list treated as absent"

# --- an unreadable set blocks the removal even when a wide span is visible ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
Nft_fail_set=killswitch/cn6_domain_ips run_drive "sw_lan_tproxy killswitch"
[ ! -s "$TMP/changes" ] && grep -q 'inspection failed' "$TMP/alerts" \
	&& grep -q 'was not removed' "$TMP/alerts" \
	&& ok "unreadable set blocks the removal" \
	|| bad "unreadable set allowed a partial removal [$(tr '\n' ' ' < "$TMP/changes")]"

# --- one removal failure inside the batch leaves every set untouched ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "139.196.16.27-150.138.220.221"
Nft_fail_change=killswitch/cn_domain_ips run_drive "sw_lan_tproxy killswitch"
[ ! -s "$TMP/changes" ] && grep -q 'could not remove' "$TMP/alerts" \
	&& ok "partial removal failure is atomic" \
	|| bad "removal failure left a one-sided cache [$(tr '\n' ' ' < "$TMP/changes")]"

# --- the nft reason survives after a per-entry log line ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "139.196.16.27-150.138.220.221"
Nft_fail_change=killswitch/cn_domain_ips run_drive "sw_lan_tproxy killswitch"
grep -q 'removal failed' "$TMP/log" \
	&& ok "removal failure reason is logged" \
	|| bad "removal failure reason was dropped"

# --- an unwritable stamp dir still pages both outcomes ---
run_drive_raw() {
	local tables="$1"
	: > "$TMP/changes"; : > "$TMP/log"
	export TMP
	CN_DOMAIN_GUARD_TABLES="$tables" ZORO_ALERT_STAMP_DIR=/proc/nonexistent bash "$TMP/drive.sh"
}
: > "$TMP/alerts"
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
run_drive_raw sw_lan_tproxy
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
Nft_fail_set=killswitch/cn6_domain_ips run_drive_raw "sw_lan_tproxy killswitch"
[ "$(wc -l < "$TMP/alerts")" -ge 2 ] 	&& ok "unwritable stamps keep both outcomes" 	|| bad "unwritable stamps merged both outcomes [$(tr '
' ' ' < "$TMP/alerts")]"

# --- structural: guard is wired into the loop before the health gate ---
grep -q '^_guard_cn_domain_ranges() {' "$WD" \
	&& ok "guard function defined" || bad "guard function missing"
grep -q '\[ "${PLATFORM:-}" = "router" \] || return 0' "$WD" \
	&& ok "guard is router-only" || bad "guard lacks a router gate"
grep -q '_guard_cn_domain_ranges' "$WD" \
	&& ok "guard call present" || bad "guard call missing"
GUARD_LINE=$(grep -n '_guard_cn_domain_ranges$' "$WD" | tail -1 | cut -d: -f1)
HEALTH_LINE=$(grep -n '^[[:space:]]*health=\$(check_vpn_health)' "$WD" | head -1 | cut -d: -f1)
if [ -n "$GUARD_LINE" ] && [ -n "$HEALTH_LINE" ] && [ "$GUARD_LINE" -lt "$HEALTH_LINE" ]; then
	ok "guard runs before the health gate"
else
	bad "guard is not before the health gate (guard=$GUARD_LINE health=$HEALTH_LINE)"
fi

# --- the scheduling gate itself is executable and must fire on interval ---
cat > "$TMP/due.sh" <<'EOF'
source ./surflare_watchdog.sh --source-only
PLATFORM=router
log() { :; }
CN_DOMAIN_GUARD_INTERVAL=60
_cn_domain_guard_last=0
_cn_domain_guard_due 59; echo "early=$? last=${_cn_domain_guard_last:-none}"
_cn_domain_guard_due 60; echo "due=$? last=${_cn_domain_guard_last:-none}"
_cn_domain_guard_due 61; echo "again=$? last=${_cn_domain_guard_last:-none}"
_cn_domain_guard_last=1000
_cn_domain_guard_due 80; echo "rebase=$? last=${_cn_domain_guard_last:-none}"
CN_DOMAIN_GUARD_INTERVAL=abc
_cn_domain_guard_last=0
_cn_domain_guard_due 1; echo "invalid=$? last=${_cn_domain_guard_last:-none}"
EOF
DUE=$(bash "$TMP/due.sh" 2>/dev/null)
printf '%s\n' "$DUE" | grep -qx 'early=1 last=0' \
	&& printf '%s\n' "$DUE" | grep -qx 'due=0 last=60' \
	&& printf '%s\n' "$DUE" | grep -qx 'again=1 last=60' \
	&& printf '%s\n' "$DUE" | grep -qx 'rebase=0 last=80' \
	&& printf '%s\n' "$DUE" | grep -qx 'invalid=1 last=0' \
	&& ok "guard scheduling gate fires on interval and rebases a future stamp" \
	|| bad "guard scheduling gate wrong [$DUE]"

# --- the log gate writes one record per class per window ---
rm -rf "$TMP/logstamps"; mkdir -p "$TMP/logstamps"
cat > "$TMP/logonce.sh" <<'EOF'
source ./surflare_watchdog.sh --source-only
PLATFORM=router
log() { printf '%s\n' "$*" >> "$LOGOUT"; }
export LOGOUT ZORO_ALERT_STAMP_DIR
_cn_domain_guard_log_once same one
_cn_domain_guard_log_once same two
_cn_domain_guard_log_once other three
EOF
LOGOUT="$TMP/logonce.out"; : > "$LOGOUT"
LOGOUT="$LOGOUT" ZORO_ALERT_STAMP_DIR="$TMP/logstamps" bash "$TMP/logonce.sh" 2>/dev/null
[ "$(wc -l < "$TMP/logonce.out")" -eq 2 ] \
	&& grep -q 'three' "$TMP/logonce.out" \
	&& ok "log gate is per message class" \
	|| bad "log gate wrote [$(wc -l < "$TMP/logonce.out")] records"

# --- a hyphenated class key still throttles when stamps are unwritable ---
cat > "$TMP/logonce2.sh" <<'EOF'
source ./surflare_watchdog.sh --source-only
PLATFORM=router
log() { printf '%s\n' "$*" >> "$LOGOUT"; }
export LOGOUT ZORO_ALERT_STAMP_DIR
_cn_domain_guard_log_once guard-repaired one
_cn_domain_guard_log_once guard-repaired two
EOF
LOGOUT="$TMP/logonce2.out"; : > "$LOGOUT"
LOGOUT="$LOGOUT" ZORO_ALERT_STAMP_DIR=/proc/nonexistent \
	bash "$TMP/logonce2.sh" 2>"$TMP/logonce2.err"
[ "$(wc -l < "$TMP/logonce2.out")" -eq 1 ] && [ ! -s "$TMP/logonce2.err" ] \
	&& ok "hyphenated log class throttles without errors" \
	|| bad "hyphenated log class did not throttle [$(wc -l < "$TMP/logonce2.out") records, err: $(head -1 "$TMP/logonce2.err")]"

# --- the loop's gate consumes the interval, the guard must still run ---
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
DRIVE_MODE=loop run_drive "sw_lan_tproxy killswitch"
[ -s "$TMP/changes" ] \
	&& ok "guard runs from the loop after the gate fires" \
	|| bad "guard is gated twice and never runs [$(tr '\n' ' ' < "$TMP/changes")]"

# --- the nft calls are bounded by the timeout wrapper ---
cat > "$TMP/timeout_probe.sh" <<'EOF2'
source ./surflare_watchdog.sh --source-only
TMP_REC="$TMP/timeout.rec"
timeout() { printf '%s\n' "$*" >> "$TMP_REC"; shift; "$@"; }
export -f timeout 2>/dev/null || true
_cn_domain_nft list tables >/dev/null 2>&1
EOF2
rm -rf "$TMP/bin_nft"; mkdir -p "$TMP/bin_nft"
cat > "$TMP/bin_nft/nft" <<'EOF2'
#!/bin/sh
echo "table inet sw_lan_tproxy"
EOF2
chmod +x "$TMP/bin_nft/nft"
PATH="$TMP/bin_nft:$PATH" bash "$TMP/timeout_probe.sh" >/dev/null 2>&1
[ -s "$TMP/timeout.rec" ] && grep -q '^10 nft' "$TMP/timeout.rec" \
	&& ok "nft calls run under a timeout bound" \
	|| bad "nft calls are unbounded [$(cat "$TMP/timeout.rec" 2>/dev/null | head -1)]"

# --- an invalid span knob is reported and the default still applies ---
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
CN_DOMAIN_MIN_SPAN=abc run_drive "sw_lan_tproxy killswitch"
grep -q 'invalid CN_DOMAIN_MIN_SPAN' "$TMP/log" \
	&& grep -q '^killswitch/cn_domain_ips$' "$TMP/changes" \
	&& ok "invalid span knob warns and still repairs" \
	|| bad "invalid span knob changed behaviour silently"

# --- the unwritable-stamp fallback separates causes inside one process ---
cat > "$TMP/fallback_two.sh" <<'EOF2'
source ./surflare_watchdog.sh --source-only
_deliver_alert() { printf '%s\n' "$*" >> "$TMP/alerts2"; }
export ZORO_ALERT_STAMP_DIR=/proc/nonexistent CN_DOMAIN_GUARD_SUPPRESS=86400
_cn_domain_guard_alert one unrepaired inspect
_cn_domain_guard_alert two unrepaired absent_copy
_cn_domain_guard_alert three unrepaired inspect
EOF2
: > "$TMP/alerts2"
bash "$TMP/fallback_two.sh" >/dev/null 2>&1
[ "$(wc -l < "$TMP/alerts2")" -eq 2 ] \
	&& ok "fallback timer separates causes" \
	|| bad "fallback timer merged two causes [$(wc -l < "$TMP/alerts2") pages]"

# --- a set holding nothing but a wide range reports an emptied cache ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "139.196.16.27-150.138.220.221"
run_drive "sw_lan_tproxy killswitch"
grep -q 'held nothing but a wide range' "$TMP/alerts" \
	&& ok "emptied cache is reported as emptied" \
	|| bad "emptied cache reported as a rebuild [$(head -1 "$TMP/alerts")]"

# --- a mixed run still names the set it emptied ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "139.196.16.27-150.138.220.221"
set_named sw_lan_tproxy gmail_smtp6 '2600:1900::1, 2001:db8::/32'
set_named killswitch gmail_smtp6 '2600:1900::1, 2001:db8::/32'
run_drive "sw_lan_tproxy killswitch"
grep -q 'cn_domain_ips held nothing else and is now empty' "$TMP/alerts" \
	&& ok "mixed run names the emptied set" \
	|| bad "mixed run hid the emptied set [$(head -1 "$TMP/alerts")]"

# --- the call site is a plain gate, not a conditional or a diag branch ---
CALL_START=$(grep -n '_now_cn_guard=\$(date +%s)$' "$WD" | head -1 | cut -d: -f1)
mapfile -t CALL_LINES < <(sed -n "${CALL_START},$((CALL_START + 3))p" "$WD" | sed 's/[[:space:]]//g')
[ "${CALL_LINES[0]:-}" = '_now_cn_guard=$(date+%s)' ] \
	&& [ "${CALL_LINES[1]:-}" = 'if_cn_domain_guard_due"$_now_cn_guard";then' ] \
	&& [ "${CALL_LINES[2]:-}" = '_guard_cn_domain_ranges' ] \
	&& [ "${CALL_LINES[3]:-}" = 'fi' ] \
	&& ok "call site is an unconditional interval gate" \
	|| bad "call site can be disabled or moved [$(printf '%s' "$(sed -n "${CALL_START},$((CALL_START + 3))p" "$WD" | tr '\n' '|')")]"

# --- gmail_smtp6 is guarded like the other v6 cache ---
set_named sw_lan_tproxy gmail_smtp6 '2600:1900::1, 2001:db8::/32'
set_named killswitch gmail_smtp6 '2600:1900::1, 2001:db8::/32'
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/gmail_smtp6=2600:1900::1$' "$TMP/entries" \
	&& grep -q '^killswitch/gmail_smtp6=2600:1900::1$' "$TMP/entries" \
	&& ! grep -q '2001:db8::/32' "$TMP/entries" \
	&& ok "gmail_smtp6 wide prefix dropped, host kept" \
	|| bad "gmail_smtp6 was not guarded [$(tr '\n' ' ' < "$TMP/entries")]"

# --- a stamp dated in the future must not suppress a page ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
rm -rf "$TMP/fs"; mkdir -p "$TMP/fs"
touch -d '+2 hours' "$TMP/fs/cn_domain_guard.repaired_rebuilt.stamp"
: > "$TMP/changes"; : > "$TMP/entries"; : > "$TMP/log"; : > "$TMP/alerts"
export TMP ZORO_ALERT_STAMP_DIR="$TMP/fs" PLATFORM=router
CN_DOMAIN_GUARD_TABLES="sw_lan_tproxy" bash "$TMP/drive.sh" >/dev/null 2>&1
grep -q 'DNS cache rebuilt' "$TMP/alerts" \
	&& ok "a future stamp does not silence the page" \
	|| bad "a future stamp suppressed the page [$(head -1 "$TMP/alerts")]"

# --- a malformed table name stops the cycle instead of writing one copy ---
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
CN_DOMAIN_GUARD_TABLES="sw_lan_tproxy killswitch typo-name" run_drive "sw_lan_tproxy killswitch typo-name"
[ ! -s "$TMP/changes" ] && grep -q 'not a usable table name' "$TMP/alerts" \
	&& ok "a malformed table name stops the cycle" \
	|| bad "a malformed table name still wrote [$(tr '\n' ' ' < "$TMP/changes")]"

# --- two dirty sets in one family keep their own entries ---
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
set_named sw_lan_tproxy gmail_smtp "140.82.113.5, 10.0.0.0/8"
set_table killswitch "8.8.8.8, 139.196.16.27-150.138.220.221"
set_named killswitch gmail_smtp "140.82.113.5, 10.0.0.0/8"
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/cn_domain_ips=8.8.8.8$' "$TMP/entries" \
	&& ! grep -q '^sw_lan_tproxy/cn_domain_ips=140.82.113.5$' "$TMP/entries" \
	&& grep -q '^sw_lan_tproxy/gmail_smtp=140.82.113.5$' "$TMP/entries" \
	&& ! grep -q '^sw_lan_tproxy/gmail_smtp=8.8.8.8$' "$TMP/entries" \
	&& ok "two dirty sets keep their own entries" \
	|| bad "a dirty set took the other set's entry [$(tr '\n' ' ' < "$TMP/entries")]"

# --- a /127 v6 prefix is flagged, a /128 is not ---
set_named sw_lan_tproxy cn6_domain_ips '2001:db8::2/127'
set_named killswitch cn6_domain_ips '2001:db8::2/127'
run_drive "sw_lan_tproxy killswitch"
grep -q '^killswitch/cn6_domain_ips$' "$TMP/changes" \
	&& ! grep -q '2001:db8::2/127' "$TMP/entries" \
	&& ok "a /127 v6 prefix is flagged" \
	|| bad "a /127 v6 prefix survived [$(tr '\n' ' ' < "$TMP/entries")]"

# --- an IPv4-mapped v6 address keeps its dotted quad ---
set_named sw_lan_tproxy cn6_domain_ips '::ffff:8.8.8.8, 2001:db8::/32'
set_named killswitch cn6_domain_ips '::ffff:8.8.8.8, 2001:db8::/32'
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/cn6_domain_ips=::ffff:8.8.8.8$' "$TMP/entries" \
	&& ok "a mapped v6 address keeps its dotted quad" \
	|| bad "a mapped v6 address was mangled [$(tr '\n' ' ' < "$TMP/entries")]"

# --- a timed out batch says the result is unverified ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "139.196.16.27-150.138.220.221"
Nft_timeout=1 run_drive "sw_lan_tproxy killswitch"
grep -q 'timed out and its result is unverified' "$TMP/alerts" \
	&& ok "a timed out rebuild is reported as unverified" \
	|| bad "a timed out rebuild was reported as a clean rollback [$(head -1 "$TMP/alerts")]"

# --- no configured table present is reported once ---
rm -f "$TMP"/sw_lan_tproxy.*.set "$TMP"/killswitch.*.set
run_drive "sw_lan_tproxy killswitch"
grep -q 'no configured table present' "$TMP/log" \
	&& ok "an empty table set is reported" \
	|| bad "an empty table set was silent"

# --- real stamps keep causes apart inside one window ---
rm -rf "$TMP/fs2"; mkdir -p "$TMP/fs2"
cat > "$TMP/cause_probe.sh" <<'EOF2'
source ./surflare_watchdog.sh --source-only
_deliver_alert() { printf '%s\n' "$*" >> "$TMP/alerts3"; }
export ZORO_ALERT_STAMP_DIR="$TMP/fs2" CN_DOMAIN_GUARD_SUPPRESS=3600
_cn_domain_guard_alert one unrepaired inspect
_cn_domain_guard_alert two unrepaired absent_copy
_cn_domain_guard_alert three unrepaired inspect
EOF2
: > "$TMP/alerts3"
bash "$TMP/cause_probe.sh" >/dev/null 2>&1
[ "$(wc -l < "$TMP/alerts3")" -eq 2 ] \
	&& ok "real stamps separate the causes" \
	|| bad "real stamps merged two causes [$(wc -l < "$TMP/alerts3") pages]"

# --- a successful rebuild logs a positive record ---
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
run_drive "sw_lan_tproxy killswitch"
grep -q 'DNS cache rebuilt' "$TMP/log" \
	&& ok "a rebuild leaves a positive log record" \
	|| bad "a rebuild left no positive record"

# --- a compressed v6 prefix is tokenised whole, not truncated ---
set_named sw_lan_tproxy cn6_domain_ips '2001:db8::/32, 2606:4700::1111'
set_named killswitch cn6_domain_ips '2001:db8::/32, 2606:4700::1111'
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/cn6_domain_ips=2606:4700::1111$' "$TMP/entries" \
	&& ! grep -qE '=(2001:db8|2001:db8::/32)$' "$TMP/entries" \
	&& ok "compressed v6 prefix is dropped whole, host kept" \
	|| bad "compressed v6 prefix was truncated [$(tr '\n' ' ' < "$TMP/entries")]"

# --- an unparsed set does not also blame the peer ---
cat > "$TMP/sw_lan_tproxy.cn_domain_ips.set" <<'EOF2'
table inet sw_lan_tproxy {
	set cn_domain_ips {
		type ipv4_addr
		flags interval,timeout
		timeout 1h
		elements = { not-an-address }
	}
}
EOF2
set_table killswitch "1.1.1.1"
run_drive "sw_lan_tproxy killswitch"
grep -q 'could not be parsed' "$TMP/alerts" \
	&& ! grep -q 'is missing from' "$TMP/alerts" \
	&& ok "an unparsed set does not blame the peer" \
	|| bad "an unparsed set also paged a peer-missing cause [$(tr '\n' '|' < "$TMP/alerts")]"

# --- housekeeping pages stay off the emergency fallback ---
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
rm -f "$TMP"/killswitch.*.set
run_drive "sw_lan_tproxy killswitch"
grep -q 'table killswitch is absent' "$TMP/alerts" \
	&& grep -q ' yes ' "$TMP/alerts" \
	&& ok "a deferral page keeps the emergency fallback" \
	|| bad "a deferral page is off the emergency channel [$(head -1 "$TMP/alerts")]"

# --- a v6 interval is dropped whole, not as two endpoints ---
set_named sw_lan_tproxy cn6_domain_ips '2001:db8::1-2001:db8::9, 2606:4700::1111'
set_named killswitch cn6_domain_ips '2001:db8::1-2001:db8::9, 2606:4700::1111'
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/cn6_domain_ips=2606:4700::1111$' "$TMP/entries" \
	&& ! grep -q '2001:db8::1$' "$TMP/entries" \
	&& ! grep -q '2001:db8::9$' "$TMP/entries" \
	&& ok "a v6 interval leaves no endpoints behind" \
	|| bad "v6 interval endpoints were written back [$(tr '\n' ' ' < "$TMP/entries")]"

# --- an un-repaired page keeps the emergency fallback ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
Nft_fail_change=killswitch/cn_domain_ips run_drive "sw_lan_tproxy killswitch"
grep -q ' yes ' "$TMP/alerts" \
	&& ok "an un-repaired page keeps the emergency fallback" \
	|| bad "an un-repaired page lost the emergency channel [$(head -1 "$TMP/alerts")]"

# --- the span knob is honoured, not just validated ---
set_table sw_lan_tproxy "10.0.0.0/30, 10.0.1.0/31"
set_table killswitch "1.1.1.1"
CN_DOMAIN_MIN_SPAN=4 run_drive sw_lan_tproxy
! grep -q '10.0.1' "$TMP/changes" \
	&& grep -q '^sw_lan_tproxy/cn_domain_ips=10.0.1.0/31$' "$TMP/entries" \
	&& ok "a higher span threshold keeps the /31" \
	|| bad "the span threshold was ignored [$(tr '\n' ' ' < "$TMP/entries")]"

# --- a future log stamp does not silence the on-disk diagnosis ---
set_table sw_lan_tproxy "139.196.16.27-150.138.220.221"
rm -rf "$TMP/fs3"; mkdir -p "$TMP/fs3"
touch -d '+2 hours' "$TMP/fs3/cn_domain_guard.log.holds.stamp"
: > "$TMP/changes"; : > "$TMP/log"; : > "$TMP/alerts"
export TMP ZORO_ALERT_STAMP_DIR="$TMP/fs3" PLATFORM=router
CN_DOMAIN_GUARD_TABLES="sw_lan_tproxy" bash "$TMP/drive.sh" >/dev/null 2>&1
grep -q 'holds' "$TMP/log" \
	&& ok "a future log stamp does not silence the diagnosis" \
	|| bad "a future log stamp silenced the log record"

# --- an unparsed copy plus a dirty peer must not rebuild one side ---
cat > "$TMP/sw_lan_tproxy.cn_domain_ips.set" <<'EOF2'
table inet sw_lan_tproxy {
	set cn_domain_ips {
		type ipv4_addr
		flags interval,timeout
		timeout 1h
		elements = { not-an-address }
	}
}
EOF2
set_table killswitch "139.196.16.27-150.138.220.221, 1.1.1.1"
run_drive "sw_lan_tproxy killswitch"
[ ! -s "$TMP/changes" ] \
	&& ok "an unparsed copy blocks the peer rebuild" \
	|| bad "rebuilt the peer while one copy was unparsed [$(tr '\n' ' ' < "$TMP/changes")]"

# --- a comment must not swallow the entry that follows it ---
cat > "$TMP/sw_lan_tproxy.cn_domain_ips.set" <<'EOF2'
table inet sw_lan_tproxy {
	set cn_domain_ips {
		type ipv4_addr
		flags interval,timeout
		timeout 1h
		elements = { 1.1.1.1 comment "note", 140.82.113.5, 139.196.16.27-150.138.220.221 }
	}
}
EOF2
set_table killswitch "1.1.1.1, 140.82.113.5"
run_drive "sw_lan_tproxy killswitch"
grep -q '^sw_lan_tproxy/cn_domain_ips=140.82.113.5$' "$TMP/entries" \
	&& ok "an inline comment does not swallow the next entry" \
	|| bad "an inline comment dropped a healthy entry [$(tr '\n' ' ' < "$TMP/entries")]"

# --- rebuilt entries carry the set lifetime ---
set_table sw_lan_tproxy "8.8.8.8, 139.196.16.27-150.138.220.221"
set_table killswitch "1.1.1.1"
run_drive "sw_lan_tproxy killswitch"
grep -q 'timeout 1h' "$TMP/rawbatch" 2>/dev/null \
	&& ok "rebuilt entries carry the set lifetime" \
	|| bad "rebuilt entries lost their lifetime"

# --- a zero interval falls back to the 60 s floor ---
CN_DOMAIN_GUARD_INTERVAL=0 bash -c '
	source ./surflare_watchdog.sh --source-only
	_now=$(date +%s)
	_cn_domain_guard_due "$_now" || exit 1
	_cn_domain_guard_due "$_now" && exit 2
	exit 0
' >/dev/null 2>&1
[ "$?" -eq 0 ] \
	&& ok "a zero interval falls back to the floor" \
	|| bad "a zero interval let two cycles run in one second"

# --- an escaped quote in a comment refuses the set ---
cat > "$TMP/sw_lan_tproxy.cn_domain_ips.set" <<'EOF2'
table inet sw_lan_tproxy {
	set cn_domain_ips { type ipv4_addr; flags interval,timeout; timeout 1h; elements = { 8.8.8.8 comment "net \"10.0.0.0/8\" here" } }
}
EOF2
set_table killswitch "1.1.1.1"
run_drive "sw_lan_tproxy killswitch"
[ ! -s "$TMP/changes" ] && grep -q 'unparsable comment' "$TMP/alerts" \
	&& ok "an escaped quote in a comment refuses the set" \
	|| bad "an escaped quote comment reached the batch [$(tr '\n' ' ' < "$TMP/entries")]"

# --- an absurd span knob is clamped instead of disabling the check ---
set_table sw_lan_tproxy "8.8.8.8, 10.0.0.0/16"
set_table killswitch "1.1.1.1"
CN_DOMAIN_MIN_SPAN=99999 run_drive "sw_lan_tproxy killswitch"
grep -q 'above the supported maximum' "$TMP/log" \
	&& grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& ok "an absurd span knob is clamped and still repairs" \
	|| bad "an absurd span knob disabled the check [$(tr '\n' ' ' < "$TMP/changes")]"

# --- the shipped default guards every cache set ---
for want in cn_domain_ips cn6_domain_ips surflare_control gmail_smtp gmail_smtp6; do
	grep -q "^CN_DOMAIN_GUARD_SETS=.*\b${want}\b" ./surflare_watchdog.sh \
		|| bad "the default guarded set list lost ${want}"
done
ok "the default guarded set list names all five caches"

# --- the deferral window and the causes that use it ---
grep -q '_suppress=$((_suppress \* 8))' ./surflare_watchdog.sh \
	&& ok "the deferral window is eight times the base window" \
	|| bad "the deferral window multiplier changed"
grep -qE '^[[:space:]]*absent_copy\|absent_table\|parse\)$' ./surflare_watchdog.sh \
	&& ok "a listing read but not understood is treated as the incident state" \
	|| bad "a listing read but not understood was moved off the incident channel"

# --- a read that warns on stderr must not feed the element scan ---
cat > "$TMP/sw_lan_tproxy.cn_domain_ips.set" <<'EOF2'
table inet sw_lan_tproxy {
	set cn_domain_ips { type ipv4_addr; flags interval,timeout; timeout 1h; elements = { 8.8.8.8, 139.196.16.27-150.138.220.221 } }
}
EOF2
set_table killswitch "1.1.1.1"
Nft_stderr="warning: 6.6.6.6 is stale" run_drive "sw_lan_tproxy killswitch"
grep -q '6.6.6.6' "$TMP/entries" \
	&& bad "a stderr warning was re-added as an address" \
	|| ok "a stderr warning never becomes an address"

# --- both families reset their offender list ---
cat > "$TMP/sw_lan_tproxy.cn_domain_ips.set" <<'EOF2'
table inet sw_lan_tproxy {
	set cn_domain_ips { type ipv4_addr; flags interval,timeout; timeout 1h; elements = { 8.8.8.8, 139.196.16.27-150.138.220.221 } }
}
EOF2
set_table killswitch "1.1.1.1"
cat > "$TMP/sw_lan_tproxy.cn6_domain_ips.set" <<'EOF2'
table inet sw_lan_tproxy {
	set cn6_domain_ips { type ipv6_addr; flags interval,timeout; timeout 1h; elements = { 2606:4700::/32 } }
}
EOF2
cat > "$TMP/killswitch.cn6_domain_ips.set" <<'EOF2'
table inet killswitch {
	set cn6_domain_ips { type ipv6_addr; flags interval,timeout; timeout 1h; elements = { 2606:4700::1111 } }
}
EOF2
run_drive "sw_lan_tproxy killswitch"
[ "$(grep -c 'FLUSH:.*cn_domain_ips' "$TMP/changes")" -eq 2 ] \
	&& ok "each family flushes only its own sets once" \
	|| bad "a family re-flushed another family's sets [$(tr '\n' ' ' < "$TMP/changes")]"

# --- a real quote inside a comment is refused, not parsed ---
cat > "$TMP/sw_lan_tproxy.cn_domain_ips.set" <<'EOF2'
table inet sw_lan_tproxy {
	set cn_domain_ips { type ipv4_addr; flags interval,timeout; timeout 1h; elements = { 8.8.8.8 comment "x "140.82.113.5" y" } }
}
EOF2
set_table killswitch "1.1.1.1"
run_drive "sw_lan_tproxy killswitch"
[ ! -s "$TMP/changes" ] && grep -q ' yes ' "$TMP/alerts" \
	&& ok "a quote inside a comment refuses the set on the incident channel" \
	|| bad "a quoted comment reached the batch [$(tr '\n' ' ' < "$TMP/entries")]"

# --- an invalid span ceiling still clamps ---
set_table sw_lan_tproxy "8.8.8.8, 10.0.0.0/16"
set_table killswitch "1.1.1.1"
CN_DOMAIN_MIN_SPAN=99999 CN_DOMAIN_MIN_SPAN_MAX=notanumber run_drive "sw_lan_tproxy killswitch"
grep -q 'invalid CN_DOMAIN_MIN_SPAN_MAX' "$TMP/log" \
	&& grep -q '^sw_lan_tproxy/cn_domain_ips$' "$TMP/changes" \
	&& ok "an invalid span ceiling still clamps" \
	|| bad "an invalid span ceiling disabled the check"

# --- two wide spans in the same set each leave a record ---
cat > "$TMP/sw_lan_tproxy.cn_domain_ips.set" <<'EOF2'
table inet sw_lan_tproxy {
	set cn_domain_ips { type ipv4_addr; flags interval,timeout; timeout 1h; elements = { 139.196.16.27-150.138.220.221, 104.16.0.0/12 } }
}
EOF2
cat > "$TMP/killswitch.cn_domain_ips.set" <<'EOF2'
table inet killswitch {
	set cn_domain_ips { type ipv4_addr; flags interval,timeout; timeout 1h; elements = { 1.1.1.1 } }
}
EOF2
run_drive "sw_lan_tproxy killswitch"
[ "$(grep -c 'holds' "$TMP/log")" -ge 2 ] \
	&& ok "each wide span in one set leaves its own record" \
	|| bad "records for one set collapsed [$(grep -c 'holds' "$TMP/log")]"

# --- the shipped default inspects both tables ---
DEFAULT_TABLES=$(bash -c 'source ./surflare_watchdog.sh --source-only; printf "%s" "$CN_DOMAIN_GUARD_TABLES"' 2>/dev/null)
[ "$DEFAULT_TABLES" = "sw_lan_tproxy killswitch" ] \
	&& ok "default table list covers both tables" \
	|| bad "default table list is [$DEFAULT_TABLES]"

bash -n < "$WD" && ok "bash -n" || bad "bash -n"

# --- real nft path in a user+net namespace, when available ---
if unshare -Urn true 2>/dev/null; then
	OUT=$(unshare -Urn bash -c '
		cd "'"$PWD"'" || exit 1
		nft add table inet sw_lan_tproxy || exit 1
		nft add set inet sw_lan_tproxy cn_domain_ips "{ type ipv4_addr; flags interval,timeout; timeout 1h; }" || exit 1
		nft add element inet sw_lan_tproxy cn_domain_ips "{ 139.196.16.27-150.138.220.221, 8.8.8.8 }" || exit 1
		log() { :; }
		_deliver_alert() { :; }
		export ZORO_ALERT_STAMP_DIR=/proc/nonexistent PLATFORM=router PLATFORM=router PLATFORM=router
		CN_DOMAIN_GUARD_TABLES=sw_lan_tproxy
		source ./surflare_watchdog.sh --source-only
PLATFORM=router
		_guard_cn_domain_ranges
		RANGE=$(nft list set inet sw_lan_tproxy cn_domain_ips | grep -c "139.196.16.27")
		HEALTHY=$(nft list set inet sw_lan_tproxy cn_domain_ips | grep -c "8.8.8.8")
		echo "${RANGE}/${HEALTHY}"
	' 2>/dev/null)
	if [ "$OUT" = "0/1" ]; then
		ok "real nft: range removed, healthy entry kept"
	else
		bad "real nft: range still present or healthy entry lost [$OUT]"
	fi
else
	echo "SKIP: real nft namespace test (unshare unavailable)"
fi

exit "$fail"
