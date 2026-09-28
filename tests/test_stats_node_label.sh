#!/usr/bin/env bash
# STATS node label tracks the live session, not the session-start label.
# A pin-back moves the tunnel without a reconnect, so _sess_node stays on
# the city the session began on while _active_node is reconciled to the
# Server: line every tick.  The STATS line must name the live node.
# shellcheck disable=SC2016
set -u
cd "$(dirname "$0")/.." || exit 1
WD="surflare_watchdog.sh"
[ -f "$WD" ] || { echo "FAIL: $WD not found"; exit 1; }
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the real _report_stats body.  It calls date and reads a state
# file; stub both so the only thing under test is which variable it prints.
awk '
    /^_report_stats\(\)/ { f=1 }
    f { print }
    f && /^}/ { exit }
' "$WD" > "$TMP/fn.sh"

cat > "$TMP/drive.sh" <<'EOF'
#!/usr/bin/env bash
set -u
log() { echo "$*"; }
date() { echo 7200; }
STORM_503_STATE="/nonexistent"
_stats_start_ts=0
_stats_reconnects=1
_stats_rotations=1
_stats_degraded=""
_stats_last_report=0
_sess_node="Los Angeles"
_sess_exit="?"
_active_node="United States(12.104.12.149)AT&T"
source ./fn.sh
_report_stats
EOF

OUT=$(cd "$TMP" && bash drive.sh 2>/dev/null)
echo "$OUT" | grep -qF 'node=United States(12.104.12.149)AT&T' \
    && ok "STATS names the reconciled live node" \
    || bad "STATS did not name the live node: [$OUT]"
echo "$OUT" | grep -qF 'node=Los Angeles' \
    && bad "STATS still names the session-start city" \
    || ok "STATS dropped the stale session-start city"

bash -n "$WD" && ok "bash -n watchdog" || bad "bash -n watchdog"
echo "PASS=$(( $(grep -c '^PASS:' <<< "$(true)") ))"
echo "FAIL=$fail"
exit $fail
