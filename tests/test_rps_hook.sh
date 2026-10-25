#!/bin/bash
# The receive-spread hook fires once, on a link event that may never come again.
# If its write is refused it must say so, because nothing else re-checks it: the
# queue simply stays on one core and the log claims success.
set -u
cd "$(dirname "$0")/.." || exit 1
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/logger" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$LOG"
EOS
chmod +x "$TMP/bin/logger"

hook() { # $1 = queue path, $2 = ACTION
	LOG="$TMP/log" QUEUE="$1" ACTION="${2:-add}" PATH="$TMP/bin:$PATH" sh router/hotplug/30-rps-wan-eth0
}

: > "$TMP/q"
: > "$TMP/log"
hook "$TMP/q"
if [ "$(cat "$TMP/q")" = "e" ] && grep -q 'rps_cpus set to e' "$TMP/log"; then
	ok "a writable queue is set and logged as set"
else
	bad "the hook did not set a writable queue (log: $(cat "$TMP/log"))"
fi

# Read-only queue: the write is refused and the log must not claim success.
mkdir -p "$TMP/ro"
: > "$TMP/ro/q"
chmod 444 "$TMP/ro/q"
if [ "$(id -u)" -eq 0 ]; then
	# root ignores the mode; the case is untestable here and saying so beats
	# reporting a pass that proved nothing.
	echo "SKIP: chmod cannot make a file read-only for root"
else
	: > "$TMP/log"
	hook "$TMP/ro/q"
	if grep -q 'WARN: could not write rps_cpus' "$TMP/log" && ! grep -q 'set to' "$TMP/log"; then
		ok "a refused write is logged as a warning, not as success"
	else
		bad "a refused write was reported as success (log: $(cat "$TMP/log"))"
	fi
fi

# A write can be accepted and then read back as something else.  /dev/null
# accepts everything and reads back empty, which is that case without needing a
# kernel that lies.
: > "$TMP/log"
hook /dev/null
if grep -q "WARN: rps_cpus write accepted but reads ''" "$TMP/log"; then
	ok "an accepted-but-changed write is logged with what it actually reads"
else
	bad "a silent write failure went unreported (log: $(cat "$TMP/log"))"
fi

# A queue that does not exist yet is not an error: the hook runs on link events.
: > "$TMP/log"
hook "$TMP/absent"
if [ ! -s "$TMP/log" ]; then
	ok "a missing queue is silent, not a warning"
else
	bad "a missing queue logged something: $(cat "$TMP/log")"
fi

# Any event other than add/register is ignored.
: > "$TMP/log"
: > "$TMP/q2"
hook "$TMP/q2" remove
if [ ! -s "$TMP/log" ]; then
	ok "a non-add event is ignored"
else
	bad "a 'remove' event still ran the hook"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
