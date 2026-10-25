#!/bin/bash
# The suite runner holds a lock on fd 200 and starts every test as a child. A
# child inherits open descriptors, so a test that leaves a background curl or
# sleep behind hands it the lock, and that survivor keeps every later run out.
#
# This was not hypothetical: the first parallel run of the runner was refused by
# its own lock, held by a curl and a sleep that a test had spawned minutes
# earlier.
set -u
cd "$(dirname "$0")/.." || exit 1
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A child started the way the runner starts tests must not see descriptor 200.
exec 9>"$TMP/lock"
sleep 2 9>&- &
child=$!
sleep 0.3
if [ -e "/proc/$child/fd/9" ]; then
	bad "a child started with 9>&- still holds the lock descriptor"
else
	ok "a child started with 9>&- does not hold the lock descriptor"
fi
wait "$child" 2>/dev/null

# The control: without the redirection the descriptor really is inherited, so
# the assertion above is testing the redirection and not something else.
sleep 2 &
child2=$!
sleep 0.3
if [ -e "/proc/$child2/fd/9" ]; then
	ok "without the redirection the same child inherits it, so the check bites"
else
	bad "the control case did not inherit fd 200; this check proves nothing"
fi
wait "$child2" 2>/dev/null
exec 9>&-

# And the runner must actually use it where it starts tests.
if grep -qE '9>&-' scripts/run-tests.sh; then
	ok "the runner closes the lock descriptor on every test it starts"
else
	bad "the runner leaks its lock descriptor to every test"
fi

# After a run the lock has to be free again.
LOCK="$TMP/reuse.lock"
( exec 9>"$LOCK"; flock -n 9 ) || true
if flock -n "$LOCK" true; then
	ok "a released lock can be taken again"
else
	bad "the lock stayed held after release"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
