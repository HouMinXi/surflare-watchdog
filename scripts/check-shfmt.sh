#!/bin/sh
# Formatting gate: every tracked shell script is either clean under shfmt, or
# listed in scripts/shfmt-baseline.txt with the number of lines shfmt would
# rewrite. A file may not get worse, and a listed file may not stay listed once
# it is clean, so the baseline cannot quietly become a permanent exemption.
#
# shfmt is a formatter, not a linter. This gate exists so a new script cannot
# arrive in a second style and so an edit cannot un-format a file that was
# already formatted. Reformatting the whole tree is a separate change, because
# it rewrites every line those files have.
#
# Usage: check-shfmt.sh [--report]
#        --report   print the current counts without judging them
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd) || exit 2
BASELINE="$ROOT/scripts/shfmt-baseline.txt"
SHFMT=${SHFMT:-shfmt}
REPORT=0
[ "${1:-}" = "--report" ] && REPORT=1

if ! command -v "$SHFMT" >/dev/null 2>&1; then
	echo "FAIL: shfmt is not installed (set SHFMT or install it); this gate cannot judge formatting without it" >&2
	exit 1
fi

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# The interpreter named by the first line. `env` is not the interpreter: a
# `#!/usr/bin/env bash` script runs bash, and treating it as "env" would drop it
# from the gate silently.
interp_of() {
	_first=$(sed -n 1p "$1" 2>/dev/null) || return 1
	case "$_first" in
	'#!'*) ;;
	*) return 1 ;;
	esac
	set -- ${_first#\#!}
	[ "$#" -gt 0 ] || return 1
	case "${1##*/}" in
	env)
		shift
		# `env -S "bash -e"` and `env -i PATH=... bash` both name it later.
		while [ "$#" -gt 0 ]; do
			case "$1" in
			-*) shift ;;
			*=*) shift ;;
			*) break ;;
			esac
		done
		[ "$#" -gt 0 ] || return 1
		;;
	esac
	printf '%s\n' "${1##*/}"
}

cd "$ROOT" || exit 2
# -z: without it git quotes names that contain a tab, and the quoted name matches
# nothing on disk, so such a file would silently leave the gate.
if ! git ls-files -z >"$TMP/tracked.z" 2>"$TMP/git-err"; then
	echo "FAIL: git ls-files failed, so the file set is unknown: $(head -1 "$TMP/git-err")" >&2
	exit 1
fi
tr '\0' '\n' <"$TMP/tracked.z" >"$TMP/tracked"
if [ ! -s "$TMP/tracked" ]; then
	echo "FAIL: git ls-files listed no files; this is not a checkout the gate can judge" >&2
	exit 1
fi
# A conflicted index lists one path once per stage, so the same file would be
# counted three times and its first verdict would decide the others.
LC_ALL=C sort -u "$TMP/tracked" >"$TMP/files"
: >"$TMP/shell"
while IFS= read -r f; do
	[ -f "$f" ] || continue
	_i=$(interp_of "$f") || continue
	case "$_i" in
	sh | bash | dash | ash | ksh | mksh | openrc-run) printf '%s\n' "$f" >>"$TMP/shell" ;;
	esac
done <"$TMP/files"
if [ ! -s "$TMP/shell" ]; then
	echo "FAIL: no shell script found among $(wc -l <"$TMP/files") tracked files; the detection is broken" >&2
	exit 1
fi

# Lines shfmt would rewrite: the added lines of its diff, not the hunk count,
# because shfmt merges nearby changes and a hunk count drops when unrelated edits
# appear between them.

fail=0
total=0
checked=0
: >"$TMP/counted"
while IFS= read -r f; do
	checked=$((checked + 1))
	# shfmt reports a parse failure on stderr and an empty diff on stdout, so only
	# stderr can tell the two apart.
	_out=$("$SHFMT" -d "$f" 2>"$TMP/err")
	_err=$(head -1 "$TMP/err" 2>/dev/null)
	if [ -n "$_err" ]; then
		# In report mode the diagnostics go to stderr: stdout is turned into a
		# baseline by whoever calls --report, and a stray line becomes a record.
		if [ "$REPORT" -eq 1 ]; then
			echo "report: could not parse $f: $_err" >&2
			continue
		fi
		echo "FAIL: shfmt could not parse $f: $_err"
		fail=$((fail + 1))
		continue
	fi
	# The diff's two file headers start with the same characters as a changed
	# line, so they are dropped before counting.
	_minus=$(printf '%s\n' "$_out" | grep -vE '^(\+\+\+|---) ' | grep -c '^-' || true)
	_plus=$(printf '%s\n' "$_out" | grep -vE '^(\+\+\+|---) ' | grep -c '^+' || true)
	changed=$((_minus + _plus))
	case "$f" in
	*"$(printf '\t')"*)
		echo "FAIL: $f has a tab in its path, which the baseline cannot represent" >&2
		fail=$((fail + 1))
		continue
		;;
	esac
	total=$((total + changed))
	[ "$changed" -gt 0 ] && printf '%s\t%s\n' "$changed" "$f" >>"$TMP/counted"
done <"$TMP/shell"

TAB=$(printf '\t')
if [ "$REPORT" -eq 1 ]; then
	sort -t"$TAB" -k2 "$TMP/counted"
	printf 'report: %s shell files, %s changed lines outstanding\n' "$checked" "$total"
	exit 0
fi

# The baseline is data, so its shape is checked before it is believed: a record
# whose count is not a number, two records for one path, or a record for a file
# that is gone would silently decide what the gate allows. Fields are separated by
# a tab because a path may contain spaces.
if [ ! -f "$BASELINE" ]; then
	echo "FAIL: $BASELINE is missing; the gate has nothing to compare against"
	fail=$((fail + 1))
else
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '' | '#'*) continue ;; esac
		case "$line" in
		*"$TAB"*) ;;
		*)
			echo "FAIL: baseline record is not a tab-separated count and path: $line"
			fail=$((fail + 1))
			continue
			;;
		esac
		_n=${line%%"$TAB"*}
		_p=${line#*"$TAB"}
		case "$_n" in
		'' | *[!0-9]*)
			echo "FAIL: baseline record is not a number and a path: $line"
			fail=$((fail + 1))
			continue
			;;
		esac
		# A count far beyond any real file also aborts the comparisons below, and an
		# aborted test falls through every branch, so the length is bounded first.
		case "$_n" in
		?????????*)
			echo "FAIL: baseline record count is implausibly large: $line"
			fail=$((fail + 1))
			continue
			;;
		esac
		[ -z "$_p" ] && {
			echo "FAIL: baseline record has no path: $line"
			fail=$((fail + 1))
			continue
		}
		_seen=$(grep -cxF -- "$_p" "$TMP/baseline-paths" 2>/dev/null || true)
		case "${_seen:-}" in '' | *[!0-9]*) _seen=0 ;; esac
		printf '%s\n' "$_p" >>"$TMP/baseline-paths"
		[ "$_seen" -gt 0 ] && {
			echo "FAIL: the baseline lists $_p more than once; the first record would hide the rest"
			fail=$((fail + 1))
		}
		grep -qxF -- "$_p" "$TMP/shell" || {
			echo "FAIL: the baseline lists $_p, which is not a tracked shell script any more; regenerate the baseline"
			fail=$((fail + 1))
		}
	done <"$BASELINE"
fi

while IFS= read -r f; do
	_want=0
	if [ -f "$BASELINE" ]; then
		_want=$(PATHNAME="$f" awk -F"$TAB" 'BEGIN { p = ENVIRON["PATHNAME"] } $2 == p { print $1; exit }' "$BASELINE" 2>/dev/null)
		# A record that failed validation must not be compared: an unusable number
		# aborts the test below and falls through every branch.
		case "$_want" in '' | *[!0-9]*) _want=0 ;; ?????????*) _want=0 ;; esac
	fi
	_got=$(PATHNAME="$f" awk -F"$TAB" 'BEGIN { p = ENVIRON["PATHNAME"] } $2 == p { print $1; exit }' "$TMP/counted" 2>/dev/null)
	case "${_got:-}" in '' | *[!0-9]*) _got=0 ;; esac
	if [ "$_want" -eq 0 ] && [ "$_got" -gt 0 ]; then
		echo "FAIL: $f is a shell script that is not shfmt-clean ($_got changed lines) and is not in the baseline"
		fail=$((fail + 1))
	elif [ "$_got" -gt "$_want" ]; then
		echo "FAIL: $f needs $_got formatted lines, up from the $_want recorded in the baseline"
		fail=$((fail + 1))
	elif [ "$_got" -lt "$_want" ]; then
		echo "FAIL: $f now needs only $_got formatted lines but the baseline still says $_want; regenerate the baseline so the exemption shrinks"
		fail=$((fail + 1))
	fi
done <"$TMP/shell"

if [ "$fail" -ne 0 ]; then
	echo "FAIL: $fail formatting problem(s); run scripts/check-shfmt.sh --report for the current numbers" >&2
	exit 1
fi
printf 'OK: %s shell files clean or within the recorded baseline (%s changed lines outstanding)\n' "$checked" "$total"
exit 0
