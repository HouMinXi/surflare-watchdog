#!/bin/bash
# Two invariant checks on the tick's repair paths: stale fwmark rules are
# drained rather than deleted once, and a reconnect retires the PROXY_BROKEN
# confirmation window instead of inheriting a clock measured on a dead tunnel.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

# --- case 1: no single-shot delete of the fwmark rule --------------------
if grep -n 'ip rule del fwmark 0x1 lookup 100' "$WD" | grep -v '^[0-9]*:[[:space:]]*while ' | grep -q .; then
	bad "a single-shot fwmark delete remains: $(grep -n 'ip rule del fwmark 0x1 lookup 100' "$WD" | grep -v 'while ' | head -2)"
else
	ok "every fwmark deletion drains in a loop"
fi

# --- case 2: the teardown drain removes every stale rule -----------------
# Drive the loops exactly as they appear in the file, against an ip stub that
# starts with two residual rules.
# Only the loops inside _full_teardown: scraping every matching line in the
# file ran eight loops from four functions, and the first one drained the
# fixture before the loop under test got a turn.
awk '
	/^_full_teardown\(\) \{/ { i = 1 }
	i && /while ip (-6 )?rule del fwmark 0x1 lookup 100.*done$/ { print }
	i && /^}$/ { exit }
' "$WD" > "$TMP/drain.sh"
if [ ! -s "$TMP/drain.sh" ]; then
	bad "no drain loop found to drive"
else
	mkdir -p "$TMP/bin"
	cat > "$TMP/bin/ip" <<'EOS'
#!/bin/bash
[ "$1" = rule ] && [ "$2" = del ] || exit 1
n=$(wc -l < "$IP_STATE")
[ "$n" -gt 0 ] || exit 1
sed -i '$d' "$IP_STATE"
printf 'del\n' >> "$IP_CALLS"
exit 0
EOS
	chmod +x "$TMP/bin/ip"
	printf 'rule\nrule\n' > "$TMP/state"
	: > "$TMP/calls"
	PATH="$TMP/bin:$PATH" IP_STATE="$TMP/state" IP_CALLS="$TMP/calls" bash "$TMP/drain.sh"
	left=$(wc -l < "$TMP/state")
	if [ "$left" -eq 0 ]; then
		ok "the drain loop removes every stale fwmark rule ($(wc -l < "$TMP/calls") deletions)"
	else
		bad "${left} stale fwmark rule(s) survived the drain"
	fi
fi

# --- case 3: connect_vpn retires the PROXY_BROKEN window ----------------
if awk '/^connect_vpn\(\) \{/{i=1} i{print; c++} c>12{exit}' "$WD" \
	| grep -vE '^[[:space:]]*#' | grep -q '_pb_grace_since=0'; then
	ok "connect_vpn resets the PROXY_BROKEN grace clock"
else
	bad "connect_vpn leaves a stale PROXY_BROKEN grace clock for the next cycle"
fi

# --- case 4: a cooldown that ends without a listener keeps the tombstone --
# Drive the exact tail of _enter_storm_cooldown against an ss stub.
# The terminator must tolerate indentation: an anchored `^\tfi$` never matched
# and the extractor swallowed 3,389 lines instead of the five it wanted.
awk '/^[[:space:]]*if ss -ltn 2>\/dev\/null \| grep -qE .:10800/{i=1} i{print} i && /^[[:space:]]*fi[[:space:]]*$/{exit}' "$WD" > "$TMP/tail.sh"
if [ ! -s "$TMP/tail.sh" ] || [ "$(wc -l < "$TMP/tail.sh")" -gt 12 ]; then
	bad "could not extract the cooldown tail ($(wc -l < "$TMP/tail.sh" 2>/dev/null) lines)"
else
	mkdir -p "$TMP/bin"
	cat > "$TMP/bin/ss" <<'EOS'
#!/bin/bash
[ -f "$SS_LISTENING" ] && printf 'LISTEN 0 4096 127.0.0.1:10800 0.0.0.0:*\n'
exit 0
EOS
	chmod +x "$TMP/bin/ss"
	drive_tail() {
		PATH="$TMP/bin:$PATH" SS_LISTENING="$1" bash -c '
			_restore_tproxy() { echo RESTORED; }
			log() { echo "LOG: $*"; }
			. "$1/tail.sh"
		' _ "$TMP" 2>/dev/null
	}
	rm -f "$TMP/listening"
	out=$(drive_tail "$TMP/listening")
	if printf '%s' "$out" | grep -q RESTORED; then
		bad "the tproxy was restored onto a port with no listener"
	else
		ok "no listener means the tombstone stays"
	fi
	touch "$TMP/listening"
	out=$(drive_tail "$TMP/listening")
	if printf '%s' "$out" | grep -q RESTORED; then
		ok "a live listener lets the tproxy come back"
	else
		bad "the tproxy stayed tombstoned with the proxy listening"
	fi
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]