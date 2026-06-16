#!/bin/bash
# surflare_early_detector.sh
# Monitors surflare VPN tunnel TCP degradation and signals the watchdog
# to run an early health check, cutting detection latency from ~10min to <60s.
#
# Dependencies: ss (iproute2-ss), nft, logger, kill, timeout
# Deploy: start alongside surflare_watchdog.sh; managed by procd or cron.

set -o nounset

# Clean up background sleep on exit so no orphan processes are left.
_sleep_pid=""
trap '[[ -n "$_sleep_pid" ]] && kill "$_sleep_pid" 2>/dev/null; exit 0' INT TERM

# -- Configuration (must match watchdog paths) ------------------------
readonly WATCHDOG_PID_FILE="/run/surflare_watchdog.pid"
readonly DETECTOR_ALIVE_FILE="/run/surflare_detector.alive"
readonly MONITOR_INTERVAL=30     # seconds between ss samples
readonly DEGRADATION_THRESHOLD=16 # min score to fire USR1 (threshold raised from 8 to reduce false positives on high-latency nodes)
readonly COOLDOWN=300            # min seconds between USR1 signals; monitoring continues

# -- Dependency check -------------------------------------------------
for _cmd in ss nft logger kill timeout; do
    command -v "$_cmd" &>/dev/null \
        || { logger -t surflare_detector "FATAL: $_cmd not found"; exit 1; }
done

# -- Get current VPN server IPs from the killswitch nft set -----------
# server_ips lives in inet killswitch (not inet surflare).
get_server_ips() {
    # Wrap nft in timeout to prevent netlink lock contention from stalling the loop.
    timeout 5 nft list set inet killswitch server_ips 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | tr '\n' ' '
}

# -- Score one server IP for TCP degradation --------------------------
# Returns an integer score (0 = healthy or insufficient data, -1 = ss error).
#
# Three independent indicators (2 pts each):
#   cwnd <= 1  : window at minimum (not normal slow-start; cwnd=2 is a valid recovery)
#   rto > 8000 : RTO above 8 s (ss prints rto in ms; iproute2 divides tcpi_rto by 1000)
#   backoff >= 3: exponential backoff counter signals persistent loss
#
# A connection counts as degraded only when it scores >= 4 (at least 2 indicators hit).
# At least 2 concurrent degraded connections are required to rule out single-stream noise.
#
# Known limitation: when total_conns == 0 (VPN hard-down, no TCP sessions exist),
# the function returns 0, indistinguishable from a healthy tunnel. This is by design:
# the watchdog curl probe (CHECK_INTERVAL=5s) handles hard-down; this detector
# focuses on in-flight tunnel degradation where TCP sessions are still open.
#
# ss -ti dst <ip> returns all TCP connections to that IP, including non-tunnel
# connections such as SSH. These dilute the signal but require simultaneous
# degradation across at least 2 connections before an alert fires.
score_tunnel() {
    local server_ip="$1"
    local total_conns=0 degraded_conns=0 score=0

    # Capture ss output with a hard timeout to prevent netlink hangs.
    local ss_output ss_rc
    ss_output=$(timeout 10 ss -ti dst "$server_ip" 2>/dev/null)
    ss_rc=$?
    if (( ss_rc == 124 )); then
        logger -t surflare_detector "WARN: ss timed out for $server_ip, skipping"
        echo "-1"; return
    fi
    if (( ss_rc != 0 )); then
        logger -t surflare_detector "WARN: ss failed rc=$ss_rc for $server_ip, skipping"
        echo "-1"; return
    fi

    # Parse TCP info lines (one per connection, emitted for all CC algorithms).
    # Anchor the cwnd: pattern with a leading space to avoid matching initcwnd:.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local rto=0 cwnd=999 backoff=0
        [[ "$line" =~ rto:([0-9]+) ]]                && rto="${BASH_REMATCH[1]}"
        [[ "$line" =~ (^|[[:space:]])cwnd:([0-9]+) ]] && cwnd="${BASH_REMATCH[2]}"
        [[ "$line" =~ backoff:([0-9]+) ]]             && backoff="${BASH_REMATCH[1]}"

        (( total_conns++ ))
        local -i conn_score=0

        [[ $cwnd    -le 1    ]] && (( conn_score += 2 ))
        [[ $rto     -gt 8000 ]] && (( conn_score += 2 ))
        [[ $backoff -ge 3    ]] && (( conn_score += 2 ))

        if (( conn_score >= 4 )); then
            (( degraded_conns++ ))
            (( score += conn_score ))
        fi
    done < <(printf '%s\n' "$ss_output" | grep 'rto:')

    if (( total_conns >= 2 && degraded_conns >= 2 )); then
        echo "$score"
    else
        echo "0"
    fi
}

# -- Signal the watchdog to run an early health check -----------------
# Validates the PID file before signalling to avoid sending USR1 to a
# process that has recycled the watchdog's PID after it exited.
trigger_watchdog() {
    local reason="$1"
    local wpid

    # Read only the first line; a corrupted multi-line file would otherwise
    # concatenate into an invalid number.
    read -r wpid < "$WATCHDOG_PID_FILE" 2>/dev/null || wpid=""
    wpid="${wpid//[^0-9]/}"   # strip non-digits

    # Reject empty, zero, or non-numeric values before any kill call.
    [[ "$wpid" =~ ^[1-9][0-9]*$ ]] || {
        logger -t surflare_detector "EARLY_WARN: $reason - invalid pid '${wpid}'"
        return 1
    }

    # Confirm PID belongs to the watchdog, not a recycled process.
    # /proc/PID/cmdline uses NUL delimiters; convert before grep.
    if ! tr '\0' ' ' < "/proc/$wpid/cmdline" 2>/dev/null \
           | grep -qE 'surflare_watchdog|watchdog_conditional'; then
        logger -t surflare_detector "EARLY_WARN: $reason - pid=$wpid not watchdog (recycled?)"
        return 1
    fi

    if kill -USR1 "$wpid" 2>/dev/null; then
        logger -t surflare_detector "EARLY_WARN: $reason - USR1 sent to pid=$wpid"
    else
        logger -t surflare_detector "EARLY_WARN: $reason - kill USR1 failed (watchdog down?)"
        return 1
    fi
}

# -- Main loop --------------------------------------------------------
# Initialize last_alert to -COOLDOWN so the first degradation event fires
# immediately rather than being gated by the cooldown window.
last_alert=$(( -COOLDOWN ))
no_ip_count=0

while true; do
    # Heartbeat: the watchdog checks this file's mtime each cycle.
    # If stale by more than 75s it logs a warning that early detection is inactive.
    touch "$DETECTOR_ALIVE_FILE" 2>/dev/null || true

    # Background sleep so SIGTERM and other signals are delivered between
    # commands rather than being deferred until after the sleep completes.
    sleep "$MONITOR_INTERVAL" & _sleep_pid=$!
    wait "$_sleep_pid"
    _sleep_pid=""

    # -- Sample phase (runs regardless of cooldown state) -------------
    server_ips=$(get_server_ips)
    if [[ -z "$server_ips" ]]; then
        (( ++no_ip_count ))
        (( no_ip_count == 1 )) && \
            logger -t surflare_detector "INFO: server_ips empty (watchdog handles VPN down)"
        (( no_ip_count >= 5 )) && {
            logger -t surflare_detector \
                "WARN: server_ips empty for $(( no_ip_count * MONITOR_INTERVAL ))s"
            no_ip_count=0
        }
        continue
    fi
    no_ip_count=0

    total_score=0
    for ip in $server_ips; do
        s=$(score_tunnel "$ip")
        (( s < 0 )) && continue   # -1 = ss error/timeout; skip
        (( total_score += s ))
    done

    # -- Signal phase (gated by cooldown) -----------------------------
    now=$SECONDS
    if (( total_score >= DEGRADATION_THRESHOLD )); then
        if (( now - last_alert >= COOLDOWN )); then
            # Only advance last_alert when USR1 is successfully delivered.
            # A failed delivery does not consume the cooldown window.
            if trigger_watchdog "score=$total_score servers=$server_ips"; then
                last_alert=$now
            else
                logger -t surflare_detector "WARN: watchdog unreachable, cooldown not consumed"
            fi
        else
            logger -t surflare_detector \
                "COOLDOWN: score=$total_score ($(( COOLDOWN - now + last_alert ))s remaining)"
        fi
    fi
done
