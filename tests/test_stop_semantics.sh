#!/bin/bash
# Tests for the stop-semantics fix: user-requested stops must stay down.
#
# Two production components are tested against the REAL sources:
#   1. laptop/surflare_early_detector.sh -- main loop must idle silently
#      while the stop marker exists (no heartbeat, no signalling), and
#      resume monitoring after the marker is removed.
#   2. install.sh WATCHDOG_RESURRECT_CRON -- the resurrect cron must key
#      on PID-file liveness (not bare pgrep), so orphan strays cannot
#      satisfy it and a stopped stack is never relaunched behind the
#      user's back.
#
# Incident background (2026-08-21): user stopped the stack at 09:54;
# early-detector's procd respawn chain relaunched a watchdog behind the
# marker, then the 5-minute resurrect cron saw the stray via pgrep and
# left the zombie stack running all day. The exact scenario is replayed
# in T4/T5.
#
# shellcheck disable=SC2015  # `[ cond ] && ok x || bad x` is safe here:
# ok()/bad() always return 0, so bad never runs after a successful ok.
# shellcheck disable=SC2016  # single quotes around harness bodies are
# intentional -- the inner $VARS must expand in the CHILD shell.

set -u
cd "$(dirname "$0")/.." || exit 1
DETECTOR=laptop/surflare_early_detector.sh
INSTALL=install.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# -- Extract the detector's main loop marker-guard block ----------------
# Anchor: the stopped-file check at the top of the while loop.
extract_detector_guard() {
    awk '
        /^[[:space:]]*if \[\[ -f "\$WATCHDOG_STOPPED_FILE" \]\]/ { f=1 }
        f { print }
        f && /^[[:space:]]*fi$/ { exit }
    ' "$DETECTOR"
}

# -- Extract the resurrect cron line from install.sh --------------------
extract_resurrect_cron() {
    # Anchor on the variable assignment (robust to trailing-fragment
    # changes); strip the surrounding single quotes, then strip the first
    # FIVE whitespace-separated cron fields generically (schedule-agnostic:
    # works for */5 today and */3 or hourly tomorrow).
    sed -n "s/^[[:space:]]*WATCHDOG_RESURRECT_CRON='\(.*\)'$/\1/p" "$INSTALL" \
        | awk '{ for (i=6; i<=NF; i++) printf "%s%s", $i, (i<NF ? " " : "\n") }'
}

# T1: detector declares the marker path constant with the canonical value
grep -q 'readonly WATCHDOG_STOPPED_FILE="/run/surflare_watchdog.stopped"' "$DETECTOR" \
    && ok "T1: WATCHDOG_STOPPED_FILE constant declared with canonical path" \
    || bad "T1: WATCHDOG_STOPPED_FILE constant missing/wrong value"

# T3 note: the harness depends on the REAL timeout(1) (no stub) and on
# bash; the detector's `timeout 5 nft` / `timeout 10 ss` calls run against
# stubbed nft/ss that exit 1 immediately.

# T2: detector main loop checks the marker before any sampling
GUARD=$(extract_detector_guard)
[ -n "$GUARD" ] && ok "T2: marker guard block present in main loop" \
    || bad "T2: marker guard block not found"

# T3: guard block contains sleep+wait+continue (idle loop, no heartbeat)
echo "$GUARD" | grep -q 'sleep "$MONITOR_INTERVAL"' \
    && echo "$GUARD" | grep -q 'continue' \
    && ok "T3: guard idles (sleep + continue), no signalling" \
    || bad "T3: guard does not idle correctly"

# T4: DETECTOR BEHAVIOR -- with marker present, loop skips heartbeat.
# Run the real detector with a fake logger/ss/nft in PATH, marker present,
# for one iteration; the heartbeat file must NOT be touched.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK/bin/ss" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$WORK/bin/nft" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$WORK/bin/"*
# NOTE: no `timeout` stub -- the real timeout(1) must stay in PATH; the
# detector invokes `timeout 5 nft` / `timeout 10 ss`, and the stubbed
# nft/ss already exit 1 immediately. A stubbed timeout would kill the
# detector itself (caught while debugging T5: `exec sleep 0` terminated
# the main loop before its first heartbeat).
# Patch the interval to 1s so the test is fast, keep everything else real.
# Path rewrites keep the detector inside $WORK (no /run writes on the dev
# box; root-owned paths would fail open and fake a "not touched" pass).
sed -e 's/^readonly MONITOR_INTERVAL=30.*/readonly MONITOR_INTERVAL=1/' \
    -e "s|/run/surflare_watchdog.stopped|$WORK/marker|" \
    -e "s|/run/surflare_detector.alive|$WORK/alive|" \
    -e "s|/run/surflare_watchdog.pid|$WORK/wd.pid|" \
    "$DETECTOR" > "$WORK/detector_test.sh"
chmod +x "$WORK/detector_test.sh"
touch "$WORK/marker"
cat > "$WORK/run_det.sh" <<EOF
#!/bin/bash
cd "$WORK" || exit 1
PATH="$WORK/bin:\$PATH" ./detector_test.sh &
DPID=\$!
sleep 1
# R2 review finding: T4 must not false-pass when the detector dies
# immediately (syntax error, missing stub). Assert liveness first.
# Exit code is the machine contract; the sentinel line is for humans.
if ! kill -0 \$DPID 2>/dev/null; then
  echo "DETECTOR_DIED_EARLY" >&2
  exit 1
fi
sleep 2
kill \$DPID 2>/dev/null
wait \$DPID 2>/dev/null
exit 0
EOF
chmod +x "$WORK/run_det.sh"
# R3 review finding: use run_det.sh's EXIT CODE, not stderr string
# comparison -- a dying detector may emit extra stderr before the
# sentinel, defeating an exact-match check.
if bash "$WORK/run_det.sh" 2>/dev/null; then DET_T4_ALIVE=1; else DET_T4_ALIVE=0; fi
[ ! -f "$WORK/alive" ] && [ "$DET_T4_ALIVE" = "1" ] \
    && ok "T4: marker present -> heartbeat NOT touched (idle honored)" \
    || bad "T4: heartbeat touched while stopped (or detector died: alive=$DET_T4_ALIVE)"

# T5: marker removed -> detector resumes heartbeat
rm -f "$WORK/marker" "$WORK/alive"
if bash "$WORK/run_det.sh" 2>/dev/null; then DET_T5_ALIVE=1; else DET_T5_ALIVE=0; fi
[ -f "$WORK/alive" ] && [ "$DET_T5_ALIVE" = "1" ] \
    && ok "T5: marker removed -> heartbeat resumes" \
    || bad "T5: heartbeat never resumed after marker removal (alive=$DET_T5_ALIVE)"

# T6: resurrect cron uses PID-file liveness, not bare pgrep
CRON=$(extract_resurrect_cron)
[ -n "$CRON" ] && ok "T6: resurrect cron line extractable" \
    || bad "T6: resurrect cron line not found"
echo "$CRON" | grep -q 'cat /run/surflare_watchdog.pid' \
    && echo "$CRON" | grep -qF '"/proc/$_wp/cmdline"' \
    && echo "$CRON" | grep -qF '*[!0-9]*' \
    && echo "$CRON" | grep -qF '""|0|' \
    && echo "$CRON" | grep -q 'tr .\\0. .\\n. < "/proc/$_wp/cmdline" 2>/dev/null | grep -qx' \
    && echo "$CRON" | grep -qF 'timeout 60 /etc/init.d/surflare-watchdog start' \
    && ok "T6: cron keys on whole-argv cmdline check + numeric guard (0 rejected) + start timeout" \
    || bad "T6: cron liveness check incomplete (numeric guard / whole-argv / timeout)"
echo "$CRON" | grep -qw 'pgrep' \
    && bad "T6: cron still uses pgrep (stray-satisfiable)" \
    || ok "T6: no bare pgrep (strays cannot satisfy cron)"
# R1 review finding: silent restart has no diagnostics. Both start paths
# must log via logger before starting.
echo "$CRON" | grep -q 'logger -t surflare-watchdog "resurrect cron' \
    && echo "$CRON" | grep -qF 'start FAILED rc=$?' \
    && ok "T6: restart paths log intent + result (forensics)" \
    || bad "T6: restart logging incomplete (need intent + rc result)"

# T7-T10: cron logic branch simulation (mirrors the N100-verified matrix)
run_cron_branch() {
    # $1 marker path ('' = absent), $2 pidfile content ('' = missing),
    # $3 pid alive (1/0). Prints START if the branch would start.
    local _m="$1" _p="$2" _alive="$3"
    local _cmd
    _cmd=$CRON
    # Marker path substitution first (double quotes needed for expansion).
    _cmd=$(printf '%s\n' "$_cmd" \
        | sed "s|/run/surflare_watchdog.stopped|${_m:-/nonexistent_marker}|")
    # Neutralize logger (it writes to syslog; under test we want silence
    # and portability) and stub the /proc cmdline check. sed with single
    # quotes keeps $_wp literal (parameter expansion inside ${var//pat/}
    # would expand the function-local empty _wp and never match).
    _cmd=$(printf '%s\n' "$_cmd" \
        | sed 's|logger -t surflare-watchdog|:|' \
        | sed "s|cat /run/surflare_watchdog.pid|cat ${_p}|")
    if [ "$_alive" = "1" ]; then
        # Stub: replace only the command name -- 'grep -qx' is metachar-free
        # so the sed pattern is stable; the leftover quoted pattern becomes
        # an ignored argument of true/false. tr still reads /proc/$_wp/cmdline
        # (nonexistent in tests) but the pipeline result is forced.
        _cmd=$(printf '%s\n' "$_cmd" | sed 's~grep -qx~true~')
    else
        _cmd=$(printf '%s\n' "$_cmd" | sed 's~grep -qx~false~')
    fi
    _cmd=${_cmd//timeout 60 \/etc\/init.d\/surflare-watchdog start/echo START}
    eval "$_cmd" 2>/dev/null
}

# Variant for T8a: override the storm-cooldown path so the cron reads a
# file the caller controls (expired timestamps must fall through).
run_cron_branch_cool_expired() {
    # $1 marker path ('' = absent), $2 pidfile content, $3 pid alive,
    # COOL_FILE env = cooldown file to substitute.
    local _m="$1" _p="$2" _alive="$3"
    local _cmd
    _cmd=$CRON
    _cmd=$(printf '%s\n' "$_cmd" \
        | sed "s|/run/surflare_watchdog.stopped|${_m:-/nonexistent_marker}|" \
        | sed "s|/run/surflare_watchdog.storm_cool_until|${COOL_FILE:-/nonexistent_cool}|g" \
        | sed 's|logger -t surflare-watchdog|:|' \
        | sed "s|cat /run/surflare_watchdog.pid|cat ${_p}|")
    if [ "$_alive" = "1" ]; then
        _cmd=$(printf '%s\n' "$_cmd" | sed 's~grep -qx~true~')
    else
        _cmd=$(printf '%s\n' "$_cmd" | sed 's~grep -qx~false~')
    fi
    _cmd=${_cmd//timeout 60 \/etc\/init.d\/surflare-watchdog start/echo START}
    eval "$_cmd" 2>/dev/null
}

R=""
touch "$WORK/m2"   # marker file must EXIST for T7 (user-stop honored)
R=$(run_cron_branch "$WORK/m2" "$WORK/p2" 1)
rm -f "$WORK/m2"
[ -z "$R" ] && ok "T7: marker present -> no start (user stop honored)" \
    || bad "T7: cron starts despite stop marker: got '$R'"

# T7a/T7b (R4 review): dynamic coverage of the non-numeric case arms.
# Regression removing the ""|0| or *[!0-9]* arms would pass T7-T10 and
# only trip the static T6 grep; these exercise the arms end-to-end.
echo 0 > "$WORK/p0"
R=$(run_cron_branch "" "$WORK/p0" 0)
[ "$R" = "START" ] && ok "T7a: pidfile=0 -> START (pid-zero arm live)" \
    || bad "T7a: pidfile=0 did not start: got '$R'"
echo abc > "$WORK/pabc"
R=$(run_cron_branch "" "$WORK/pabc" 0)
[ "$R" = "START" ] && ok "T7b: pidfile=abc -> START (non-numeric arm live)" \
    || bad "T7b: pidfile=abc did not start: got '$R'"

# T8a (R4 review): storm-cooldown file present but EXPIRED -> cron must
# proceed to the PID check (cooldown is a pause, not a latch).
echo 1 > "$WORK/cool_expired"   # timestamp far in the past
echo 999999 > "$WORK/p3c"
R=$(COOL_FILE="$WORK/cool_expired" run_cron_branch_cool_expired "" "$WORK/p3c" 0)
[ "$R" = "START" ] && ok "T8a: expired cooldown -> proceeds to PID check" \
    || bad "T8a: expired cooldown blocked start: got '$R'"

# T8b (R5 review): storm-cooldown file present and ACTIVE (future
# timestamp) -> cron must NOT start (storm backoff honored).
echo $(( $(date +%s) + 300 )) > "$WORK/cool_active"
R=$(COOL_FILE="$WORK/cool_active" run_cron_branch_cool_expired "" "$WORK/p3c" 0)
[ -z "$R" ] && ok "T8b: active cooldown -> no start (storm backoff honored)" \
    || bad "T8b: active cooldown did not block start: got '$R'"

touch "$WORK/p3"; echo 999999 > "$WORK/p3"
R=$(run_cron_branch "" "$WORK/p3" 1)
[ -z "$R" ] && ok "T8: pidfile live -> no start (healthy stack untouched)" \
    || bad "T8: cron starts despite live watchdog: got '$R'"

R=$(run_cron_branch "" "$WORK/p3" 0)
[ "$R" = "START" ] && ok "T9: pidfile stale -> start (resurrect works)" \
    || bad "T9: cron fails to resurrect dead watchdog: got '$R'"

R=$(run_cron_branch "" "/nonexistent_pid" 0)
[ "$R" = "START" ] && ok "T10: no pidfile -> start (clean boot path)" \
    || bad "T10: cron fails on missing pidfile: got '$R'"

echo ""
echo "detector guard:"
extract_detector_guard | sed 's/^/    /'
echo ""
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
