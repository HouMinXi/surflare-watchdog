#!/usr/bin/env bash
# Storm-cooldown early-lift test (sandboxed harness).
#
# Runs the REAL _enter_storm_cooldown body with every filesystem/nft side
# effect redirected into a temp sandbox: no live killswitch flush, no live
# /run writes.  Must run as root (writes the sandbox); refuses to degrade
# silently.
#
# Cases:
#   1. session connected AFTER cooldown start (out-of-band) -> lift early
#   2. session still Disconnected                        -> hold full window
#   3. session connected BEFORE cooldown start (storm's own leftover
#      session; PROXY_BROKEN/CN-exit paths)              -> hold full window
#   4. lift must delete the persisted storm_cool_until file (restart
#      inside the window must not re-impose the cooldown)
#   5. INJECTION: probe deleted -> connected case holds (test bites)
set -u
[ "$(id -u)" -eq 0 ] || { echo "SKIP: needs root (sandbox writes + real paths)"; exit 2; }
cd "$(dirname "$0")/.." || exit 2
SRC=surflare_watchdog.sh
WORK=$(mktemp -d /tmp/stormlift.XXXXXX)
RUN=$WORK/run
mkdir -p "$RUN" "$WORK/bin"
trap 'rm -rf "$WORK"' EXIT

# Extract the real function, then redirect its hardcoded side-effect paths
# into the sandbox: cool file under $RUN, nft stubbed on PATH.  Probe
# interval 60s -> 1s so the test runs in seconds.
sed -n '/^_enter_storm_cooldown() {/,/^}/p' "$SRC" > "$WORK/fn.raw"
sed -e "s|/run/surflare_watchdog.storm_cool_until|$RUN/storm_cool_until|g" \
    -e 's/_storm_probe_interval=60/_storm_probe_interval=1/' \
    "$WORK/fn.raw" > "$WORK/fn.sh"

# stub nft so the killswitch flush can never touch the live ruleset
cat > "$WORK/bin/nft" <<EOF
#!/bin/sh
echo "nft: \$*" >> "$WORK/nft.calls"
exit 0
EOF
chmod +x "$WORK/bin/nft"

cat > "$WORK/harness.sh" <<'EOF'
#!/usr/bin/env bash
set -u
STATUS_FILE=$1
WORK=$2
FNSH=$3
COOL_START_MIN_AGO=${4:-0}   # cooldown started N minutes ago (case 3)
COOL_START_AT=${6:-}         # fixed cooldown start HH:MM (midnight case)
STORM_COOLING=${5:-130}
run_health_check_now=0
storm_sleep_pid=""
reconnect_count=2
_healthy_consecutive=0
_diag_server_ips=""
FAIL_THRESHOLD_BASE=4
transient_count=0
_cn_consecutive=0
_transit_grace_ts=0
fail_count=0
log() { echo "log: $*"; }
_send_alert() { :; }
_tombstone_tproxy() { :; }
_remove_dns_fallback() { :; }
stop_packet_trace() { :; }
_restore_tproxy() { :; }
mkdir -p "$WORK/bin"
printf '#!/bin/sh\ncat "%s"\n' "$STATUS_FILE" > "$WORK/bin/surflare"
chmod +x "$WORK/bin/surflare"
PATH="$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH
# date shim: report a cooldown start N minutes in the past, or a fixed
# HH:MM for the midnight-crossing case
if [ "$COOL_START_MIN_AGO" -gt 0 ] || [ -n "$COOL_START_AT" ]; then
    mkdir -p "$WORK/datebin"
    cat > "$WORK/datebin/date" <<DEOF
#!/bin/sh
case "\$*" in
    +%H:%M) if [ -n "${COOL_START_AT}" ]; then
                echo "${COOL_START_AT}"
            else
                /bin/date -d "-${COOL_START_MIN_AGO} minutes" +%H:%M
            fi ;;
    *) /bin/date "\$@" ;;
esac
DEOF
    chmod +x "$WORK/datebin/date"
    PATH="$WORK/datebin:$PATH"
    export PATH
fi
source "$FNSH"
t0=$SECONDS
_enter_storm_cooldown test
echo "elapsed=$(( SECONDS - t0 ))"
EOF
chmod +x "$WORK/harness.sh"

mk_status() {  # $1 = since HH:MM or "none"
    if [ "$1" = none ]; then
        printf 'Surflare VPN Status\n  Status:      ○ Disconnected\n'
    else
        printf 'Surflare VPN Status\n  Status:      ● Connected │ since %s\n  Server:      United States(12.104.12.149)AT&T\n' "$1"
    fi
}
# Fixtures must be RELATIVE to the real clock (string HH:MM compare):
# out-of-band = 5 min in the future of "now" (cooldown just started,
# GUI connects a moment later); leftover = 30 min in the past (the
# storm's own session predates the cooldown).
OOB_SINCE=$(date -d "+5 minutes" +%H:%M)
LEFTOVER_SINCE=$(date -d "-30 minutes" +%H:%M)
mk_status "$OOB_SINCE" > "$WORK/oob.txt"
mk_status none         > "$WORK/down.txt"
mk_status "$LEFTOVER_SINCE" > "$WORK/leftover.txt"

pass=0; fail=0
run_case() {  # $1=status $2=expect $3=label $4=fn.sh $5=coolstart-ago $6=cooling $7=fixed-start
    local out lifts elapsed
    out=$(bash "$WORK/harness.sh" "$1" "$WORK" "$4" "${5:-0}" "${6:-130}" "${7:-}")
    lifts=$(echo "$out" | grep -c "lifted early" || true)
    elapsed=$(echo "$out" | sed -n "s/^elapsed=//p")
    if [ "$2" = lift ] && [ "${lifts:-0}" -ge 1 ] && [ "${elapsed:-999}" -le 10 ]; then
        echo "PASS [$3] lifted in ${elapsed}s"
        return 0
    elif [ "$2" = hold ] && [ "${lifts:-1}" -eq 0 ] && [ "${elapsed:-0}" -ge 5 ]; then
        echo "PASS [$3] held full window ${elapsed}s"
        return 0
    fi
    echo "FAIL [$3] expect=$2 lifts=${lifts:-?} elapsed=${elapsed:-?}"
    return 1
}

run_case "$WORK/oob.txt"      lift "out-of-band session"      "$WORK/fn.sh"        && pass=$((pass+1)) || fail=$((fail+1))
run_case "$WORK/down.txt"     hold "still down"               "$WORK/fn.sh" 0 6    && pass=$((pass+1)) || fail=$((fail+1))
run_case "$WORK/leftover.txt" hold "storm leftover session"   "$WORK/fn.sh" 10     && pass=$((pass+1)) || fail=$((fail+1))
# midnight crossing: cooldown started 23:58, out-of-band session since 00:02
mk_status 00:02 > "$WORK/midnight.txt"
run_case "$WORK/midnight.txt" lift "session across midnight"  "$WORK/fn.sh" 0 130 23:58 && pass=$((pass+1)) || fail=$((fail+1))
# midnight non-lift: same 23:58 start, leftover session from 23:00
mk_status 23:00 > "$WORK/midnight_old.txt"
run_case "$WORK/midnight_old.txt" hold "pre-midnight leftover" "$WORK/fn.sh" 0 6 23:58 && pass=$((pass+1)) || fail=$((fail+1))

# Case 4: lift must remove the persisted cool file (pre-seeded).
echo $(( $(date +%s) + 500 )) > "$RUN/storm_cool_until"
out=$(bash "$WORK/harness.sh" "$WORK/oob.txt" "$WORK" "$WORK/fn.sh" 0 130)
lifts=$(echo "$out" | grep -c "lifted early" || true)
if [ "${lifts:-0}" -ge 1 ] && [ ! -e "$RUN/storm_cool_until" ]; then
    echo "PASS [lift removes persisted cool file]"
    pass=$((pass+1))
else
    echo "FAIL [lift removes persisted cool file] lifts=${lifts:-?} file_exists=$([ -e "$RUN/storm_cool_until" ] && echo yes || echo no)"
    fail=$((fail+1))
fi

# Case 5 sanity: killswitch flush (v4 AND v6) went to the stub, never to live nft.
if grep -q "flush set inet killswitch server_ips$" "$WORK/nft.calls" 2>/dev/null \
   && grep -q "flush set inet killswitch server_ips6" "$WORK/nft.calls" 2>/dev/null; then
    echo "PASS [nft flush sandboxed]"
    pass=$((pass+1))
else
    echo "FAIL [nft flush sandboxed] sandbox log does not show both server_ips and server_ips6 flushes"
    fail=$((fail+1))
fi

# INJECTION: delete the probe; the out-of-band case must then hold.
sed -e "s|/run/surflare_watchdog.storm_cool_until|$RUN/storm_cool_until|g" \
    -e 's/_storm_probe_interval=60/_storm_probe_interval=1/' \
    "$WORK/fn.raw" > "$WORK/fn_inj.sh"
python3 - "$WORK/fn_inj.sh" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
# remove the whole probe block: from the rc=0 init through the break+fi
pat = re.compile(r"\n\t\t\t_storm_status_rc=0\n\t\t\t_storm_status=\$\(timeout 5 surflare status 2>/dev/null\).*?break\n\t\t\t\tfi\n\t\t\tfi\n", re.S)
s2 = pat.sub("\n", s)
assert s2 != s, "injection regex did not match -- harness broken"
open(p, "w").write(s2)
PY
if run_case "$WORK/oob.txt" hold "injection: probe deleted" "$WORK/fn_inj.sh" 0 6; then
    echo "PASS [injection] probe deleted -> held, test bites"
    pass=$((pass+1))
else
    echo "FAIL [injection] probe deleted but still lifted -- no teeth"
    fail=$((fail+1))
fi

echo "----------------------------------------"
echo "storm-cooldown lift test: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
