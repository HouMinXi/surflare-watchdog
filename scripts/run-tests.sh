#!/bin/sh
# Run the test suite, and report what running it did to the tree.
#
# Two facts about this suite used to live only in someone's memory: it must not
# be run twice at once, and a test that writes into the repository turns the
# next `git status` into a lie. Neither is enforceable by remembering, so this
# refuses to start a second instance and re-checks the tree afterwards.
#
# Usage: run-tests.sh
# Exit: 0 every test passed, 1 a test failed or the tree changed, 2 could not start.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 2

LOCK="${TMPDIR:-/tmp}/surflare-suite.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
	echo "FATAL: another suite run holds $LOCK; wait for it or stop it" >&2
	exit 2
fi

RESULTS=$(mktemp) || exit 2
BEFORE_FILE=$(mktemp) || exit 2
LOGS=$(mktemp -d) || exit 2
trap 'rm -rf "$RESULTS" "$BEFORE_FILE" "$LOGS"' EXIT INT TERM

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
	echo "NOTE: the tree is already dirty; a change below is not attributable" >&2
fi
git status --porcelain 2>/dev/null | sort > "$BEFORE_FILE"

for t in tests/test_*.sh; do
	# Run each test with the interpreter its shebang names.  Forcing sh made
	# every bash test a syntax error under dash, and a syntax error looks
	# exactly like the skip convention handled below.
	case "$(head -1 "$t")" in
	*bash*) interp="bash" ;;
	*) interp="sh" ;;
	esac
	# Parse before running: "cannot parse" must never be reported as "skipped".
	if ! "$interp" -n "$t" 2> "$LOGS/$(basename "$t").log"; then
		printf '%s %s\n' "$(basename "$t")" "3" >> "$RESULTS"
		continue
	fi
	# 9>&- is not decoration: a test that leaves a background child (a curl
	# against a blackhole address, a sleep) hands it the lock descriptor, and
	# that child outlives the run and blocks every later one.
	timeout 240 "$interp" "$t" > "$LOGS/$(basename "$t").log" 2>&1 9>&-
	# Capture before any substitution: `printf ... "$(basename ...)" "$?"`
	# expands the command first, and under a non-POSIX shell that resets $?
	# to zero -- every test then records a pass.
	rc=$?
	printf '%s %s\n' "$(basename "$t")" "$rc" >> "$RESULTS"
done

hard=0
skip=0
while read -r name rc; do
	case "$rc" in
	0) ;;
	2) skip=$((skip + 1)); printf '%-46s SKIP\n' "$name" ;;
	3)
		hard=$((hard + 1))
		printf '%-46s PARSE-ERROR\n' "$name"
		[ -f "$LOGS/$name.log" ] && tail -n 6 "$LOGS/$name.log" | sed 's/^/    /'
		;;
	*)
		hard=$((hard + 1))
		printf '%-46s rc=%s\n' "$name" "$rc"
		# A failing test's output is the only thing that explains it later,
		# and the run this replaced threw it away.
		[ -f "$LOGS/$name.log" ] && tail -n 12 "$LOGS/$name.log" | sed 's/^/    /'
		;;
	esac
done < "$RESULTS"

after=$(git status --porcelain 2>/dev/null | sort)
before=$(cat "$BEFORE_FILE")
if [ "$before" != "$after" ]; then
	echo "FATAL: the suite changed the working tree:" >&2
	printf '%s\n' "$after" | grep -vxF -f "$BEFORE_FILE" >&2
	exit 1
fi

echo "RESULT: hard_fails=$hard skipped=$skip"
[ "$hard" -eq 0 ]