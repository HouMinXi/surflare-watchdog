#!/bin/bash
# Tests for the dedicated-IP support in _sync_node_candidates.
# The python parser is EXTRACTED from the real watchdog script (not copied)
# so a passing test proves the production parser, not a drifted duplicate.
#
# shellcheck disable=SC2015  # ok()/bad() always return 0: A && ok || bad is exact if/else here

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Pull the python3 -c payload out of _sync_node_candidates verbatim: the
# block starts at "python3 -c '" and ends at the closing "' <<<" line.
# $1 = path to watchdog script (allows bug-inject runs against a mutated copy)
extract_python() {
	awk '/^_sync_node_candidates\(\)/,/^}/' "$1" |
		awk '/python3 -c '"'"'/{flag=1;next} /^'"'"' <</{flag=0} flag'
}

# Mirrors the NODE validation loop in _sync_node_candidates (kept in sync
# manually; the parser above is the piece that matters and is extracted).
validate_node() {
	local node="$1"; shift
	[ $# -ge 1 ] || return 1
	local c valid=0
	for c in "$@"; do
		[ "$c" = "$node" ] && { valid=1; break; }
	done
	[ "$valid" -eq 1 ] || node="$1"
	printf '%s' "$node"
}

# Code goes via -c so python's stdin stays free for the catalog fixture
# (piping the code to `python3 -` consumes stdin; sys.stdin then sees EOF).
run_parser() { PYTHONUTF8=1 python3 -c "$1"; }

# Catalog fixtures in the real `surflare nodes` TTY format.
catalog_full() {
	cat <<'EOF'
  Dedicated IPs
  🔒 United States(65.195.35.200)

  Recommended
  ★ Auto Best
  🇰🇷 Seoul (x2)
  🇯🇵 Tokyo (x5)
  🇺🇸 Los Angeles (x3)

  North America
  🇺🇸 Chicago
  🇺🇸 Miami (x2)
  🇺🇸 New York
EOF
}

catalog_no_dedicated() {
	cat <<'EOF'
  Recommended
  🇺🇸 Los Angeles (x3)
  🇺🇸 Chicago
EOF
}

catalog_dedicated_only() {
	printf '  \xf0\x9f\x94\x92 United States(65.195.35.200)  \n'
}

# ---------- tests against the REAL parser ----------
PY=$(extract_python "$WATCHDOG")
[ -n "$PY" ] && ok "parser extracted from real script" || { bad "extraction failed"; exit 1; }

echo "T1: happy path -- dedicated first, US cities follow, foreign excluded"
out=$(catalog_full | run_parser "$PY")
[ "$(printf '%s\n' "$out" | sed -n 1p)" = "United States(65.195.35.200)" ] \
	&& ok "dedicated IP is first candidate" || bad "first line: $(printf '%s' "$out" | sed -n 1p)"
printf '%s\n' "$out" | grep -qx "Los Angeles" && ok "US city captured" || bad "Los Angeles missing"
printf '%s\n' "$out" | grep -qx "Seoul" && bad "foreign city leaked in" || ok "foreign city excluded"
printf '%s\n' "$out" | grep -q "Auto Best" && bad "Auto Best leaked in" || ok "Auto Best excluded"

echo "T2: (xN) suffix stripped for cities, parens kept for dedicated"
printf '%s\n' "$out" | grep -qx "Miami" && ok "Miami (x2) -> Miami" || bad "Miami suffix not stripped"
printf '%s\n' "$out" | grep -qx "United States(65.195.35.200)" \
	&& ok "dedicated tag keeps (ip)" || bad "dedicated tag mangled"

echo "T3: subscription lapse -- no dedicated listing, cities only"
out3=$(catalog_no_dedicated | run_parser "$PY")
[ "$(printf '%s\n' "$out3" | wc -l)" -eq 2 ] && ok "2 cities synced" || bad "expected 2 lines, got: $out3"
mapfile -t cands3 <<< "$out3"
node3=$(validate_node "United States(65.195.35.200)" "${cands3[@]}") \
	&& [ "$node3" = "Los Angeles" ] && ok "NODE degrades to first city" \
	|| bad "NODE fell back to: $node3"

echo "T4: dedicated-only catalog still syncs (cities not required)"
out4=$(catalog_dedicated_only | run_parser "$PY")
[ -n "$out4" ] && ok "dedicated alone is non-empty" || bad "dedicated-only catalog yielded nothing"

echo "T5: duplicate dedicated lines dedup"
out5=$( { catalog_dedicated_only; catalog_dedicated_only; } | run_parser "$PY")
[ "$(printf '%s\n' "$out5" | grep -c "United States(65.195.35.200)")" -eq 1 ] \
	&& ok "duplicate dedicated printed once" || bad "dedicated duplicated"

echo "T6: NODE validation keeps dedicated when listed"
mapfile -t cands6 < <(catalog_full | run_parser "$PY")
node6=$(validate_node "United States(65.195.35.200)" "${cands6[@]}")
[ "$node6" = "United States(65.195.35.200)" ] && ok "NODE stays pinned" || bad "NODE became: $node6"

# ---------- bug-inject: the lock branch IS the fix under test ----------
# Swap the lock codepoint for a lookalike glyph: parser stays syntactically
# valid but the dedicated branch never matches (same inject style as the
# original flag-parser tests).
echo "T7: bug-inject -- parser without the lock branch must FAIL T1"
INJ=$(mktemp /tmp/node_sync_inj_XXXXXX)
trap 'rm -f "$INJ"' EXIT
sed 's/\\U0001F512/\\U0001F513/g' "$WATCHDOG" > "$INJ"
PY_INJ=$(extract_python "$INJ")
if [ -z "$PY_INJ" ]; then
	bad "bug-inject extraction failed"
elif catalog_full | run_parser "$PY_INJ" | grep -q "United States(65.195.35.200)"; then
	bad "injected bug NOT caught (dedicated still captured)"
else
	ok "injected bug caught: dedicated dropped from candidates"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
