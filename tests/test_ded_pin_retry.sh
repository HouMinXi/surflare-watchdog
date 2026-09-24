#!/bin/bash
# Tests for the deferred dedicated-pin retry and the catalog-name
# resolution used at connect time.  Both functions are EXTRACTED from the
# real watchdog script, so a pass proves the production logic, not a copy.
#
# shellcheck disable=SC2015  # ok()/bad() always return 0: A && ok || bad is exact if/else here
# shellcheck disable=SC2016  # single quotes around harness bodies are intentional

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# RFC 5737 TEST-NET-2, built at runtime so no IPv4 literal sits in the file.
DEDICATED="United States($(printf '%d.%d.%d.%d' 198 51 100 7))"
DED_EXACT="${DEDICATED}AT&T"

extract_fn() {
	awk -v fn="$2" '
		$0 ~ "^" fn "\\(\\)" { f=1 }
		f { print }
		f && /^}/ { exit }
	' "$1"
}

# run_resolve: seeds MAP (base<TAB>exact lines) and NODES (catalog text).
# Prints the resolved name.
run_resolve() {
	local wd="${1:-$WATCHDOG}" fn
	fn=$(extract_fn "$wd" _resolve_node_catalog_name)
	if [ -z "$fn" ]; then echo "EXTRACT_FAIL"; return 99; fi
	local mapfile
	mapfile=$(mktemp /tmp/dp_map_XXXXXX)
	if [ -n "${MAP:-}" ]; then
		printf '%s\n' "$MAP" > "$mapfile"
	else
		rm -f "$mapfile"
	fi
	local stub
	stub=$(mktemp -d /tmp/dp_stub_XXXXXX)
	cat > "$stub/surflare" << 'STUB'
#!/bin/bash
if [ "$1" = "nodes" ]; then printf '%s\n' "$NODES_OUT"; exit 0; fi
exit 0
STUB
	chmod +x "$stub/surflare"
	WANT="${WANT:-}" MAPFILE="$mapfile" STUB="$stub" NODES_OUT="${NODES:-}" \
	bash -c "
		set -u
		export PATH=\"\$STUB:\$PATH\"
		DED_NAME_MAP=\"\$MAPFILE\"
		$fn
		_resolve_node_catalog_name \"\$WANT\"
	" 2>/dev/null
	rm -rf "$mapfile" "$stub"
}

# run_retry: seeds PENDING, DEADLINE, FAILCOUNT, CANDS, NODE.
# Prints "pending|active|idx|connects|file".
run_retry() {
	local wd="${1:-$WATCHDOG}" fn idx
	fn=$(extract_fn "$wd" _maybe_retry_ded_pin)
	idx=$(extract_fn "$wd" _node_candidate_index)
	if [ -z "$fn" ] || [ -z "$idx" ]; then echo "EXTRACT_FAIL"; return 99; fi
	local rfile
	rfile=$(mktemp /tmp/dp_rot_XXXXXX)
	printf '%s\n' "${ROT_FILE_CONTENT:-}" > "$rfile"
	PENDING="${PENDING:-0}" DEADLINE="${DEADLINE:-0}" FAILCOUNT="${FAILCOUNT:-0}" \
	CANDS="${CANDS:-}" NODE="${NODE:-}" RFILE="$rfile" \
	bash -c "
		set -u
		log() { LOG_BUF=\"\$LOG_BUF|\$1\"; }
		_ded_pin_pending=\"\$PENDING\"
		_ded_pin_deadline=\"\$DEADLINE\"
		fail_count=\"\$FAILCOUNT\"
		NODE=\"\$NODE\"
		ROTATION_STATE=\"\$RFILE\"
		IFS='|' read -r -a NODE_CANDIDATES <<< \"\$CANDS\"
		_active_node=\"\${ACTIVE:-Chicago}\"
		_node_idx=0
		_prev_active_node=\"\${PREV_ACTIVE:-}\"
		CONNECTS=0
		connect_vpn() { CONNECTS=\$((CONNECTS+1)); }
		# The sync already happened: the candidate array IS the result.
		_sync_node_candidates() { return 0; }
		LOG_BUF=
		$idx
		$fn
		_maybe_retry_ded_pin
		_f=; [ -f \"\$ROTATION_STATE\" ] && _f=\$(cat \"\$ROTATION_STATE\")
		echo \"\$_ded_pin_pending|\$_active_node|\$_node_idx|\$CONNECTS|\$_f\"
	" 2>/dev/null
	rm -f "$rfile"
}

echo "R1: city label passes through unchanged"
OUT=$(WANT="Chicago" run_resolve)
[ "$OUT" = "Chicago" ] && ok "city unchanged" || bad "R1: $OUT"

echo "R2: map hit resolves base name to the exact catalog row"
OUT=$(WANT="$DEDICATED" MAP="$(printf '%s\t%s' "$DEDICATED" "$DED_EXACT")" run_resolve)
[ "$OUT" = "$DED_EXACT" ] && ok "map hit -> exact row" || bad "R2: $OUT"

echo "R3: no map, catalog read resolves by IP"
OUT=$(WANT="$DEDICATED" NODES="  $(printf '\xf0\x9f\x94\x92') $DED_EXACT" run_resolve)
[ "$OUT" = "$DED_EXACT" ] && ok "catalog read -> exact row" || bad "R3: $OUT"

echo "R4: unresolvable dedicated label passes through (never blocks rotation)"
OUT=$(WANT="$DEDICATED" NODES="  $(printf '\xf0\x9f\x94\x92') United States($(printf '%d.%d.%d.%d' 203 0 113 9))" run_resolve)
[ "$OUT" = "$DEDICATED" ] && ok "unresolvable -> base passthrough" || bad "R4: $OUT"

echo "R5: pending pin, catalog lists it -> asserted exactly once and persisted"
FUTURE=$(( $(date +%s) + 600 ))
OUT=$(PENDING=1 DEADLINE="$FUTURE" NODE="$DEDICATED" \
	CANDS="$DEDICATED|Chicago|Miami" \
	ROT_FILE_CONTENT="$(printf 'Chicago\t1')" run_retry)
[ "$OUT" = "0|$DEDICATED|0|1|$DEDICATED	0" ] && ok "pin asserted once, file updated" || bad "R5: $OUT"

echo "R6: window expired -> pin dropped, no connect"
PAST=$(( $(date +%s) - 10 ))
OUT=$(PENDING=1 DEADLINE="$PAST" NODE="$DEDICATED" \
	CANDS="$DEDICATED|Chicago" run_retry)
[ "$OUT" = "0|Chicago|0|0|" ] && ok "expired window -> no dial" || bad "R6: $OUT"

echo "R7: not pending -> no-op"
OUT=$(PENDING=0 DEADLINE="$FUTURE" NODE="$DEDICATED" \
	CANDS="$DEDICATED|Chicago" run_retry)
[ "$OUT" = "0|Chicago|0|0|" ] && ok "not pending -> untouched" || bad "R7: $OUT"

echo "R8: failure in progress -> retry deferred, pin stays pending"
OUT=$(PENDING=1 DEADLINE="$FUTURE" FAILCOUNT=2 NODE="$DEDICATED" \
	CANDS="$DEDICATED|Chicago" run_retry)
[ "$OUT" = "1|Chicago|0|0|" ] && ok "active failure -> pin held" || bad "R8: $OUT"

echo "R9: catalog synced but pin retired -> pin dropped, no dial"
OUT=$(PENDING=1 DEADLINE="$FUTURE" NODE="$DEDICATED" \
	CANDS="Chicago|Miami" run_retry)
[ "$OUT" = "0|Chicago|0|0|" ] && ok "retired pin dropped" || bad "R9: $OUT"

echo "R10: bug-inject -- dropping the connect call must fail R5"
INJ=$(mktemp /tmp/dp_inj_XXXXXX)
python3 - "$WATCHDOG" "$INJ" << 'PYEOF'
import sys
from pathlib import Path
src, dst = sys.argv[1], sys.argv[2]
s = Path(src).read_text()
start = s.find("_maybe_retry_ded_pin() {")
assert start >= 0, "fn missing"
end = s.find("\n}", start)
body = s[start:end]
assert body.count("\t\t\tconnect_vpn") == 1, "connect call missing"
new_body = body.replace("\t\t\tconnect_vpn", "\t\t\t: pin asserted", 1)
Path(dst).write_text(s[:start] + new_body + s[end:])
PYEOF
OUT=$(PENDING=1 DEADLINE="$FUTURE" NODE="$DEDICATED" \
	CANDS="$DEDICATED|Chicago" run_retry "$INJ")
got="${OUT#0|}"
got="${got%%|*}"
conn_field=$(printf '%s' "$OUT" | awk -F"|" '{print $4}')
if [ "$got" = "$DEDICATED" ] && [ "$conn_field" = "0" ]; then
	ok "connect deleted -> R5 would not dial (caught)"
else
	bad "R10 NOT caught: $OUT"
fi
rm -f "$INJ"

# run_sync: runs the REAL _sync_node_candidates against a stubbed CLI.
# Prints "rc|candidates|map-lines|node-valid", then the map file contents
# (prefixed with "> ") so S4 can assert on exact base names per row.
run_sync() {
	local wd="${1:-$WATCHDOG}" fn
	fn=$(extract_fn "$wd" _sync_node_candidates)
	if [ -z "$fn" ]; then echo "EXTRACT_FAIL"; return 99; fi
	local stub mapf child
	stub=$(mktemp -d /tmp/dp_sync_XXXXXX)
	mapf=$(mktemp /tmp/dp_map_XXXXXX)
	child=$(mktemp /tmp/dp_child_XXXXXX)
	cat > "$stub/surflare" << 'STUB'
#!/bin/bash
if [ "$1" = "nodes" ]; then printf '%s\n' "$NODES_OUT"; exit "${NODES_RC:-0}"; fi
exit 0
STUB
	chmod +x "$stub/surflare"
	cat > "$child" << 'CHILD'
#!/bin/bash
set -u
export PATH="$STUB:$PATH"
log() { :; }
NODE="$NODE_SEED"
DED_NAME_MAP="$MAPF"
NODE_CANDIDATES=(Chicago Miami)
ROTATION_STATE="/tmp/dp_none_$$"
eval "$FN"
_sync_node_candidates
rc=$?
printf '%s|%s|%s|%s\n' "$rc" "${NODE_CANDIDATES[*]}" "$( [ -f "$DED_NAME_MAP" ] && wc -l < "$DED_NAME_MAP" || echo 0 )" "$NODE"
if [ -f "$DED_NAME_MAP" ]; then
	sed 's/^/> /' "$DED_NAME_MAP"
fi
CHILD
	chmod +x "$child"
	NODE_SEED="${NODE_SEED:-Chicago}" NODES_OUT="${NODES_OUT:-}" NODES_RC="${NODES_RC:-0}" \
	STUB="$stub" MAPF="$mapf" FN="$fn" bash "$child" 2>/dev/null
	rm -rf "$stub" "$mapf" "$child"
}

echo "R12: pin already active, no prior rotation (prev seeded from active) -> no reconnect"
OUT=$(PENDING=1 DEADLINE="$FUTURE" NODE="$DEDICATED" \
		CANDS="$DEDICATED|Chicago" PREV_ACTIVE="" ACTIVE="$DEDICATED" run_retry)
if [ "$OUT" = "0|$DEDICATED|0|0|" ]; then
	ok "prev seeded from active -> no reconnect"
else
	bad "R12: $OUT"
fi

echo "S1: catalog unreachable -> rc=1, candidates untouched, map untouched"
OUT=$(NODES_RC=124 NODE_SEED="Chicago" run_sync)
[ "$OUT" = "1|Chicago Miami|0|Chicago" ] && ok "failed sync keeps prior candidates" || bad "S1: $OUT"

echo "S2: multi-country dedicated rows map correctly (Washington not rebuilt as United States)"
NODES_OUT="  $(printf '\xf0\x9f\x94\x92') United States(198.51.100.7)AT&T
  $(printf '\xf0\x9f\x94\x92') Washington(203.0.113.8)
  $(printf '\xf0\x9f\x87\xba\xf0\x9f\x87\xb8') Chicago (x3)"
OUT=$(NODE_SEED="United States(198.51.100.7)" run_sync)
rc_line2=$(printf '%s' "$OUT" | awk -F'|' '{print $2}')
map_ok=$(printf '%s' "$OUT" | awk -F'|' '{print $3}')
[ "$map_ok" = "2" ] && ok "two dedicated rows mapped" || bad "S2 map-lines: $OUT"
printf '%s' "$rc_line2" | grep -q "Washington(203.0.113.8)" && ok "Washington kept its own country" || bad "S2 candidates: $OUT"

echo "S3: bug-inject -- sync failure swallowed (rc forced 0) must fail S1"
INJ=$(mktemp /tmp/dp_inj2_XXXXXX)
python3 - "$WATCHDOG" "$INJ" << 'PYINJ'
import sys
from pathlib import Path
src, dst = sys.argv[1], sys.argv[2]
s = Path(src).read_text()
start = s.find("_sync_node_candidates() {")
assert start >= 0, "fn missing"
end = s.find("\n}", start)
body = s[start:end]
# injection: make the network-call failure return success (swallow the rc)
old = '_raw=$(timeout 15 surflare nodes 2>/dev/null) || return 1'
assert body.count(old) == 1, "call line missing"
new_body = body.replace(old, '_raw=$(timeout 15 surflare nodes 2>/dev/null) || true', 1)
Path(dst).write_text(s[:start] + new_body + s[end:])
PYINJ
OUT=$(NODES_RC=124 NODE_SEED="Chicago" run_sync "$INJ")
[ "${OUT%%|*}" = "0" ] && ok "swallowed rc caught (returns 0, S1 would fail)" || bad "S3 NOT caught: $OUT"
rm -f "$INJ"

echo "S4: bug-inject -- hardcoding the country must fail S2"
INJ=$(mktemp /tmp/dp_inj3_XXXXXX)
python3 - "$WATCHDOG" "$INJ" << 'PYINJ'
import sys
from pathlib import Path
src, dst = sys.argv[1], sys.argv[2]
s = Path(src).read_text()
old = '\t\t\t_b="${_arr[-1]}"\n'
assert s.count(old) == 1, "anchor missing"
# injection: hardcode the country like the pre-fix code did
Path(dst).write_text(s.replace(old, '\t\t\t_b="United States(${_ip})"\n', 1))
PYINJ
NODES_OUT="  $(printf '\xf0\x9f\x94\x92') United States(198.51.100.7)AT&T
  $(printf '\xf0\x9f\x94\x92') Washington(203.0.113.8)
  $(printf '\xf0\x9f\x87\xba\xf0\x9f\x87\xb8') Chicago (x3)"
OUT=$(NODE_SEED="United States(198.51.100.7)" MAP_PRINT=1 run_sync "$INJ")
bad_map=$(printf '%s' "$OUT" | grep -c "United States(203.0.113.8)" || true)
[ "$bad_map" -ge 1 ] && ok "hardcoded country caught (wrong map row present)" || bad "S4 NOT caught: $OUT"
rm -f "$INJ"

echo "R11: pin already active when catalog arrives -> no reconnect"
OUT=$(PENDING=1 DEADLINE="$FUTURE" NODE="$DEDICATED" \
	CANDS="$DEDICATED|Chicago" PREV_ACTIVE="$DEDICATED" run_retry)
[ "$OUT" = "0|$DEDICATED|0|0|" ] && ok "already active -> no reconnect, no file churn" || bad "R11: $OUT"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
