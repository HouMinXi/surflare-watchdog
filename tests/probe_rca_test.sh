#!/bin/bash
# Transit probe root-cause analysis v2
# Captures deep diagnostics to find WHY probes fail, not just IF.
# Usage: sudo bash /tmp/probe_rca_test.sh
# Output: /tmp/probe_rca_<timestamp>/ (per-test dirs + summary)
# WARNING: VPN offline for ~8-12 minutes. Restarts watchdog at end.

set -u

NODE="${NODE:-Los Angeles}"
MODE="${MODE:-global}"
CONNECT_TIMEOUT=12
ROUTE_POLL_MAX=15
PROCESS_EXIT_TIMEOUT=20

if [ "$EUID" -ne 0 ]; then
    echo "Must run as root: sudo $0" >&2
    exit 1
fi

OUTDIR="/tmp/probe_rca_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S.%3N')" "$*" >> "$SUMMARY"
    printf '[%s] %s\n' "$(date '+%H:%M:%S.%3N')" "$*" >&2
}

cleanup() {
    surflare disconnect >/dev/null 2>&1
    killall surflare-proxy 2>/dev/null
    local i=0
    while pgrep -x surflare-proxy >/dev/null 2>&1 && [ "$i" -lt "$PROCESS_EXIT_TIMEOUT" ]; do
        sleep 1; i=$((i + 1))
    done
    pgrep -x surflare-proxy >/dev/null 2>&1 && killall -KILL surflare-proxy 2>/dev/null
    if nft list table inet surflare >/dev/null 2>&1; then
        nft flush table inet surflare 2>/dev/null || true
        nft delete table inet surflare 2>/dev/null || true
    fi
    while ip rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null || true
}

trap_cleanup() {
    trap - EXIT INT TERM
    local rc=$?
    log "Signal caught (rc=${rc}), cleaning up..."
    cleanup
    log "Restarting surflare-watchdog..."
    systemctl start surflare-watchdog 2>/dev/null
    log "Aborted. Output: $OUTDIR"
    exit "$rc"
}
trap trap_cleanup EXIT INT TERM

snapshot_state() {
    local outfile="$1"
    {
        echo "=== timestamp: $(date '+%H:%M:%S.%3N') ==="
        echo "=== PID ==="
        pgrep -ax 'surflare|surflare-proxy' 2>/dev/null || echo "(none)"
        echo "=== surflare status ==="
        surflare status 2>&1 || echo "(status failed)"
        echo "=== nftables ==="
        nft list table inet surflare 2>&1 || echo "(no table)"
        echo "=== ip rule ==="
        ip rule show 2>/dev/null | grep -E 'fwmark|lookup 100' || echo "(no fwmark rule)"
        echo "=== ip route table 100 ==="
        ip route show table 100 2>/dev/null || echo "(empty)"
        echo "=== ss surflare-proxy listen ==="
        ss -tlnp 2>/dev/null | grep surflare || echo "(not listening)"
    } > "$outfile" 2>&1
}

curl_verbose() {
    local target="$1" max_time="$2"
    curl -v --connect-timeout 4 --max-time "$max_time" \
        -o /dev/null -w '\n=== curl metrics ===\nhttp_code: %{http_code}\ntime_namelookup: %{time_namelookup}\ntime_connect: %{time_connect}\ntime_appconnect: %{time_appconnect}\ntime_starttransfer: %{time_starttransfer}\ntime_total: %{time_total}\nremote_ip: %{remote_ip}\nremote_port: %{remote_port}\nlocal_ip: %{local_ip}\nlocal_port: %{local_port}\nexitcode: %{exitcode}\n' \
        "$target" 2>&1
}

rapid_probe() {
    local transit="$1" test_dir="$2" duration="${3:-30}"

    log "  connect --transit $transit --daemon"
    if ! timeout "$CONNECT_TIMEOUT" surflare connect \
        --node "$NODE" --mode "$MODE" \
        --transit "$transit" --daemon >/dev/null 2>&1; then
        log "  connect failed"
        cleanup
        return 1
    fi

    local w=0
    while [ "$w" -lt "$ROUTE_POLL_MAX" ]; do
        pgrep -x surflare-proxy >/dev/null 2>&1 && \
        nft list table inet surflare >/dev/null 2>&1 && \
        ip rule show | grep -q 'fwmark 0x1 lookup 100' && break
        sleep 1; w=$((w + 1))
    done
    log "  routing ready after ${w}s"

    if [ "$w" -ge "$ROUTE_POLL_MAX" ]; then
        log "  routing timeout"
        cleanup
        return 1
    fi

    snapshot_state "$test_dir/state_after_routing.txt"

    local t0 elapsed
    t0=$(date +%s)
    log "  rapid curl every 1s for ${duration}s..."

    printf '%-4s %-4s %-7s %-8s %-8s %-4s %-5s\n' \
        "sec" "http" "time" "pid_pre" "pid_post" "nft" "rule" \
        > "$test_dir/rapid_curl.txt"

    while true; do
        elapsed=$(( $(date +%s) - t0 ))
        [ "$elapsed" -ge "$duration" ] && break

        local pid_before pid_after
        pid_before=$(pgrep -x surflare-proxy 2>/dev/null | head -1)

        local code http time_val
        code=$(curl -s --connect-timeout 2 --max-time 4 \
            -o /dev/null -w '%{http_code}:%{time_total}' \
            https://www.google.com 2>/dev/null)
        http="${code%%:*}"
        time_val="${code##*:}"

        pid_after=$(pgrep -x surflare-proxy 2>/dev/null | head -1)

        local nft_ok="Y" rule_ok="Y"
        nft list table inet surflare >/dev/null 2>&1 || nft_ok="N"
        ip rule show | grep -q 'fwmark 0x1 lookup 100' || rule_ok="N"

        printf '%-4s %-4s %-7s %-8s %-8s %-4s %-5s\n' \
            "$elapsed" "$http" "$time_val" \
            "${pid_before:--}" "${pid_after:--}" "$nft_ok" "$rule_ok" \
            >> "$test_dir/rapid_curl.txt"

        case "$http" in
            200|301|302)
                log "  t+${elapsed}s: OK http=$http time=${time_val}s pid=${pid_before}"
                ;;
            *)
                log "  t+${elapsed}s: FAIL http=$http pid=${pid_before}->${pid_after} nft=$nft_ok rule=$rule_ok"
                ;;
        esac

        sleep 1
    done

    curl_verbose "https://www.google.com" 10 > "$test_dir/final_curl_verbose.txt" 2>&1
    snapshot_state "$test_dir/state_final.txt"
    cleanup
}

log "=== Transit Probe RCA v2 ==="
log "Output dir: $OUTDIR"
log "Stopping surflare-watchdog..."
systemctl stop surflare-watchdog 2>/dev/null
cleanup
sleep 2

log ""
log "=== T1: TIMELINE Tokyo (30s rapid curl after routing ready) ==="
log "  Goal: map the exact connectivity timeline of the first candidate"
mkdir -p "$OUTDIR/T1_tokyo_timeline"
rapid_probe Tokyo "$OUTDIR/T1_tokyo_timeline" 30
sleep 2

log ""
log "=== T2: TIMELINE Seoul (30s after Tokyo cleanup) ==="
log "  Goal: map Seoul connectivity as second candidate"
mkdir -p "$OUTDIR/T2_seoul_after_tokyo"
rapid_probe Seoul "$OUTDIR/T2_seoul_after_tokyo" 30
sleep 2

log ""
log "=== T3: SOLO Seoul (no prior Tokyo) ==="
log "  Goal: Seoul baseline without Tokyo interference"
mkdir -p "$OUTDIR/T3_seoul_solo"
rapid_probe Seoul "$OUTDIR/T3_seoul_solo" 30
sleep 2

log ""
log "=== T4: SOLO Tokyo (after Seoul cleanup) ==="
log "  Goal: does order matter? Tokyo after Seoul"
mkdir -p "$OUTDIR/T4_tokyo_after_seoul"
rapid_probe Tokyo "$OUTDIR/T4_tokyo_after_seoul" 30
sleep 2

code=""
t5_start=0
t5_elapsed=0
t5_iter=0

log ""
log "=== T5: Tokyo then Seoul with status snapshots ==="
log "  Goal: capture surflare internal state during Seoul probe"
mkdir -p "$OUTDIR/T5_status_detail"
log "  --- Phase A: Tokyo connect + snapshot ---"
if timeout "$CONNECT_TIMEOUT" surflare connect \
    --node "$NODE" --mode "$MODE" \
    --transit Tokyo --daemon >/dev/null 2>&1; then
    sleep 10
    snapshot_state "$OUTDIR/T5_status_detail/tokyo_connected.txt"
    log "  Tokyo connected, snapshotted"
    cleanup
    snapshot_state "$OUTDIR/T5_status_detail/after_tokyo_cleanup.txt"
    log "  Tokyo cleaned up, snapshotted"
else
    log "  Tokyo connect failed"
    cleanup
fi
sleep 2
log "  --- Phase B: Seoul connect + periodic snapshots ---"
if timeout "$CONNECT_TIMEOUT" surflare connect \
    --node "$NODE" --mode "$MODE" \
    --transit Seoul --daemon >/dev/null 2>&1; then
    t5_start=$(date +%s)
    t5_iter=0
    while [ "$(( $(date +%s) - t5_start ))" -lt 25 ]; do
        t5_elapsed=$(( $(date +%s) - t5_start ))
        snapshot_state "$OUTDIR/T5_status_detail/seoul_state_iter${t5_iter}_${t5_elapsed}s.txt"
        code=$(curl -s --connect-timeout 2 --max-time 4 \
            -o /dev/null -w '%{http_code}' \
            https://www.google.com 2>/dev/null)
        log "  Seoul t+${t5_elapsed}s: http=$code"
        t5_iter=$((t5_iter + 1))
        sleep 2
    done
    curl_verbose "https://www.google.com" 10 > "$OUTDIR/T5_status_detail/seoul_curl_verbose.txt" 2>&1
    cleanup
else
    log "  Seoul connect failed"
    cleanup
fi
sleep 2

log ""
log "=== T6: Repeat T1+T2 for reproducibility ==="
mkdir -p "$OUTDIR/T6_tokyo_repeat"
rapid_probe Tokyo "$OUTDIR/T6_tokyo_repeat" 30
sleep 2
mkdir -p "$OUTDIR/T6_seoul_repeat"
rapid_probe Seoul "$OUTDIR/T6_seoul_repeat" 30

log ""
log "============================================"
log "Tests complete. Output: $OUTDIR"
log ""
log "Key files per test:"
log "  rapid_curl.txt          -- per-second: http code, timing, PID, nft/rule state"
log "  state_after_routing.txt -- full system state when routing poll passed"
log "  state_final.txt         -- full system state at end"
log "  final_curl_verbose.txt  -- curl -v for failure mode diagnosis"
log ""
log "Analysis priority:"
log "  1. Compare T1 vs T2 rapid_curl.txt -- when does connectivity start?"
log "  2. Compare T2 vs T3 -- does Seoul differ as 2nd vs solo?"
log "  3. Check PID column -- does surflare-proxy crash/restart during probe?"
log "  4. Check nft/rule columns -- does routing flicker?"
log "  5. Read T5 seoul_state_*s.txt -- what does surflare status say over time?"
log "  6. Read final_curl_verbose.txt -- connection refused vs timeout vs SSL?"
log "============================================"
log ""
log "Restarting surflare-watchdog..."
systemctl start surflare-watchdog
trap - EXIT INT TERM
log "Done."
echo ""
echo "Output: $OUTDIR"
echo "Summary: cat $OUTDIR/summary.txt"
echo "Quick view: for f in $OUTDIR/T*/rapid_curl.txt; do echo \"--- \$f ---\"; cat \"\$f\"; done"
