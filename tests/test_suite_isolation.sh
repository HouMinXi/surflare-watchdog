#!/bin/bash
# Two copies of the suite ran at once and agreed with each other and with a
# serial run. That is evidence for one night; this pins the property that made
# it true, so a new test cannot quietly reintroduce a shared path.
#
# The rule: a test may build files in a directory it creates itself. A literal
# path in /tmp is shared by every concurrent run by definition, and the loser
# reads as a flaky assertion -- ded-exit-inject did exactly that.
set -u
cd "$(dirname "$0")/.." || exit 1
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

# Paths under /tmp that are not scoped to this run: no $, no $$, no mktemp.
literal_tmp() {
	grep -nE "/tmp/[A-Za-z0-9][A-Za-z0-9_.-]*" "$1" 2>/dev/null |
		grep -v '\$' |
		grep -v '^[0-9]*:#'
}

offenders=""
for t in tests/*.sh; do
	[ "$(basename "$t")" = "$(basename "$0")" ] && continue
	hits=$(literal_tmp "$t")
	[ -z "$hits" ] && continue
	# Reading a well-known system path is not the same as building one there.
	hits=$(printf '%s\n' "$hits" | grep -vE '/tmp/(surflare-|dedex\.)?[a-z-]*\.(state|log)' || true)
	[ -z "$hits" ] && continue
	offenders="$offenders$t: $hits\n"
done

if [ -z "$offenders" ]; then
	ok "no test builds files at a fixed path under /tmp"
else
	bad "tests share /tmp paths, which makes concurrent runs lie"
	printf '%b' "$offenders" | head -8
fi

# A test that needs scratch space must get it from mktemp, not from a name it
# invented.
n_mktemp=0
n_needing=""
for t in tests/*.sh; do
	[ "$(basename "$t")" = "$(basename "$0")" ] && continue
	if grep -qE '/tmp/|[^a-z]TMP' "$t"; then
		if grep -qE 'mktemp|TMPDIR|\$\$' "$t"; then
			n_mktemp=$((n_mktemp + 1))
		else
			n_needing="$n_needing $(basename "$t")"
		fi
	fi
done
if [ -z "$n_needing" ]; then
	ok "every test that uses scratch space gets it from mktemp ($n_mktemp tests)"
else
	bad "these tests use scratch space without mktemp:$n_needing"
fi

# Every tests/*.sh that the suite does not run has to be declared. A manual
# harness that nothing names reads as coverage while protecting nothing.
undeclared=""
for t in tests/*.sh; do
	base=$(basename "$t")
	case "$base" in test_*) continue ;; esac
	[ "$base" = "$(basename "$0")" ] && continue
	grep -q "$base" tests/MANUAL.md 2>/dev/null || undeclared="$undeclared $base"
done
if [ -z "$undeclared" ]; then
	ok "every harness outside the suite is declared in tests/MANUAL.md"
else
	bad "undeclared harnesses:$undeclared"
fi

# The runner's reported status must survive the echo that follows it. Under a
# non-POSIX shell, `printf ... "$(basename ...)" "$?"` runs the substitution
# first and every test records a pass.
if grep -qE '^[[:space:]]*rc[[:space:]]*=[[:space:]]*\$\?' scripts/run-tests.sh; then
	ok "the runner captures each test's status before any substitution"
else
	bad "the runner reads \$? after a command substitution, which hides failures"
fi

# The runner is what makes 'must be run serially' a tool constraint instead of a
# memory: it refuses a second instance and reports a tree the suite dirtied.
RUNNER=scripts/run-tests.sh
if [ -x "$RUNNER" ] && sh -n < "$RUNNER"; then
	ok "the suite runner is present and parses"
else
	bad "no usable $RUNNER"
fi

if grep -q 'flock' "$RUNNER" 2>/dev/null; then
	ok "the runner takes a lock, so two runs cannot interleave by accident"
else
	bad "the runner has no lock"
fi

if grep -q 'git status --porcelain' "$RUNNER" 2>/dev/null; then
	ok "the runner notices when the suite leaves files in the tree"
else
	bad "the runner would not notice a test writing into the repository"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
