#!/bin/bash
# Every destructive nft write either runs under the shared lock or is listed
# below with the reason it does not.  A new unlocked site fails this gate, so
# the remaining work cannot grow quietly while the list stays honest.
#
# Exit: 0 = no new unlocked sites, 1 = a site appeared that is not accounted
# for, 2 = the script could not be read.
set -u
WD=${1:-surflare_watchdog.sh}
[ -r "$WD" ] || { echo "cannot read $WD" >&2; exit 2; }

# Locked: the write is passed through nft_apply_locked, or sits between an
# acquire and its release in the same function.
locked_fns="_install_killswitch _restore_tproxy cleanup_probe_state"

# Not locked, by decision.  Keep a reason on each line; an entry without one is
# a bug in this list, not a decision.
allowed_fns="
_setup_kernel_moat	builds its own table once at boot, before any other writer exists
_setup_chnroute	loads static CN ranges at boot and on refresh; a lost range is rebuilt by the next refresh
_load_tproxy_cn_direct	adds one rule to a table it does not replace
_guard_cn_domain_ranges	deletes one range element; it has its own retry and never replaces a table
_cleanup_on_startup	boot-time cleanup, single instance guaranteed by the singleton lock
_ensure_dns_enforce	adds one rule to an existing chain
_reinstall_killswitch_output	rebuilds one chain of the killswitch table, not the table
_remove_killswitch	removal path; must work when the lock is what is wedged
_update_bypass_devices	updates set elements, not rules or tables
_sync_dns_enforce_bypass	updates set elements
_update_killswitch_server_ips	updates set elements of the killswitch table, never its rules
_install_cn_dns_direct	creates its own table with no other writer
_exempt_cn_output	appends one rule
connect_vpn	the reconnect owns the whole rebuild; it calls the locked restore
start_packet_trace	creates a trace table of its own
stop_packet_trace	removes the trace table it created
_check_trace_alive	recreates the trace table it owns
_full_teardown	deletes every table: a teardown that blocks on a wedged writer cannot do its job
<top-level>	startup prologue and one-shot repairs, before the health loop runs
"

locked_hits=0
unexpected=""

fn=""
while IFS= read -r line; do
	case "$line" in
	[A-Za-z_]*"() {") fn=${line%%"() {"*}; continue ;;
	"}") fn=""; continue ;;
	esac
	case "$line" in
	"#"* | *"log "* | *"printf '"*) continue ;;
	esac
	case "$line" in
	*"nft -f"* | *"nft flush table"* | *"nft delete table"* | *"destroy table"*) : ;;
	*) continue ;;
	esac
	key=${fn:-<top-level>}
	case " $locked_fns " in
	*" $key "*)
		locked_hits=$((locked_hits + 1))
		continue
		;;
	esac
	if printf '%s\n' "$allowed_fns" | cut -f1 | grep -qx -- "$key"; then
		case "$key" in
		*fns*) unexpected="$unexpected $key(no-reason)" ;;
		esac
		continue
	fi
	unexpected="$unexpected $key"
done < "$WD"

# The list must carry a reason for every entry, and every entry must still
# exist in the script: a stale allowlist is how a gate turns into decoration.
missing_reason=$(printf '%s\n' "$allowed_fns" | grep -v '^$' | grep -vc $'\t')
listed=$(printf '%s\n' "$allowed_fns" | cut -f1 | grep -v '^$')
stale=""
for f in $listed; do
	grep -q "^${f//.</\\.}() {" "$WD" 2>/dev/null || [ "$f" = "<top-level>" ] || stale="$stale $f"
done

rc=0
if [ -n "$unexpected" ]; then
	echo "FAIL: destructive nft write outside the lock, not accounted for:$unexpected"
	rc=1
fi
if [ "$missing_reason" -ne 0 ]; then
	echo "FAIL: $missing_reason allowlist entries carry no reason"
	rc=1
fi
if [ -n "$stale" ]; then
	echo "FAIL: allowlist names functions that no longer exist:$stale"
	rc=1
fi
if [ "$locked_hits" -eq 0 ]; then
	echo "FAIL: no locked site found; did the lock helpers get removed?"
	rc=1
fi
[ "$rc" -eq 0 ] && echo "OK: $locked_hits locked writes, $(printf '%s\n' "$listed" | grep -c .) accounted for"
exit "$rc"
