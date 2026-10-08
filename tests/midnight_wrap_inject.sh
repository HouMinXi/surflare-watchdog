#!/usr/bin/env bash
# Injection probe for the midnight wrap: delete the +1440 wrap line,
# the 23:58/00:02 case must HOLD (lift regresses to pre-fix behavior).
set -u
[ "$(id -u)" -eq 0 ] || { echo "SKIP: needs root"; exit 2; }
cd "$(dirname "$0")/.." || exit 2
WORK=$(mktemp -d /tmp/storminj3.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
RUN=$WORK/run; mkdir -p "$RUN" "$WORK/bin"

sed -n '/^_enter_storm_cooldown() {/,/^}/p' surflare_watchdog.sh > "$WORK/fn.raw"
sed -e "s|/run/surflare_watchdog.storm_cool_until|$RUN/storm_cool_until|g" \
    -e 's/_storm_probe_interval=60/_storm_probe_interval=1/' "$WORK/fn.raw" > "$WORK/fn.sh"
python3 - "$WORK/fn.sh" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).readlines()
out = [l for l in lines if "_delta + 1440" not in l]
assert len(out) == len(lines) - 1, "expected to drop exactly one line"
open(p, "w").writelines(out)
PY
grep -q "1440" "$WORK/fn.sh" && { echo "INJECTION FAILED TO APPLY"; exit 1; }
echo "injection applied (wrap line dropped)"

printf 'Surflare VPN Status\n  Status:      ● Connected │ since 00:02\n' > "$WORK/s.txt"
printf '#!/bin/sh\ncat "%s"\n' "$WORK/s.txt" > "$WORK/bin/surflare"
chmod +x "$WORK/bin/surflare"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/nft"; chmod +x "$WORK/bin/nft"
mkdir -p "$WORK/dbin"
cat > "$WORK/dbin/date" <<'EOF'
#!/bin/sh
case "$*" in
    "+%H:%M") echo "23:58" ;;
    *) /bin/date "$@" ;;
esac
EOF
chmod +x "$WORK/dbin/date"

# sanity: shim answers 23:58
shim=$("$WORK/dbin/date" '+%H:%M')
[ "$shim" = "23:58" ] || { echo "date shim broken: got $shim"; exit 1; }

out=$(bash -c '
set -u
STORM_COOLING=8
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
PATH="'"$WORK"'/bin:'"$WORK"'/dbin:/usr/bin:/bin:$PATH"
export PATH
source "'"$WORK"'/fn.sh"
t0=$SECONDS
_enter_storm_cooldown inj
echo "elapsed=$(( SECONDS - t0 ))"
')
echo "$out" | grep -E "log:|elapsed" | tail -3
if echo "$out" | grep -q "lifted early"; then
    echo "RESULT: LIFTED -- injection did NOT regress the midnight case (wrap line is not load-bearing?)"
    exit 1
fi
echo "RESULT: HELD -- midnight lift depends on the wrap line; injection proves the test bites"
