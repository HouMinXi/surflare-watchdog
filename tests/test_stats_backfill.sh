#!/usr/bin/env bash
# Session-identity backfill (STATS node=? exit=? gap).
# An adopted tunnel (proxy outlived this watchdog, zero reconnects
# since start) never passes through _record_connect, so _sess_node and
# _sess_exit stay empty and every STATS line prints node=? exit=?.
# The backfill fills them once, on the first healthy tick, from the
# reconciled _active_node.
# shellcheck disable=SC2015,SC2016  # ok/bad idiom; $1 is for the inner sh -c
set -u
cd "$(dirname "$0")/.." || exit 1
WD="surflare_watchdog.sh"
[ -f "$WD" ] || { echo "FAIL: $WD not found (run from repo root)"; exit 1; }
fail=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- functional: real function from the real script, stubbed state ---
# The script is sourced with --source-only; only the variables the
# backfill touches are pre-set.
cat > "$TMP/drive.sh" <<'EOF'
#!/usr/bin/env bash
set -u
source ./surflare_watchdog.sh --source-only

case "$1" in
    fill-ok)
        _sess_node=""
        _sess_exit=""
        _active_node="United States(12.104.10.184)"
        _backfill_session_identity "OK"
        echo "node=[${_sess_node}] exit=[${_sess_exit}]"
        ;;
    fill-country)
        _sess_node=""
        _sess_exit=""
        _active_node="United States(12.104.10.184)"
        _backfill_session_identity "US"
        echo "node=[${_sess_node}] exit=[${_sess_exit}]"
        ;;
    no-clobber)
        _sess_node="Atlanta"
        _sess_exit="US"
        _active_node="United States(12.104.10.184)"
        _backfill_session_identity "OK"
        echo "node=[${_sess_node}] exit=[${_sess_exit}]"
        ;;
esac
EOF
chmod +x "$TMP/drive.sh"

OUT=$(bash "$TMP/drive.sh" fill-ok 2>/dev/null)
if echo "$OUT" | grep -qF 'node=[United States(12.104.10.184)] exit=[?]'; then
    ok "empty session backfilled from _active_node (exit normalized to ?)"
else
    bad "backfill fill-ok: got [$OUT]"
fi

OUT=$(bash "$TMP/drive.sh" fill-country 2>/dev/null)
if echo "$OUT" | grep -qF 'node=[United States(12.104.10.184)] exit=[US]'; then
    ok "country health kept as exit"
else
    bad "backfill fill-country: got [$OUT]"
fi

OUT=$(bash "$TMP/drive.sh" no-clobber 2>/dev/null)
if echo "$OUT" | grep -qF 'node=[Atlanta] exit=[US]'; then
    ok "existing session identity not clobbered"
else
    bad "backfill no-clobber: got [$OUT]"
fi

# --- structural: call site sits in the health-success branch ---
HEALTH_START=$(grep -n 'VPN healthy -- Google 200' "$WD" | head -1 | cut -d: -f1)
CALL_LINE=$(awk '/_backfill_session_identity "\$health"/ {print NR; exit}' "$WD")
if [ -n "$HEALTH_START" ] && [ -n "$CALL_LINE" ] && [ "$CALL_LINE" -gt "$HEALTH_START" ]; then
    ok "backfill called inside health-success branch"
else
    bad "backfill call missing or before health branch (health=$HEALTH_START call=$CALL_LINE)"
fi

# --- teeth: the call line must be exactly one site ---
NCALL=$(grep -c '_backfill_session_identity "\$health"' "$WD")
if [ "$NCALL" -eq 1 ]; then
    ok "exactly one call site"
else
    bad "expected 1 call site, found $NCALL"
fi

# --- teeth: neuter the call in a COPY; STATS vars would stay empty ---
# The fill-ok driver against a copy with the function body emptied must
# NOT fill the variables -- proves the functional cases exercise the
# real body, not some unrelated path.
NEUT="$TMP/watchdog_neutered.sh"
python3 - "$WD" "$NEUT" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
needle = '_backfill_session_identity() {'
i = src.find(needle)
assert i != -1, "function not found"
j = src.find('\n}', i)
assert j != -1, "function end not found"
open(sys.argv[2], 'w').write(src[:i] + needle + '\n\treturn 0' + src[j:])
PYEOF
if [ -s "$NEUT" ]; then
    OUT=$(sed "s|source ./surflare_watchdog.sh|source $NEUT|" "$TMP/drive.sh" > "$TMP/drive_neut.sh" && bash "$TMP/drive_neut.sh" fill-ok 2>/dev/null)
    if echo "$OUT" | grep -qF 'node=[] exit=[]'; then
        ok "teeth: emptied body leaves session identity unset"
    else
        bad "teeth: emptied body still filled vars [$OUT] -- cases test nothing"
    fi
else
    bad "injection copy not produced"
fi

bash -n "$WD" && ok "bash -n watchdog" || bad "bash -n watchdog"
exit $fail
