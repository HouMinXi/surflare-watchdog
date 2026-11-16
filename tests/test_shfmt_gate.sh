#!/bin/sh
# The formatting gate is the only thing between this repository and a second,
# unreviewed style, so its rules are pinned here: a new script must be clean, a
# listed one must not get worse, a listed one that gets fixed must lose its
# exemption, and the baseline itself must be well formed before it is believed.
set -u

GATE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)/scripts/check-shfmt.sh
SHFMT=${SHFMT:-shfmt}
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
TAB=$(printf '\t')
ok() {
	printf 'PASS: %s\n' "$1"
	pass=$((pass + 1))
}
bad() {
	printf 'FAIL: %s\n' "$1"
	fail=$((fail + 1))
}

# A throwaway repository per case, because the gate reads `git ls-files`.
new_repo() {
	rm -rf "$TMP/repo"
	mkdir -p "$TMP/repo/scripts"
	cp "$GATE" "$TMP/repo/scripts/check-shfmt.sh"
	(cd "$TMP/repo" && git init -q .) || return 1
}
commit_repo() { (cd "$TMP/repo" && git add -A && git -c user.email=t@t -c user.name=t commit -qm x); }
clean_file() { printf '#!/bin/sh\nx=1\nprintf "%%s\\n" "$x"\n' >"$1"; }
# One place shfmt rewrites: an aligned trailing comment.
dirty_file() { printf '#!/bin/sh\nx=1     # aligned comment\nprintf "%%s\\n" "$x"\n' >"$1"; }
# Two separate places, far enough apart to stay two changes.
dirtier_file() {
	printf '#!/bin/sh\nx=1     # one\nprintf "%%s\\n" "$x"\necho 1\necho 2\necho 3\necho 4\necho 5\necho 6\necho 7\necho 8\necho 9\ncase "$x" in a|b) : ;; esac\n' >"$1"
}
# The gate's own report is the baseline, so no case hardcodes the metric.
baseline_all() { (cd "$TMP/repo" && sh scripts/check-shfmt.sh --report) | grep -v '^report:' >"$TMP/repo/scripts/shfmt-baseline.txt"; }
baseline_set() { printf '%s\t%s\n' "$1" "$2" >"$TMP/repo/scripts/shfmt-baseline.txt"; }
run_gate() { (cd "$TMP/repo" && sh scripts/check-shfmt.sh "$@") 2>&1; }
# Same run, stdout only: a case that cares which stream a diagnostic lands on cannot
# use run_gate, which merges them.
run_gate_stdout() { (cd "$TMP/repo" && sh scripts/check-shfmt.sh "$@") 2>/dev/null; }

new_repo
clean_file "$TMP/repo/scripts/clean.sh"
commit_repo
baseline_all
out=$(run_gate)
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '^OK:'; then
	ok "a clean new script passes"
else
	bad "a clean new script was rejected: $out"
fi

new_repo
commit_repo
baseline_all
dirty_file "$TMP/repo/scripts/dirty.sh"
commit_repo
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'dirty.sh is a shell script that is not shfmt-clean'; then
	ok "a new script in another style is refused"
else
	bad "a dirty new script passed: $out"
fi

new_repo
dirty_file "$TMP/repo/scripts/known.sh"
commit_repo
baseline_all
out=$(run_gate)
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '^OK:'; then
	ok "a listed file at its recorded count passes"
else
	bad "a listed file at its recorded count was rejected: $out"
fi

new_repo
dirtier_file "$TMP/repo/scripts/known.sh"
commit_repo
baseline_set 1 scripts/known.sh
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'up from the 1 recorded'; then
	ok "a listed file that got worse is refused"
else
	bad "a worse file passed: $out"
fi

new_repo
clean_file "$TMP/repo/scripts/fixed.sh"
commit_repo
baseline_set 3 scripts/fixed.sh
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'regenerate the baseline'; then
	ok "a listed file that is now clean must lose its exemption"
else
	bad "a stale exemption survived: $out"
fi

new_repo
printf '#!/bin/sh\ncase "$x" in\na) : ;;\n' >"$TMP/repo/scripts/broken.sh"
commit_repo
baseline_all
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'could not parse'; then
	ok "an unparseable script fails instead of counting as clean"
else
	bad "a parse error was not reported: $out"
fi

new_repo
clean_file "$TMP/repo/scripts/clean.sh"
commit_repo
baseline_all
out=$(cd "$TMP/repo" && SHFMT=/nonexistent/shfmt sh scripts/check-shfmt.sh 2>&1)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'shfmt is not installed'; then
	ok "a missing formatter fails the gate instead of skipping it"
else
	bad "a missing formatter was treated as success: $out"
fi

new_repo
clean_file "$TMP/repo/scripts/clean.sh"
dirty_file "$TMP/repo/scripts/dirty.sh"
commit_repo
baseline_all
out=$(run_gate --report)
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q 'dirty.sh$' && printf '%s' "$out" | grep -q '^report: 3 shell files,'; then
	ok "--report prints the counts and never judges them"
else
	bad "--report did not print the expected counts: $out"
fi

new_repo
commit_repo
baseline_all
dirty_file "$TMP/repo/scripts/envbash.sh"
sed -i '1s|.*|#!/usr/bin/env bash|' "$TMP/repo/scripts/envbash.sh"
commit_repo
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'envbash.sh is a shell script that is not shfmt-clean'; then
	ok "a script whose interpreter is named through env is still checked"
else
	bad "an /usr/bin/env bash script escaped the gate: $out"
fi

new_repo
clean_file "$TMP/repo/scripts/clean.sh"
commit_repo
baseline_all
out=$(cd "$TMP/repo" && rm -rf .git && sh scripts/check-shfmt.sh 2>&1)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'git ls-files failed'; then
	ok "a missing repository fails the gate instead of passing zero files"
else
	bad "the gate reported success without a repository: $out"
fi

new_repo
dirty_file "$TMP/repo/scripts/known.sh"
commit_repo
printf 'not-a-number\t%s\n' scripts/known.sh >"$TMP/repo/scripts/shfmt-baseline.txt"
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'baseline record is not a number'; then
	ok "a baseline record that is not a number is refused instead of read as zero"
else
	bad "a malformed baseline record was accepted: $out"
fi

new_repo
dirty_file "$TMP/repo/scripts/known.sh"
commit_repo
printf '1\t%s\n9\t%s\n' scripts/known.sh scripts/known.sh >"$TMP/repo/scripts/shfmt-baseline.txt"
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'lists scripts/known.sh more than once'; then
	ok "two baseline records for one path are refused"
else
	bad "a duplicated baseline record was accepted: $out"
fi

new_repo
clean_file "$TMP/repo/scripts/clean.sh"
commit_repo
baseline_set 4 scripts/gone.sh
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'not a tracked shell script any more'; then
	ok "a baseline record for a file that is gone must be pruned"
else
	bad "a stale baseline record survived: $out"
fi

new_repo
commit_repo
baseline_all
dirty_file "$TMP/repo/scripts/two words.sh"
commit_repo
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'two words.sh is a shell script that is not shfmt-clean'; then
	ok "a path with a space is judged once, under its whole name"
else
	bad "a path with a space was mishandled: $out"
fi

# The gate's number must be the number of lines shfmt would rewrite. The test
# counts them straight from shfmt, so changing the gate's metric to something
# coarser (hunks, files) reds this even though the gate is the one that reports it.
new_repo
dirty_file "$TMP/repo/scripts/measured.sh"
commit_repo
expected=$("$SHFMT" -d "$TMP/repo/scripts/measured.sh" | grep -c '^[+-][^+-]')
got=$( (cd "$TMP/repo" && sh scripts/check-shfmt.sh --report) | awk -F'\t' '$2 == "scripts/measured.sh" {print $1}')
if [ -n "$expected" ] && [ "$expected" = "$got" ]; then
	ok "the reported count is the number of lines shfmt rewrites"
else
	bad "the report said '$got' while shfmt rewrites $expected lines"
fi

new_repo
commit_repo
baseline_all
printf '#!/bin/sh\nx=1     # aligned\n' >"$TMP/repo/scripts/has${TAB}tab.sh"
commit_repo
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'has a tab in its path'; then
	ok "a path with a tab is refused instead of compared as zero"
else
	bad "a path with a tab was mishandled: $out"
fi

# The same file's lines must not reach the summary either: refusing the path and
# then counting its lines would let one unrepresentable path decide the total.
out=$(run_gate_stdout --report)
# The only file in this repository is the one with the tab, so a total above
# zero means its lines were counted before the path was refused.
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '0 changed lines outstanding'; then
	ok "a path with a tab contributes nothing to the recorded total"
else
	bad "a tab path leaked into the recorded total: $out"
fi

new_repo
commit_repo
baseline_all
dirty_file "$TMP/repo/scripts/svc"
sed -i '1s|.*|#!/sbin/openrc-run|' "$TMP/repo/scripts/svc"
commit_repo
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'svc is a shell script that is not shfmt-clean'; then
	ok "an openrc-run service script is checked like any other shell script"
else
	bad "an openrc-run script escaped the gate: $out"
fi

# The metric must hold on a file with several separate changes, not just one:
# a count of hunks multiplied by two equals the line count for a single rewrite
# and differs for three, so this fixture is what separates the two definitions.
new_repo
printf '#!/bin/sh\nx=1     # one\nprintf "%%s\\n" "$x"\necho a\necho b\necho c\necho d\necho e\necho f\ny=2     # two\ncase "$y" in a|b) : ;; esac\n' >"$TMP/repo/scripts/several.sh"
commit_repo
expected=$("$SHFMT" -d "$TMP/repo/scripts/several.sh" | grep -c '^[+-][^+-]')
got=$( (cd "$TMP/repo" && sh scripts/check-shfmt.sh --report) | awk -F'\t' '$2 == "scripts/several.sh" {print $1}')
if [ -n "$expected" ] && [ "$expected" = "$got" ] && [ "$expected" -gt 4 ]; then
	ok "the metric still counts lines on a file with several changes"
else
	bad "several-change fixture: report said '$got', shfmt rewrites $expected lines"
fi

new_repo
commit_repo
baseline_all
printf '#!/bin/sh\nx=1     # aligned\n' >"$TMP/repo/scripts/back\\slash.sh"
commit_repo
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'back.slash.sh is a shell script that is not shfmt-clean'; then
	ok "a path containing a backslash is judged, not interpreted as an escape"
else
	bad "a path containing a backslash was skipped: $out"
fi

new_repo
dirty_file "$TMP/repo/scripts/known.sh"
commit_repo
printf '123456789012345678901234\t%s\n' scripts/known.sh >"$TMP/repo/scripts/shfmt-baseline.txt"
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -q 'implausibly large'; then
	ok "a count too large to compare is refused instead of skipping every branch"
else
	bad "an oversized count fell through: $out"
fi

# A baseline whose last record has no newline must still be validated: `read`
# returns false at end of input and drops the partial line otherwise.
new_repo
dirty_file "$TMP/repo/scripts/known.sh"
commit_repo
printf '999999999999999999999999\t%s' scripts/known.sh >"$TMP/repo/scripts/shfmt-baseline.txt"
out=$(run_gate)
if [ $? -ne 0 ] && printf '%s' "$out" | grep -qE 'implausibly large|not a number'; then
	ok "an unterminated final baseline record is validated, not dropped"
else
	bad "an unterminated final record was ignored: $out"
fi

# The counted-line lookup and the baseline lookup are two sites: a record whose
# path needs the same care pins the second one, because a zero count there reads
# as a stale exemption.
new_repo
commit_repo
baseline_all
printf '#!/bin/sh\nx=1     # aligned\n' >"$TMP/repo/scripts/back\\slash.sh"
commit_repo
# Read the count from the gate's own verdict, not from --report: --report is a
# third lookup, so a gate broken in both comparisons would still show a number
# here and the case would pass.
count=$( (cd "$TMP/repo" && sh scripts/check-shfmt.sh) 2>&1 | sed -n 's/.*(\([0-9][0-9]*\) changed lines.*/\1/p')
if [ -z "$count" ]; then
	bad "the gate reported no count for the backslash path, so the case proves nothing"
fi
printf '%s\t%s\n' "$count" "scripts/back\\slash.sh" >"$TMP/repo/scripts/shfmt-baseline.txt"
out=$(run_gate)
rc=$?
if [ -n "$count" ] && [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^OK:'; then
	ok "a recorded count is compared for a path containing a backslash"
else
	[ -n "$count" ] && bad "the counted lookup lost a path containing a backslash: $out"
fi

# Three hunks, one of which carries two changes: the number of changed lines and
# twice the number of hunks then differ, which is the only geometry in which a
# metric that counts hunks can be told apart from one that counts lines.
new_repo
{
	printf '#!/bin/sh\nx=1     # one\n'
	for n in a b c d e f g h i j; do printf 'echo %s\n' "$n"; done
	printf 'y=2     # two\nw=4     # four\n'
	for n in k l m n o p q r s t; do printf 'echo %s\n' "$n"; done
	printf 'z=3     # three\n'
	for n in u v w x y; do printf 'echo %s\n' "$n"; done
} >"$TMP/repo/scripts/three.sh"
commit_repo
expected=$("$SHFMT" -d "$TMP/repo/scripts/three.sh" | grep -c '^[+-][^+-]')
got=$( (cd "$TMP/repo" && sh scripts/check-shfmt.sh --report) | awk -F'\t' '$2 == "scripts/three.sh" {print $1}')
hunks=$("$SHFMT" -d "$TMP/repo/scripts/three.sh" | grep -c '^@@')
if [ "$expected" = "$got" ] && [ "$hunks" -ge 2 ] && [ "$expected" -ne "$((hunks * 2))" ]; then
	ok "the metric is lines, not twice the hunk count, on three separate changes"
else
	bad "three-change fixture: report said '$got', shfmt rewrites $expected lines in $hunks hunks"
fi

# --report's stdout is turned into a baseline by its caller, so a diagnostic must
# never appear there: a stray line would become a baseline record.
new_repo
printf '#!/bin/sh\ncase "$x" in\na) : ;;\n' >"$TMP/repo/scripts/broken.sh"
commit_repo
out=$(run_gate_stdout --report)
if [ $? -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
	ok "--report keeps diagnostics out of the stream its caller records"
else
	bad "--report wrote a diagnostic into the record stream: $out"
fi

# A path the baseline cannot represent is a diagnostic, not a record: --report's
# stdout is what its caller banks, so nothing but records may appear there.
new_repo
printf '#!/bin/sh\nx=1     # aligned\n' >"$TMP/repo/scripts/has$(printf '\t')tab.sh"
commit_repo
out=$(run_gate_stdout --report)
if ! printf '%s' "$out" | grep -q 'tab in its path'; then
	ok "--report keeps an unrepresentable path out of the record stream"
else
	bad "--report wrote a tab-path diagnostic into the record stream: $out"
fi

printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
# The count is pinned: a case deleted in a later edit leaves fail at zero, so
# the total is what notices it, and it says so by name.
[ "$fail" -eq 0 ] || exit 1
if [ "$pass" -ne 26 ]; then
	printf 'FAIL: expected 26 cases, ran %s\n' "$pass"
	exit 1
fi
