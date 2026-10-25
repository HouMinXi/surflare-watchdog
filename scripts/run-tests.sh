#!/bin/sh
# Run the test suite, and report what running it did to the tree.
#
# Two facts about this suite used to live only in someone's memory: it must not
# be run twice at once, and a test that writes into the repository turns the
# next `git status` into a lie. Neither is enforceable by remembering, so this
# refuses to start a second instance and re-checks the tree afterwards.
#
# Usage: run-tests.sh [--jobs N] [-- list of test names]
# Exit: 0 every test passed, 1 a test failed, 2 could not start.
set -u

JOBS=1
while [ $# -gt 0 ]; do
	case "$1" in
	--jobs) JOBS="$2"; shift 2 ;;
	*) echo "usage: $0 [--jobs N]" >&2; exit 2 ;;
	esac
done
case "$JOBS" in
''|*[!0-9]*) echo "FATAL: --jobs needs a number" >&2; exit 2 ;;
esac

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 2

LOCK="${TMPDIR:-/tmp}/surflare-suite.lock"
exec 200>"$LOCK"
if ! flock -n 200; then
	echo "FATAL: another suite run holds $LOCK; wait for it or stop it" >&2
	exit 2
fi

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
	echo "NOTE: the tree is already dirty; a change below is not attributable" >&2
fi
before=$(git status --porcelain 2>/dev/null | sort)

run_one() {
	_t=$1
	# 200>&- is not decoration: a test that leaves a background child (a curl
	# against a blackhole address, a sleep) hands it the lock descriptor, and
	# that child outlives the run and blocks every later one.
	timeout 240 sh "$_t" >/dev/null 2>&1 200>&-
	printf '%s %s\n' "$(basename "$_t")" "$?"
}

if [ "$JOBS" -gt 1 ] && command -v xargs >/dev/null 2>&1; then
	ls tests/test_*.sh | xargs -P "$JOBS" -I{} sh -c "$(declare -f run_one); $(declare -p REPO 2>/dev/null || true); run_one {}" > /tmp/suite-results.$$ 2>/dev/null
else
	for t in tests/test_*.sh; do
		run_one "$t"
	done > /tmp/suite-results.$$
fi

hard=0
skip=0
for line in $(cat /tmp/suite-results.$$); do :; done 2>/dev/null
while read -r name rc; do
	case "$rc" in
	0) ;;
	2) skip=$((skip + 1)); printf '%-46s SKIP\n' "$name" ;;
	*) hard=$((hard + 1)); printf '%-46s rc=%s\n' "$name" "$rc" ;;
	esac
done < /tmp/suite-results.$$
rm -f /tmp/suite-results.$$

after=$(git status --porcelain 2>/dev/null | sort)
if [ "$before" != "$after" ]; then
	echo "FATAL: the suite changed the working tree:" >&2
	printf '%s\n' "$after" | grep -vxF "$(printf '%s\n' "$before")" >&2
	exit 1
fi

echo "RESULT: hard_fails=$hard skipped=$skip"
[ "$hard" -eq 0 ]