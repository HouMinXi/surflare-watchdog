#!/bin/bash
# The receive-spread setting is written by a hotplug hook that fires when the
# interface appears, and the router was found with it back at 0 anyway.  This
# asserts the re-assert: it must put the value back, say so, and do nothing at
# all when the value is already right.
set -u
cd "$(dirname "$0")/.." || exit 1
SUT=${SUT:-scripts/surflare_rps_assert.sh}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
QUEUE="$TMP/rps_cpus"
mkdir -p "$TMP/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logged"\n' "$TMP" > "$TMP/bin/logger"
chmod +x "$TMP/bin/logger"

drive() { # extra args via env
	PATH="$TMP/bin:$PATH" QUEUE="$QUEUE" "$@" sh "$SUT" >/dev/null 2>&1
	echo $?
}

printf '0\n' > "$QUEUE"
rc=$(drive env)
if [ "$rc" -eq 0 ] && [ "$(cat "$QUEUE")" = e ]; then
	ok "a queue that lost its spread gets it back"
else
	bad "the spread was not restored (rc=$rc, value=$(cat "$QUEUE"))"
fi
if grep -q 're-asserted' "$TMP/logged" 2>/dev/null; then
	ok "the repair is logged, so a silent reset leaves a trace"
else
	bad "the repair was silent"
fi

: > "$TMP/logged"
rc=$(drive env)
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/logged" ]; then
	ok "a queue that is already right is left alone and not logged"
else
	bad "an already-correct queue was rewritten or logged"
fi

rm -f "$QUEUE"
rc=$(drive env)
if [ "$rc" -eq 0 ]; then
	ok "a missing queue is not an error"
else
	bad "a missing queue returned rc=$rc"
fi

printf '0\n' > "$QUEUE"
chmod 444 "$QUEUE"
if [ "$(id -u)" -eq 0 ]; then
	echo "SKIP: running as root, a read-only file is still writable"
else
	rc=$(drive env)
	if [ "$rc" -eq 1 ] && grep -q 'WARN' "$TMP/logged"; then
		ok "a write that fails is reported, not swallowed"
	else
		bad "a failed write returned rc=$rc"
	fi
fi
chmod 644 "$QUEUE"

# QUIET=1 is what the boot-time init passes.  With an empty prefix -- the way
# it was written first -- the guard `[ -n "$QUIET" ]` is false and every
# interface event writes a log line.
: > "$TMP/logged"
printf '0\n' > "$QUEUE"
rc=$(drive env QUIET=1)
if [ "$rc" -eq 0 ] && [ "$(cat "$QUEUE")" = e ] && [ ! -s "$TMP/logged" ]; then
	ok "QUIET=1 repairs without logging, which is what boot passes"
else
	bad "QUIET=1 did not stay quiet (rc=$rc, value=$(cat "$QUEUE"), log=$(cat "$TMP/logged" 2>/dev/null))"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
