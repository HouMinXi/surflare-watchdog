#!/usr/bin/env bash
# Regression for the silent half-deploy: scp inherits the script's
# stdin, so a piped answer ('y\n') is drained before the restart
# prompt; read then hits EOF and set -e kills the script AFTER the new
# file lands but BEFORE restart or rollback -- N100 is left running the
# old process off the new file with no message.  Two behaviours pin the
# fix: a piped 'y' must reach the restart prompt, and genuine EOF must
# degrade to the safe abort+rollback path instead of silent death.
# Stubs scp/ssh on PATH (A-class flow logic; no router needed).  The
# last block neuters the scp stdin redirect in a COPY to prove case 1
# exercises the fix, not the test itself.
# shellcheck disable=SC2015  # ok/bad idiom
set -u
cd "$(dirname "$0")/.." || exit 1
DEPLOY="scripts/surflare_deploy.sh"
fail=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

STUB="$(mktemp -d)"
LOG="$(mktemp)"
OUT="$(mktemp)"
trap 'rm -rf "$STUB" "$LOG" "$OUT"' EXIT
export LOG

# scp stub: drains its stdin exactly like the real scp/ssh pair, then
# reports success.  With the fix, main invokes scp with </dev/null so
# this drain can no longer reach the script's own stdin.
cat > "$STUB/scp" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
echo "SCP $*" >> "$LOG"
exit 0
EOF

# ssh stub: drains stdin exactly like the real ssh -- except when -n
# is passed, which makes real ssh reopen stdin from /dev/null, so the
# stub must honor the flag and leave stdin alone.  Logs every
# invocation; restart and rollback get distinct markers.
cat > "$STUB/ssh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-n" ]; then shift; else cat >/dev/null 2>&1 || true; fi
echo "SSH $*" >> "$LOG"
case "$*" in
    *"grep -m1"*) printf 'NODE="x"\nTRANSIT="y"\n' ;;
    *"surflare-watchdog restart"*) echo "RESTART" >> "$LOG" ;;
    *"mv "*.prev*) echo "ROLLBACK" >> "$LOG" ;;
esac
exit 0
EOF
chmod +x "$STUB/scp" "$STUB/ssh"
export PATH="$STUB:$PATH"

# Local watchdog copy whose NODE=/TRANSIT= match the stub's live cfg,
# so the refuse gate passes and main proceeds to scp/restart.
LOCAL_WD="$(mktemp --suffix=.sh)"
trap 'rm -rf "$STUB" "$LOG" "$OUT" "$LOCAL_WD"' EXIT
printf '#!/usr/bin/env bash\nNODE="x"\nTRANSIT="y"\n' > "$LOCAL_WD"

: > "$LOG"

# Case 1: piped 'y' must survive scp and drive the restart.  Broken
# script: scp drains the pipe, read EOF, set -e death -- rc!=0 and no
# RESTART marker.  Fixed: rc=0, RESTART logged, "Deploy OK" printed.
printf 'y\n' | DEPLOY_WAIT=1 bash "$DEPLOY" "$LOCAL_WD" > "$OUT" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^RESTART$' "$LOG" && grep -q 'Deploy OK' "$OUT"; then
    ok "piped answer reaches restart prompt (rc=$rc)"
else
    bad "piped answer lost: rc=$rc restart=$(grep -c '^RESTART$' "$LOG") out=[$(tail -2 "$OUT")]"
fi

# Case 2: genuine EOF (no answer at all) must take the safe
# abort+rollback path, not die silently mid-deploy.  Broken script:
# rc=1, no "Aborted", no ROLLBACK.  Fixed: rc=0 + "Aborted by user." +
# rollback restores .prev.
: > "$LOG"
DEPLOY_WAIT=1 bash "$DEPLOY" "$LOCAL_WD" </dev/null > "$OUT" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Aborted by user' "$OUT" && grep -q '^ROLLBACK$' "$LOG"; then
    ok "EOF degrades to abort+rollback (rc=$rc)"
else
    bad "EOF handling broken: rc=$rc aborted=$(grep -c 'Aborted by user' "$OUT") rollback=$(grep -c '^ROLLBACK$' "$LOG")"
fi

# Teeth: neuter the scp stdin redirect in a COPY; case 1 must then lose
# the answer again.  Proves case 1 gates on the fix, not on the stubs.
NEUT="$(mktemp --suffix=.sh)"
python3 - "$DEPLOY" "$NEUT" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = '"${N100}:${REMOTE_WATCHDOG}.new" < /dev/null'
assert needle in text, "scp stdin redirect not found; injection target drifted"
open(dst, "w", encoding="utf-8").write(text.replace(needle, '"${N100}:${REMOTE_WATCHDOG}.new"  # INJECTED', 1))
PYEOF
if [ ! -s "$NEUT" ]; then
    bad "injection copy not produced"
else
    : > "$LOG"
    printf 'y\n' | DEPLOY_WAIT=1 bash "$NEUT" "$LOCAL_WD" > "$OUT" 2>&1
    if grep -q '^RESTART$' "$LOG"; then
        bad "neutered scp still preserves stdin; injection ineffective"
    else
        ok "injection (redirect neutered) loses the answer -- teeth proven"
    fi
fi
rm -f "$NEUT"

# Teeth 2: same idea for the ssh family -- strip -n from the cfg-probe
# ssh in a COPY; that ssh runs before scp, so it drains the answer even
# earlier.  Guards against someone later "simplifying" the -n flags away.
NEUT="$(mktemp --suffix=.sh)"
python3 - "$DEPLOY" "$NEUT" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = 'ssh -n "$N100" "{ grep -m1'
assert needle in text, "cfg ssh -n not found; injection target drifted"
open(dst, "w", encoding="utf-8").write(text.replace(needle, 'ssh "$N100" "{ grep -m1', 1))
PYEOF
if [ ! -s "$NEUT" ]; then
    bad "injection copy (ssh -n) not produced"
else
    : > "$LOG"
    printf 'y\n' | DEPLOY_WAIT=1 bash "$NEUT" "$LOCAL_WD" > "$OUT" 2>&1
    if grep -q '^RESTART$' "$LOG"; then
        bad "cfg ssh without -n still preserves stdin; injection ineffective"
    else
        ok "injection (cfg ssh -n stripped) loses the answer -- teeth proven"
    fi
fi
rm -f "$NEUT"

bash -n "$DEPLOY" && ok "bash -n deploy" || bad "bash -n deploy"

exit "$fail"
