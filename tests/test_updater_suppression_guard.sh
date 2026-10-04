#!/usr/bin/env bash
# _route_updater_active must not stay fooled by a hung updater whose
# heartbeat keeps the lock mtime fresh.  2026-10-02 P0: the 09-29 cron
# instance wedged in do_wait for 4 days (bare `wait` collecting the
# heartbeat under cron's no-job-control session); the heartbeat kept
# re-touching the lock, so "lock fresh + process alive" read as an
# active download window the whole time and suppressed health
# escalation during a real outage.
#
# The gate is now a pure age bound: every pgrep-matching process must
# be younger than UPDATER_MAX_AGE_S.  This test exercises the real
# functions from the real script against staged scenarios.
set -u
cd "$(dirname "$0")/.." || exit 1
WD="surflare_watchdog.sh"
[ -f "$WD" ] || { echo "FAIL: $WD not found"; exit 1; }
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
PIDS=""
cleanup() {
    for p in $PIDS; do kill "$p" 2>/dev/null; done
    rm -rf "$TMP"
}
trap cleanup EXIT

# Extract the real function bodies (the main gate plus its helper, so
# the harness exercises the actual production logic end to end).
awk '
    /^_route_updater_active\(\)/ { f=1 }
    f { print }
    f && /^}/ { exit }
' "$WD" > "$TMP/fn.sh"
grep -q '_proc_alive' "$TMP/fn.sh" || { bad "function not extracted"; exit 1; }
awk '
    /^_updater_age_ok\(\)/ { f=1 }
    f { print }
    f && /^}/ { exit }
' "$WD" > "$TMP/age.sh"
grep -q 'stat' "$TMP/age.sh" || { bad "age helper not extracted"; exit 1; }

# Harness: sources the real function with lock path and _proc_alive
# pointed at a staged PID table.
make_harness() {  # $1=out $2=staged_parent_pid
    cat > "$1" <<EOF
#!/usr/bin/env bash
set -u
STAGED_PID=$2
_proc_alive() {
    case "\$1" in
        surflare_route_updater) kill -0 "\$STAGED_PID" 2>/dev/null ;;
        *) pgrep -f "\$1" >/dev/null 2>&1 ;;
    esac
}
export LOCKF="$TMP/ru.lock"
EOF
    sed 's|local lock="/run/surflare_route_updater.lock"|local lock="$LOCKF"|' "$TMP/fn.sh" >> "$1"
    cat "$TMP/age.sh" >> "$1"
    cat >> "$1" <<'EOF'
if _route_updater_active; then echo ACTIVE; else echo INACTIVE; fi
EOF
}

LOCKF="$TMP/ru.lock"; export LOCKF

# --- Case 1: young updater, fresh lock -> ACTIVE (suppression on)
touch "$LOCKF"
bash -c "exec -a surflare_route_updater sleep 50" &
HUNG=$!; PIDS="$PIDS $HUNG"
make_harness "$TMP/h1.sh" "$HUNG"
V=$(bash "$TMP/h1.sh" 2>/dev/null)
if [ "$V" = "ACTIVE" ]; then
    ok "young updater with fresh lock reads ACTIVE"
else
    bad "young updater reads INACTIVE ($V) - legit run would be interrupted"
fi

# --- Case 2: over-age run with fresh heartbeat -> INACTIVE (the P0 shape)
# The staged parent pretends to be over-age by setting the cap BELOW its
# own age: UPDATER_MAX_AGE_S=0 makes any process with now_age > 0 over-age.
# Birth-race hardening: wait until /proc shows now_age >= 1 so the
# comparison is deterministic (0 > 0 is false).
mkdir -p "$TMP/stage2"
cat > "$TMP/stage2/run.sh" <<'OUTER'
#!/usr/bin/env bash
curl -s --connect-timeout 50 --max-time 55 http://10.255.255.1/ >/dev/null 2>&1 &
echo $! > "$1/curl.pid"
sleep 60
OUTER
chmod +x "$TMP/stage2/run.sh"
exec -a surflare_route_updater bash "$TMP/stage2/run.sh" "$TMP/stage2" &
WORKER2=$!; PIDS="$PIDS $WORKER2"
# Deterministic: wait until /proc/<pid>/stat yields now_age >= 1.
for i in $(seq 1 20); do
    st=$(awk '{print $22}' "/proc/$WORKER2/stat" 2>/dev/null)
    up=$(awk '{print int($1)}' /proc/uptime)
    [ -n "$st" ] && [ $(( up - st / 100 )) -ge 1 ] && break
    sleep 0.2
done
make_harness "$TMP/h2.sh" "$WORKER2"
V2=$(UPDATER_MAX_AGE_S=0 bash "$TMP/h2.sh" 2>/dev/null)
if [ "$V2" = "INACTIVE" ]; then
    ok "over-age run with live curl child no longer suppresses (P0 shape)"
else
    bad "over-age run reads ACTIVE ($V2) - the actual P0 shape recurs"
fi

# --- Case 3: orphaned heartbeat (parent SIGKILLed) must not suppress
# the NEXT legit run.  Stage: an old matching process (the orphan) plus
# a young lock; the age gate must see the orphan and read INACTIVE.
bash -c "exec -a surflare_route_updater sleep 50" &
ORPHAN=$!; PIDS="$PIDS $ORPHAN"
touch "$LOCKF"
make_harness "$TMP/h3.sh" "$ORPHAN"
V3=$(UPDATER_MAX_AGE_S=0 bash "$TMP/h3.sh" 2>/dev/null)
if [ "$V3" = "INACTIVE" ]; then
    ok "over-age matching process (orphan heartbeat) breaks suppression"
else
    bad "orphaned heartbeat still suppresses ($V3) - next-day run stays blocked"
fi

# --- Structural: the gate must not depend on a working-children scan
# (removed 2026-10-02: serial-curl gaps caused false INACTIVE mid-run).
grep -q '_updater_has_work' "$TMP/fn.sh" "$TMP/age.sh" 2>/dev/null \
    && bad "children-scan gate still present (false-INACTIVE source)" \
    || ok "pure age gate (no children scan)"

# --- Structural: the updater's RIPE wait must be an explicit PID list
# (POSIX, ash-safe).  Neither a bare wait (collects the heartbeat: the
# 4-day do_wait wedge) nor the bash-only 'wait $(jobs -p | grep -v)'
# (empty substitution under busybox ash -> same bare wait) is allowed.
_UP=router/surflare_route_updater.sh
# Strip comments using the shell's own parser.  A hand-rolled lexer
# cannot keep up with shell lexing.  For each line, the comment starts
# at the first '#' whose removal leaves a line bash -n accepts as
# complete: that is exactly where the shell sees a comment.
python3 - "$_UP" "$TMP/upd-nocomment.sh" <<'STRIPEOF'
import subprocess, sys
def whole_accepts(lines):
    r = subprocess.run(["bash", "-n"],
                       input=("\n".join(lines) + "\n").encode(),
                       capture_output=True)
    return r.returncode == 0
src_lines = open(sys.argv[1], "rb").read().decode().split("\n")
out = []
for n, line in enumerate(src_lines):
    body = line.rstrip("\n")
    cut = len(body)
    for i, c in enumerate(body):
        if c != "#":
            continue
        # A '#' glued to the preceding word is part of that word.
        if i > 0 and body[i - 1] not in " \t;|&()":
            continue
        # Judge against the whole file: a per-line check cannot see a
        # comment that follows an unfinished construct.
        trial = src_lines[:n] + [body[:i]] + src_lines[n + 1:]
        if whole_accepts(trial):
            cut = i
            break
    out.append(body[:cut])
open(sys.argv[2], "w").write("\n".join(out))
STRIPEOF
# Normalize shell no-ops around wait so 'command wait' / '{ wait; }' /
# '(wait)' / 'wait &' cannot smuggle a bare wait past the regex.
sed -e ':a' -e 's/\bcommand[[:space:]]\+\(-[a-zA-Z]*[[:space:]]\+\|--[[:space:]]\+\)/command /;ta' -e 's/\bcommand[[:space:]]\+/ /' -e 's/\bbuiltin[[:space:]]\+/ /' -e 's/\btime[[:space:]]\+\(-p[[:space:]]\+\)\?/ /' -e 's/\beval[[:space:]]\+//g' -e 's/["'\'']//g' \
    -e 's/|&/ | /g' -e 's/[({][[:space:]]*wait[[:space:]]*;*[[:space:]]*[)}][[:space:]]*/ wait /' -e 's/[({][^)}\n]*|[[:space:]]*wait[[:space:]]*[)}]/ wait /' "$TMP/upd-nocomment.sh" > "$TMP/upd-norm.sh"
# A bare wait is 'wait' followed by anything except a PID argument:
# end of line, ;, &, ||, &&, or a redirect.  ('wait $pid' still passes.)
grep -nE '(^|;|&|&&|\|\||\||\b(if|elif|until|while|then|do|else|esac)\b|[({)]|[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\+?=)[^;|&]*[[:space:]]+|[0-9]*[<>]+[|&]?[[:space:]]*[^[:space:];|&]+[[:space:]]+)[[:space:]]*(![[:space:]]+)?wait([[:space:]]*($|;|&|\||\|\||&&|2>|>)|[[:space:]]+\$\()' "$TMP/upd-norm.sh" \
    && bad "updater contains a bare wait (deadlock source)" \
    || ok "no bare wait in updater"
grep -q 'wait $(jobs' "$TMP/upd-nocomment.sh" \
    && bad "updater uses jobs-table wait (ash-broken, deadlock source)" \
    || ok "no jobs-table wait in updater"
# Structural scan reads the dequoted copy: a quoted 'for ... do' or a
# quoted 'wait "$_pid"' is text, not the loop.
python3 "$(dirname "$0")/lib_dequote.py" "$TMP/upd-nocomment.sh"
# The dequoted copy proves the wait is real code; the raw copy proves
# the variable is exactly _pid.
# The curls are children of ripe_fetch.py, which reaps each pid with
# waitid.  A shell wait here would also collect the heartbeat.
grep -Fq 'ripe_fetch.py' "$TMP/upd-nocomment.sh" \
    && grep -Fq 'os.waitid(os.P_PID' "$(dirname "$0")/../router/ripe_fetch.py" \
    && ok "updater RIPE fetch reaps with waitid" \
    || bad "updater RIPE fetch does not reap with waitid"
# waitid on a pid this process did not start fails at once.  The
# launcher must be the parent: it calls Popen, then waitid on that pid.
LAUNCHER="$(dirname "$0")/../router/ripe_fetch.py"
export LAUNCHER
python3 - << 'PY'
import os, pathlib, sys
src = pathlib.Path(os.environ["LAUNCHER"]).read_text()
popen = src.find("subprocess.Popen")
wait = src.find("os.waitid(os.P_PID")
if popen < 0 or wait < popen:
    sys.exit("launcher does not start the child it waits for")
PY
ok "ripe_fetch starts the child it waits for"
# The shell no longer starts the curls, so a stale $! cannot collect
# the heartbeat.  The launcher must both start curl and waitid.
grep -Fq 'subprocess.Popen(curl_argv' "$(dirname "$0")/../router/ripe_fetch.py" \
    && grep -Fq 'os.waitid(os.P_PID' "$(dirname "$0")/../router/ripe_fetch.py" \
    && ok "launcher starts curl and reaps that pid" \
    || bad "launcher does not start and reap its own curl"

# --- Structural: the heartbeat checks parent liveness (comment-stripped)
grep -q 'kill -0 "$2" 2>/dev/null || break' "$TMP/upd-nocomment.sh" \
    && ok "heartbeat exits when parent dies" \
    || bad "heartbeat can outlive its parent"

bash -n "$WD" && ok "bash -n watchdog" || bad "bash -n watchdog"
bash -n router/surflare_route_updater.sh && ok "bash -n updater" || bad "bash -n updater"

echo "FAIL=$fail"
exit $fail
