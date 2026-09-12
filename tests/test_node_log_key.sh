#!/bin/bash
# Tests for _node_log_key: dedicated-IP nodes get provider-internal outbound
# tags (private_NNN) in sing-box, so node_health keys rebuilt from the display
# name never match. 2026-09-12 incident: dedicated leg dead 3h, 99 urltest
# errors attributed to nothing, proactive rotation never fired.
#
# Run against the production script by default; pass a script path as $1 to
# test a mutated copy (bug-injection). The resolver and the consumer function
# are EXTRACTED from the script under test, never copied, so a passing test
# proves the production code, not a drifted duplicate.
#
# shellcheck disable=SC2015  # ok()/bad() always return 0: A && ok || bad is exact if/else here
# shellcheck disable=SC2016  # single-quoted stubs/patterns are literal on purpose
# shellcheck disable=SC2034  # NODE_HEALTH_FILE is consumed by the eval'd production functions

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
WATCHDOG="${1:-surflare_watchdog.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

extract_func() { awk -v name="$2" '$0 ~ "^" name "\\(\\)" {f=1} f {print} f && /^}/ {exit}' "$1"; }

RESOLVER=$(extract_func "$WATCHDOG" _node_log_key)
if [ -z "$RESOLVER" ]; then
	echo "  NOTE: _node_log_key absent in $WATCHDOG -- stubbing pre-fix behavior (display-name key)"
	RESOLVER='_node_log_key() {
	local node="$1" transit="${2:-}"
	if [ -n "$transit" ]; then
		printf "mh_via_%s_to_%s\n" "$transit" "$node"
	else
		printf "%s\n" "$node"
	fi
}'
fi
eval "$RESOLVER"

CONSUMER=$(extract_func "$WATCHDOG" _node_is_log_healthy)
[ -n "$CONSUMER" ] || { echo "FATAL: _node_is_log_healthy extract empty"; exit 1; }
eval "$CONSUMER"

# Deps of the extracted consumer.
log() { :; }

DED='United States(65.195.35.200)'
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
NH="$TMPD/nh.json"
NODE_HEALTH_FILE="$NH"

# Fixture: dedicated leg broken via Washington (99 errors), no display key.
fixture_ded_broken() {
	cat > "$NH" <<'EOF'
{"nodes": {
  "mh_via_Washington_to_private_576": {"healthy": false, "error_count": 99},
  "mh_via_Washington_to_Atlanta": {"healthy": false, "error_count": 3}
}}
EOF
}
# Fixture: dedicated node has a display-named entry (future/drift case).
fixture_ded_display() {
	cat > "$NH" <<'EOF'
{"nodes": {
  "mh_via_Washington_to_United States(65.195.35.200)": {"healthy": false, "error_count": 42}
}}
EOF
}
# Fixture: two private legs under the same transit (ambiguous).
fixture_two_private() {
	cat > "$NH" <<'EOF'
{"nodes": {
  "mh_via_Washington_to_private_576": {"healthy": false, "error_count": 99},
  "mh_via_Washington_to_private_577": {"healthy": false, "error_count": 5}
}}
EOF
}
# Fixture: private leg only under a DIFFERENT transit.
fixture_other_transit() {
	cat > "$NH" <<'EOF'
{"nodes": {
  "mh_via_Dallas_to_private_576": {"healthy": false, "error_count": 99}
}}
EOF
}

echo "== resolver unit cases =="
fixture_ded_broken
out=$(_node_log_key "$DED" Washington)
[ "$out" = "mh_via_Washington_to_private_576" ] && ok "dedicated resolves to observed private tag" || bad "dedicated resolves to private tag (got: $out)"

out=$(_node_log_key Atlanta Washington)
[ "$out" = "mh_via_Washington_to_Atlanta" ] && ok "city node keeps display key" || bad "city display key (got: $out)"

fixture_ded_display
out=$(_node_log_key "$DED" Washington)
[ "$out" = "mh_via_Washington_to_United States(65.195.35.200)" ] && ok "exact display key wins when present" || bad "display key wins (got: $out)"

fixture_two_private
out=$(_node_log_key "$DED" Washington)
[ "$out" = "mh_via_Washington_to_United States(65.195.35.200)" ] && ok "two private legs = no attribution" || bad "ambiguous private legs must not resolve (got: $out)"

fixture_other_transit
out=$(_node_log_key "$DED" Washington)
[ "$out" = "mh_via_Washington_to_United States(65.195.35.200)" ] && ok "private leg under other transit ignored" || bad "other-transit private ignored (got: $out)"

# --- dedicated label must be a full trailing IPv4 (regex tightened) ----
fixture_ded_broken
out=$(_node_log_key "United States(65.195.35)" Washington)
[ "$out" = "mh_via_Washington_to_United States(65.195.35)" ] && ok "partial label (1.2.3) is not dedicated" || bad "partial label must not resolve (got: $out)"

out=$(_node_log_key "United States(65.195.35.200.)" Washington)
[ "$out" = "mh_via_Washington_to_United States(65.195.35.200.)" ] && ok "trailing-dot label is not dedicated" || bad "trailing-dot label must not resolve (got: $out)"

out=$(_node_log_key "United States(999.1.2.3)" Washington)
[ "$out" = "mh_via_Washington_to_private_576" ] && ok "octet range not validated (documented)" || bad "octet-range behavior changed (got: $out)"

out=$(_node_log_key "$DED" "")
[ "$out" = "$DED" ] && ok "no transit = plain node name" || bad "plain node name (got: $out)"

rm -f "$NH"
out=$(_node_log_key "$DED" Washington)
[ "$out" = "mh_via_Washington_to_United States(65.195.35.200)" ] && ok "missing health file = display key" || bad "missing file fallback (got: $out)"

echo "== consumer e2e (_node_is_log_healthy) =="
fixture_ded_broken
if _node_is_log_healthy "$DED" Washington; then
	bad "broken dedicated leg must be unhealthy (99 errors via private tag)"
else
	ok "broken dedicated leg reported unhealthy"
fi

fixture_ded_broken
if _node_is_log_healthy Atlanta Washington; then
	ok "city node with 3 errors (<=10) still healthy"
else
	bad "city node 3 errors must stay healthy"
fi

fixture_ded_broken
if _node_is_log_healthy Miami Washington; then
	ok "absent node key = healthy"
else
	bad "absent node key must be healthy"
fi

echo "== wiring assertions =="
ROT=$(extract_func "$WATCHDOG" _handle_proactive_node_rotation)
printf '%s\n' "$ROT" | grep -qF '_cur_key=$(_node_log_key' \
	&& ok "proactive rotation resolves cur_key via _node_log_key" \
	|| bad "proactive rotation still builds cur_key from display name"

STARTUP=$(awk '/# Startup observability/,/^fi$/' "$WATCHDOG")
printf '%s\n' "$STARTUP" | grep -qF '_startup_key=$(_node_log_key' \
	&& ok "startup observability resolves key via _node_log_key" \
	|| bad "startup observability still builds key from display name"

echo
echo "RESULT: $PASS passed, $FAIL failed ($WATCHDOG)"
[ "$FAIL" -eq 0 ]
