#!/usr/bin/env bash
# bypass_src must refill once after a restart, and must not keep flushing.
#
# The killswitch forward chain reads bypass_src, and a restart leaves that
# set empty until the next VPN reconnect.  The loop refills it.  But the
# refill flushes the set and only puts addresses back when a bypass MAC
# resolves, so while none resolve the set stays empty.  Retrying every
# cycle would flush it forever.  One try, then stop until the set is
# non-empty again.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

WD="surflare_watchdog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The guard, from its opening comment through the `fi` that closes it.
# Two `fi` lines: the inner if/elif and the outer if.
awk '
	/killswitch forward chain actually reads/ { grab=1 }
	grab { print }
	grab && /^[[:space:]]*fi$/ { n++; if (n==2) exit }
' "$WD" > "$TMP/guard.sh"

if ! grep -q '_update_bypass_devices' "$TMP/guard.sh"; then
	bad "the guard does not call _update_bypass_devices"
	echo "FAILED"
	exit 1
fi
ok "the guard calls _update_bypass_devices"

# Stand-ins.  The set is a file: an empty file is an empty set.  The
# refill records how often it ran and writes an address only when one resolves.
cat > "$TMP/fake-nft" << 'EOF'
#!/bin/sh
case "$*" in
	"list table inet killswitch") exit 0 ;;
	"list set inet killswitch bypass_src")
		[ -s "$SETFILE" ] && echo "elements = { $(cat "$SETFILE") }"
		exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/fake-nft"

cat > "$TMP/refill" << 'EOF'
#!/bin/sh
echo x >> "$COUNTFILE"
[ -n "$RESOLVES_TO" ] && echo "$RESOLVES_TO" > "$SETFILE"
EOF
chmod +x "$TMP/refill"

echo "aa:bb:cc:dd:ee:ff" > "$TMP/macs"

# Run the guard N times in one shell so the latch survives between cycles.
run_cycles() {
	PATH="$TMP:$PATH" SETFILE="$TMP/set" COUNTFILE="$TMP/count" \
	RESOLVES_TO="$2" BYPASS_LAN_MACS_FILE="$TMP/macs" \
		bash -c '
			nft() { "'"$TMP"'/fake-nft" "$@"; }
			_update_bypass_devices() { "'"$TMP"'/refill"; }
			log() { :; }
			: > "$COUNTFILE"
			i=0
			while [ "$i" -lt '"$1"' ]; do
				. "'"$TMP"'/guard.sh"
				i=$((i+1))
			done
			echo "calls=$(wc -l < "$COUNTFILE" | tr -d " ")"
			echo "final=$(cat "$SETFILE")"
		'
}

# MAC resolves: one refill puts the address in, later cycles do nothing.
: > "$TMP/set"
out=$(run_cycles 5 "192.168.100.11")
echo "$out" | grep -qx 'calls=1' \
	&& ok "resolving MAC: refilled once in 5 cycles" \
	|| bad "resolving MAC: expected 1 call, got [$(echo "$out" | head -1)]"
echo "$out" | grep -qx 'final=192.168.100.11' \
	&& ok "resolving MAC: set ends with the address" \
	|| bad "resolving MAC: set ended as [$(echo "$out" | tail -1)]"

# MAC never resolves: one attempt, then it stops.  Not one flush per cycle.
: > "$TMP/set"
out=$(run_cycles 5 "")
echo "$out" | grep -qx 'calls=1' \
	&& ok "unresolved MAC: tried once, then stopped" \
	|| bad "unresolved MAC: expected 1 call, got [$(echo "$out" | head -1)]"

# Non-empty, then a rebuild empties it: the latch re-arms and it tries again.
: > "$TMP/count"
printf '192.168.100.11\n' > "$TMP/set"
out=$(bash -c '
	nft() { "'"$TMP"'/fake-nft" "$@"; }
	_update_bypass_devices() { "'"$TMP"'/refill"; }
	log() { :; }
	SETFILE="'"$TMP"'/set" COUNTFILE="'"$TMP"'/count"
	RESOLVES_TO="" BYPASS_LAN_MACS_FILE="'"$TMP"'/macs"
	export SETFILE COUNTFILE RESOLVES_TO BYPASS_LAN_MACS_FILE
	. "'"$TMP"'/guard.sh"
	: > "$SETFILE"
	. "'"$TMP"'/guard.sh"
	echo "calls=$(wc -l < "$COUNTFILE" | tr -d " ")"
')
echo "$out" | grep -qx 'calls=1' \
	&& ok "emptied after being full: tries again" \
	|| bad "emptied after being full: expected 1 call, got [$out]"

# The resolve-nothing branch must not flush.  It sits between the
# `if [ -z "$all_ips" ]` test and its `return 0`, and a flush there empties
# bypass_devices, which the loop guard then refills every cycle.
branch=$(awk '
	/\$all_ips" \] && \[ -z "\$all_v6"/{p=1}
	p { print }
	p && /return 0/{ exit }
' "$WD")
if printf '%s\n' "$branch" | grep -q 'flush set'; then
	bad "resolve-nothing branch still flushes: $(printf '%s' "$branch" | grep flush | head -1)"
else
	ok "resolve-nothing branch does not flush"
fi

[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "FAILED"
exit "$fail"
