#!/bin/bash
# Node pre-probe: surflare nodes --speed rating gates node rotation.
# A reconnect tears down the live tunnel (14-30s per attempt); connecting
# to a dead node costs a full teardown + connect cycle. The speed rating
# is a live probe of each node relay -- filter NODE_CANDIDATES through
# it before rotating.
#
# shellcheck disable=SC2015
# shellcheck disable=SC2016
set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# S1: _speed_rate function exists and parses the CLI table
grep -q '_speed_probe_nodes' "$WATCHDOG" || { echo "FATAL: _speed_probe_nodes missing"; exit 1; }
grep -q 'SPEED_PROBE_TIMEOUT' "$WATCHDOG" || { echo "FATAL: SPEED_PROBE_TIMEOUT constant missing"; exit 1; }

# extract the function body to test the rating parser standalone
extract_fn() {
	awk -v fn="$1" '
		$0 ~ "^" fn "\\(\\) \\{" { in_fn=1 }
		in_fn { print }
		in_fn && /^}$/ { exit }
	' "$WATCHDOG"
}

# run_probe RAW_TABLE OUTVAR: simulate the parser on a fixture table
run_probe() {
	local table="$1" outvar="$2"
	local fnbody
	fnbody=$(extract_fn _parse_speed_ratings)
	bash -c "
		$fnbody
		_parse_speed_ratings <<'TBL'
$table
TBL
	" > /tmp/speed_parse_$$.out 2>/dev/null
	# parser writes NODE_SPEED_RATINGS="City=Rating;City=Rating"
	eval "$(cat /tmp/speed_parse_$$.out)"
	eval "$outvar=\"\$NODE_SPEED_RATINGS\""
	rm -f /tmp/speed_parse_$$.out
}

echo "S1: parser extracts city=rating pairs from speed table"
RATINGS=""
run_probe "  🇺🇸 Dallas  Excellent
  🇺🇸 Chicago  Good
  🇺🇸 Miami  Fair
  🇺🇸 New York
  🇺🇸 Atlanta  Poor" RATINGS
echo "$RATINGS" | grep -q "Dallas=Excellent" && ok "S1 Dallas=Excellent" || bad "S1 Dallas missing in '$RATINGS'"
echo "$RATINGS" | grep -q "Chicago=Good" && ok "S1 Chicago=Good" || bad "S1 Chicago missing"
echo "$RATINGS" | grep -q "Miami=Fair" && ok "S1 Miami=Fair" || bad "S1 Miami missing"
echo "$RATINGS" | grep -q "New York=unrated" && ok "S1 unrated city marked" || bad "S1 New York unrated missing"
echo "$RATINGS" | grep -q "Atlanta=Poor" && ok "S1 Atlanta=Poor" || bad "S1 Atlanta missing"

echo "S2: rotate skips Poor/unrated, picks first Excellent/Good in candidate order"
# fixture: candidates Dallas Chicago Miami NY; only Miami=Fair Chicago=Good rated
RATINGS2=""
run_probe "  🇺🇸 Dallas  Poor
  🇺🇸 Chicago  Good" RATINGS2
FN_ROTATE=$(extract_fn _rotate_node)
OUT=$(bash -c "
	NODE_CANDIDATES=(Dallas Chicago Miami 'New York')
	SPEED_PROBE_ENABLED=1
	NODE_SPEED_RATINGS='$RATINGS2'
	ROTATION_STATE=/tmp/rot_state_\$\$
	ROTATION_STATE_DIR=/tmp
	_node_idx=0
	_active_node=Dallas
	_refresh_effective_transit() { _effective_transit=''; }
	_node_is_log_healthy() { return 0; }
	_speed_probe_nodes() { return 0; }
	log() { echo \"\$@\"; }
	_stats_rotations=0
$FN_ROTATE
	_rotate_node
	echo \"RESULT_NODE=\$_active_node\"
" 2>/dev/null)
echo "$OUT" | grep -q "RESULT_NODE=Chicago" && ok "S2 rotated to Chicago (Good), skipped Dallas (Poor)" || bad "S2 got: $OUT"
rm -f /tmp/rot_state_$$

echo "S3: all candidates Poor -> fall back to current behavior (no forced skip of everyone)"
RATINGS3=""
run_probe "  🇺🇸 Dallas  Poor
  🇺🇸 Chicago  Poor" RATINGS3
OUT3=$(bash -c "
	NODE_CANDIDATES=(Dallas Chicago)
	SPEED_PROBE_ENABLED=1
	NODE_SPEED_RATINGS='$RATINGS3'
	ROTATION_STATE=/tmp/rot_state3_\$\$
	ROTATION_STATE_DIR=/tmp
	_node_idx=0
	_active_node=Dallas
	_refresh_effective_transit() { _effective_transit=''; }
	_node_is_log_healthy() { return 0; }
	_speed_probe_nodes() { return 0; }
	log() { echo \"\$@\"; }
	_stats_rotations=0
$(extract_fn _rotate_node)
	_rotate_node
	echo \"RESULT_NODE=\$_active_node\"
" 2>/dev/null)
# all-poor: no rated candidate exists -> legacy order picks Chicago
echo "$OUT3" | grep -q "RESULT_NODE=Chicago" && ok "S3 all-poor falls back to sequential" || bad "S3 got: $OUT3"
rm -f /tmp/rot_state3_$$

echo "S4: probe failure (CLI hang/exit nonzero) -> ratings empty -> legacy behavior"
OUT4=$(bash -c "
	NODE_CANDIDATES=(Dallas Chicago)
	SPEED_PROBE_ENABLED=1
	NODE_SPEED_RATINGS=''
	ROTATION_STATE=/tmp/rot_state4_\$\$
	ROTATION_STATE_DIR=/tmp
	_node_idx=0
	_active_node=Dallas
	_refresh_effective_transit() { _effective_transit=''; }
	_node_is_log_healthy() { return 0; }
	_speed_probe_nodes() { return 1; }
	log() { echo \"\$@\"; }
	_stats_rotations=0
$(extract_fn _rotate_node)
	_rotate_node
	echo \"RESULT_NODE=\$_active_node\"
" 2>/dev/null)
echo "$OUT4" | grep -q "RESULT_NODE=Chicago" && ok "S4 empty ratings -> legacy sequential" || bad "S4 got: $OUT4"
rm -f /tmp/rot_state4_$$

echo "S5: injection - remove the rating filter -> S2 must fail"
INJ=$(mktemp /tmp/np_inj_XXXXXX)
# Neutralize the rating filter by locating the condition line by its
# unique signature and rewriting it, avoiding quote-laden literals.
awk '
	/_speed_rating:-unrated/ && /Excellent/ && /Good/ && !done {
		sub(/if \[.*$/, "if false; then")
		done=1
	}
	{ print }
' "$WATCHDOG" > "$INJ"
grep -q 'if false; then' "$INJ" || { bad "S5 injection failed to apply"; rm -f "$INJ"; echo; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
OUT5=$(bash -c "
	NODE_CANDIDATES=(Miami Dallas Chicago)
	SPEED_PROBE_ENABLED=1
	NODE_SPEED_RATINGS='Dallas=Poor;Chicago=Good'
	ROTATION_STATE=/tmp/rot_state5_\$\$
	ROTATION_STATE_DIR=/tmp
	_node_idx=0
	_active_node=Miami
	_refresh_effective_transit() { _effective_transit=''; }
	_node_is_log_healthy() { return 0; }
	_speed_probe_nodes() { return 0; }
	log() { echo \"\$@\"; }
	_stats_rotations=0
$(awk -v fn="_rotate_node" '
	$0 ~ "^" fn "\\(\\) \\{" { in_fn=1 }
	in_fn { print }
	in_fn && /^}$/ { exit }
' "$INJ")
	_rotate_node
	echo \"RESULT_NODE=\$_active_node\"
" 2>/dev/null)
[ "$OUT5" != "${OUT5/RESULT_NODE=Dallas/}" ] && ok "S5 inject: Poor node selected when filter removed (test catches it)" || bad "S5 injection did not change selection: $OUT5"
rm -f "$INJ" /tmp/rot_state5_$$

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
