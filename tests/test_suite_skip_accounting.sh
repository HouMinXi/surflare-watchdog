#!/bin/bash
# Exit 2 means two different things, and the runner used to treat both as a
# skip. A test that cannot run here (no root, no user namespace) exits 2 and
# says SKIP. A test that cannot even make its scratch directory also exits 2,
# and that one ran nothing. Counting the second as skipped lets a broken
# environment report a clean suite.
set -u
cd "$(dirname "$0")/.." || exit 1
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# A miniature of the runner's accounting, pointed at fixtures instead of the
# real suite, so this does not depend on how many tests need root today.
cat > "$TMP/runner" <<'EOS'
#!/bin/sh
set -u
hard=0
skip=0
broken=0
for t in "$@"; do
	sh "$t" > "$t.out" 2>&1
	rc=$?
	name=$(basename "$t")
	case "$rc" in
	0) ;;
	2)
		if grep -q '^SKIP:' "$t.out"; then
			skip=$((skip + 1))
		else
			broken=$((broken + 1))
			printf '%-46s rc=%s (no SKIP line)\n' "$name" "$rc"
		fi
		;;
	*) hard=$((hard + 1)); printf '%-46s rc=%s\n' "$name" "$rc" ;;
	esac
done
echo "RESULT: hard_fails=$hard skipped=$skip broken=$broken"
[ "$hard" -eq 0 ] && [ "$broken" -eq 0 ]
EOS
chmod +x "$TMP/runner"

# And the real runner must do the same thing. The fixture above only proves
# the rule; this proves the suite applies it.
if grep -q "grep -q '\\^SKIP:'" scripts/run-tests.sh \
	&& grep -q 'broken=' scripts/run-tests.sh; then
	ok "the suite runner only skips a test that said SKIP"
else
	bad "the suite runner still counts every exit 2 as a skip"
fi

printf '#!/bin/sh\necho "SKIP: needs root"\nexit 2\n' > "$TMP/needs-root.sh"
printf '#!/bin/sh\necho "cannot make a directory"\nexit 2\n' > "$TMP/mktemp-died.sh"
printf '#!/bin/sh\necho ok\nexit 0\n' > "$TMP/fine.sh"
chmod +x "$TMP"/*.sh

sh "$TMP/runner" "$TMP/needs-root.sh" "$TMP/fine.sh" > "$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'skipped=1' "$TMP/out" && grep -q 'broken=0' "$TMP/out"; then
	ok "a test that says SKIP and exits 2 is a skip"
else
	bad "a declared skip was not counted as one: rc=$rc $(cat "$TMP/out")"
fi

sh "$TMP/runner" "$TMP/mktemp-died.sh" > "$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'broken=1' "$TMP/out" && ! grep -q 'skipped=1' "$TMP/out"; then
	ok "an exit 2 with no SKIP line is a failure, not a skip"
else
	bad "a silent exit 2 was counted as a skip: rc=$rc $(cat "$TMP/out")"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
