#!/bin/bash
# Tests for the dwell-storm gate (Zone C storm backoff).
# _in_dwell_storm, the dwell-history append block, and the main-loop gate
# are EXTRACTED from the real watchdog script so a pass proves the
# production logic, not a copy.

set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
HIST=$(mktemp /tmp/dwell_hist_XXXXXX)
RINGDIR=$(mktemp -d /tmp/dwell_ring_XXXXXX)
RING="$RINGDIR/ring"   # absent until T7's first append creates it
GATE_SCR=$(mktemp /tmp/dwell_gate_XXXXXX)
GATE_ENV=$(mktemp /tmp/dwell_gateenv_XXXXXX)
INJ_GATE=$(mktemp /tmp/dwell_gateinj_XXXXXX)
INJ=$(mktemp /tmp/dwell_inj_XXXXXX)
cleanup() { rm -f "$HIST" "$GATE_SCR" "$GATE_ENV" "$INJ_GATE" "$INJ" "/tmp/dwell_hist_absent_$$"; rm -r "$RINGDIR"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Extract from "/^_in_dwell_storm()/,/^}/" plus the constants it reads.
extract_fn() {
	awk '/^_in_dwell_storm\(\)/,/^}/' "$1"
}

# Extract the dwell-history append block from _record_connect: from the
# marker comment to the end of its enclosing if. Nesting counts only
# "if" lines ("elif" opens no new block, so it must not increment).
extract_append() {
	awk '
		/# Dwell history feeds/ { in_blk=1 }
		in_blk { print }
		in_blk && /^[[:space:]]*if[[:space:]].*then[[:space:]]*$/ { nest++ }
		in_blk && /^[[:space:]]*fi/ { nest--; if (nest == 0) exit }
	' "$1"
}

# Extract the main-loop gate block: from the age computation feeding
# the gate to its matching fi. Nesting counts every line starting with
# "if" (the gate's if may span lines, so requiring "then" on the same
# line would skip the count); "elif" starts with "el", not counted.
extract_gate() {
	awk '
		/_dwell_age=\$\(\(_now/ { in_blk=1 }
		in_blk { print }
		in_blk && /^[[:space:]]*if[[:space:]]/ { nest++ }
		in_blk && /^[[:space:]]*fi/ { nest--; if (nest == 0) exit }
	' "$1"
}

CONSTS=$(grep -E "^STORM_DWELL_MAX=|^STORM_DWELL_SESSIONS=|^DWELL_HISTORY=" "$WATCHDOG")

run_case() {
	# $1 = history file content (one dwell per line), $2 = expected (0/1)
	local hist="$1" want="$2" rc
	# truncate first so hist="" yields a zero-byte file, exercising
	# the real empty-file path (printf '%s\n' "" would write one
	# blank line instead).
	: > "$HIST"
	[ -n "$hist" ] && printf '%s\n' "$hist" > "$HIST"
	DWELL_HISTORY="$HIST" bash -c "
		$CONSTS
		DWELL_HISTORY=\"$HIST\"
		$(extract_fn "$WATCHDOG")
		_in_dwell_storm && exit 0 || exit 1
	" 2>/dev/null
	rc=$?
	if [ "$rc" -ne "$want" ]; then
		echo "    (got rc=$rc, want rc=$want, hist='$hist')" >&2
	fi
	[ "$rc" -eq "$want" ]
}

echo "T1: empty history -> no storm"
if run_case "" 1; then ok "empty -> false"; else bad "empty -> wrong"; fi

echo "T2: fewer than 3 sessions -> no storm"
if run_case "$(printf '120\n480')" 1; then ok "2 short -> false"; else bad "2 short -> wrong"; fi

echo "T3: 3 consecutive short sessions -> storm"
if run_case "$(printf '236\n483\n660')" 0; then ok "3 short -> true"; else bad "3 short -> wrong"; fi

echo "T4: one long session among the last 3 -> no storm"
if run_case "$(printf '3600\n236\n483')" 1; then ok "long+2short -> false"; else bad "long+2short -> wrong"; fi

echo "T5: exactly at threshold boundary (900s) is NOT storm"
if run_case "$(printf '900\n900\n900')" 1; then ok "900 x3 -> false"; else bad "900 x3 -> wrong"; fi

echo "T6: garbage line in history -> no storm (fail open, rotation continues)"
if run_case "$(printf 'abc\n120\n480')" 1; then ok "garbage -> false"; else bad "garbage -> wrong"; fi

echo "T7: production append block keeps only last N (extracted from _record_connect)"
if extract_append "$WATCHDOG" | grep -q "NODE_DEGRADED"; then
	bad "extraction overran past the append block (elif counted as if)"
else
	ok "extraction stops at the append block"
fi
for s in 100 200 300 3600; do
	_sess_prev_s="$s" DWELL_HISTORY="$RING" bash -c "
		$CONSTS
		DWELL_HISTORY=\"$RING\"
		log() { :; }
		$(extract_append "$WATCHDOG")
	" 2>/dev/null
done
if [ "$(wc -l < "$RING")" -eq 3 ] && [ "$(sed -n 1p "$RING")" = "200" ] \
	&& [ "$(sed -n 3p "$RING")" = "3600" ]; then
	ok "ring bounded at 3, oldest dropped"
else
	bad "ring wrong: $(tr '\n' ',' < "$RING")"
fi
_sess_prev_s=0 DWELL_HISTORY="$RING" bash -c "
	$CONSTS
	DWELL_HISTORY=\"$RING\"
	log() { :; }
	$(extract_append "$WATCHDOG")
" 2>/dev/null
if [ "$(wc -l < "$RING")" -eq 3 ]; then
	ok "zero prev session does not append"
else
	bad "zero prev appended: $(tr '\n' ',' < "$RING")"
fi

echo "T8: bug-inject -- inverted comparison must flip T3"
# shellcheck disable=SC2016  # \$ must stay literal: sed matches "$_d" in the source
sed 's/\[ "\$_d" -lt "\$STORM_DWELL_MAX" \]/[ "$_d" -ge "$STORM_DWELL_MAX" ]/' "$WATCHDOG" > "$INJ"
printf '236\n483\n660\n' > "$HIST"
DWELL_HISTORY="$HIST" bash -c "
	$CONSTS
	DWELL_HISTORY=\"$HIST\"
	$(extract_fn "$INJ")
	_in_dwell_storm && exit 0 || exit 1
" 2>/dev/null
rc=$?
# inverted: 3 short sessions all fail the >=900 check -> all_short=0 ->
# no storm. T3 (expect storm) must flip, so rc must be 1 here.
if [ "$rc" -eq 1 ]; then ok "injected bug detected (verdict flipped)"; else bad "injection not caught (rc=$rc)"; fi

echo "T9: missing history file -> no storm (fail open)"
# $$ expands in the outer test shell, so the path checked inside the
# child is the same one cleanup() removes.
bash -c "
	$CONSTS
	DWELL_HISTORY=/tmp/dwell_hist_absent_$$
	$(extract_fn "$WATCHDOG")
	_in_dwell_storm && exit 0 || exit 1
" 2>/dev/null
rc=$?
if [ "$rc" -eq 1 ]; then ok "missing -> false"; else bad "missing -> wrong (rc=$rc)"; fi

echo "T13: trailing blank line -> no storm (fail open, not corrupt-as-storm)"
# Command substitution strips trailing newlines, so a ring ending in a
# blank line would otherwise be judged on fewer values than its line
# count -- the gate must fail open instead.
printf '100\n200\n\n' > "$HIST"
DWELL_HISTORY="$HIST" bash -c "
	$CONSTS
	DWELL_HISTORY=\"$HIST\"
	$(extract_fn "$WATCHDOG")
	_in_dwell_storm && exit 0 || exit 1
" 2>/dev/null
rc=$?
if [ "$rc" -eq 1 ]; then ok "trailing blank -> false"; else bad "trailing blank -> wrong (rc=$rc)"; fi

echo "T10: gate suppresses rotation in storm, resumes after, announces once"
{
	echo "log() { LOG_CALLS=\$((LOG_CALLS+1)); }"
	echo "_handle_proactive_node_rotation() { ROTATED=1; }"
	extract_fn "$WATCHDOG"
	extract_gate "$WATCHDOG"
} > "$GATE_SCR"

OUT=$(bash -c "
	$CONSTS
	DWELL_HISTORY=\"$GATE_ENV\"
	printf '200\n300\n400\n' > \"$GATE_ENV\"
	LOG_CALLS=0
	_now=1000
	_sess_connect_s=200
	. \"$GATE_SCR\"
	. \"$GATE_SCR\"
	echo \"calls=\$LOG_CALLS rotated=\${ROTATED:-0}\"
" 2>/dev/null)
if [ "$OUT" = "calls=1 rotated=0" ]; then ok "storm: no rotation, one announcement"; else bad "storm wrong: $OUT"; fi

OUT=$(bash -c "
	$CONSTS
	DWELL_HISTORY=\"$GATE_ENV\"
	printf '3600\n' > \"$GATE_ENV\"
	LOG_CALLS=0
	_now=1000
	_sess_connect_s=200
	. \"$GATE_SCR\"
	. \"$GATE_SCR\"
	echo \"calls=\$LOG_CALLS rotated=\${ROTATED:-0}\"
" 2>/dev/null)
if [ "$OUT" = "calls=0 rotated=1" ]; then ok "clean: rotation runs, no announcement"; else bad "clean wrong: $OUT"; fi

OUT=$(bash -c "
	$CONSTS
	DWELL_HISTORY=\"$GATE_ENV\"
	printf '200\n300\n400\n' > \"$GATE_ENV\"
	LOG_CALLS=0
	_now=1000
	_sess_connect_s=200
	ROTATED=0
	. \"$GATE_SCR\"
	printf '3600\n' > \"$GATE_ENV\"
	ROTATED=0
	. \"$GATE_SCR\"
	printf '200\n300\n400\n' > \"$GATE_ENV\"
	ROTATED=0
	. \"$GATE_SCR\"
	echo \"calls=\$LOG_CALLS rotated=\${ROTATED:-0}\"
" 2>/dev/null)
if [ "$OUT" = "calls=2 rotated=0" ]; then ok "storm->clean->storm: re-announced, final storm re-suppresses"; else bad "recovery wrong: $OUT"; fi

echo "T12: storm history but current session outlived threshold -> rotation runs"
OUT=$(bash -c "
	$CONSTS
	DWELL_HISTORY=\"$GATE_ENV\"
	printf '200\n300\n400\n' > \"$GATE_ENV\"
	LOG_CALLS=0
	_now=2000
	_sess_connect_s=100
	. \"$GATE_SCR\"
	echo \"calls=\$LOG_CALLS rotated=\${ROTATED:-0}\"
" 2>/dev/null)
if [ "$OUT" = "calls=0 rotated=1" ]; then ok "old session clears storm: rotation runs, no announcement"; else bad "old session wrong: $OUT"; fi

echo "T14: negative session age (clock rollback) -> rotation runs, no suppression"
OUT=$(bash -c "
	$CONSTS
	DWELL_HISTORY=\"$GATE_ENV\"
	printf '200\n300\n400\n' > \"$GATE_ENV\"
	LOG_CALLS=0
	_now=1000
	_sess_connect_s=2000
	. \"$GATE_SCR\"
	echo \"calls=\$LOG_CALLS rotated=\${ROTATED:-0}\"
" 2>/dev/null)
if [ "$OUT" = "calls=0 rotated=1" ]; then ok "rollback age clears storm: rotation runs"; else bad "rollback wrong: $OUT"; fi

echo "T11: bug-inject -- deleting the gate must be caught (rotation runs in storm)"
sed 's/if _in_dwell_storm/if false/' "$GATE_SCR" > "$INJ_GATE"
OUT=$(bash -c "
	$CONSTS
	DWELL_HISTORY=\"$GATE_ENV\"
	printf '200\n300\n400\n' > \"$GATE_ENV\"
	_now=1000
	_sess_connect_s=200
	. \"$INJ_GATE\"
	echo \"rotated=\${ROTATED:-0}\"
" 2>/dev/null)
if [ "$OUT" = "rotated=1" ]; then ok "injected gate bypass detected (rotation ran during storm)"; else bad "injection not caught: $OUT"; fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
