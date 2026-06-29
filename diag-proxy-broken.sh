#!/bin/bash
# diag-proxy-broken.sh — capture proxy/internal state when health is anomalous
# Run manually:  /usr/local/sbin/diag-proxy-broken.sh
# Auto-triggered: by watchdog when Proxy path broken detected (future integration)
set -e

TS=$(date +%Y%m%d_%H%M%S)
DIR="/tmp/diag_proxy_${TS}"
mkdir -p "$DIR"

echo "=== diagnostics at $(date) ===" | tee "$DIR/00_summary.txt"

# 1. Watchdog health state — direct vs proxy path discrepancy markers
echo "--- watchdog health ---" | tee -a "$DIR/00_summary.txt"
dmesg | grep surflare_watchdog | tail -30 > "$DIR/01_watchdog_dmesg.txt"
dmesg | grep surflare_watchdog | grep -E 'PROXY_BROKEN|Proxy path|Health check|TUNNEL_OK|post-reconnect|reconnect_count|fail_count' | tail -10 | tee -a "$DIR/00_summary.txt"
echo "fail_count guess: $(dmesg | grep 'Consecutive failures' | tail -1)" | tee -a "$DIR/00_summary.txt"

# 2. 503 state — is G2 accumulating?
echo "--- 503 state ---" | tee -a "$DIR/00_summary.txt"
cat /run/surflare_503_state 2>/dev/null | tee -a "$DIR/00_summary.txt" || echo "(absent)" | tee -a "$DIR/00_summary.txt"

# 3. Proxy TCP connections — which relay servers, socket state
echo "--- proxy TCP sockets ---" | tee -a "$DIR/00_summary.txt"
ss -tnp | grep surflare-proxy > "$DIR/03_proxy_sockets.txt"
echo "total connections: $(wc -l < "$DIR/03_proxy_sockets.txt")" | tee -a "$DIR/00_summary.txt"
# Suspicious states
grep -c 'CLOSE.WAIT\|FIN.WAIT\|LAST.ACK\|SYN.SENT' "$DIR/03_proxy_sockets.txt" 2>/dev/null | { read _v; echo "unhealthy states: $_v"; } | tee -a "$DIR/00_summary.txt"
# Unique relay servers
awk '{print $5}' "$DIR/03_proxy_sockets.txt" | cut -d: -f1 | sort -u > "$DIR/03_relay_ips.txt"
echo "relay servers: $(tr '\n' ' ' < "$DIR/03_relay_ips.txt")" | tee -a "$DIR/00_summary.txt"

# 4. Conntrack for relay connections — are they actually forwarding?
echo "--- conntrack relay ---" | tee -a "$DIR/00_summary.txt"
for ip in $(cat "$DIR/03_relay_ips.txt"); do
    conntrack -L -d "$ip" 2>/dev/null || true
done > "$DIR/04_conntrack_relay.txt"
echo "conntrack entries: $(wc -l < "$DIR/04_conntrack_relay.txt")" | tee -a "$DIR/00_summary.txt"
grep -c 'ASSURED' "$DIR/04_conntrack_relay.txt" 2>/dev/null | { read _v; echo "ASSURED: $_v"; } | tee -a "$DIR/00_summary.txt"
grep -cv 'ASSURED' "$DIR/04_conntrack_relay.txt" 2>/dev/null | { read _v; echo "non-ASSURED: $_v"; } | tee -a "$DIR/00_summary.txt"

# 5. Proxy log tail — urltest errors, reconnect attempts
echo "--- proxy log ---" | tee -a "$DIR/00_summary.txt"
if [ -f /var/log/surflare/surflare-proxy.log ]; then
    tail -100 /var/log/surflare/surflare-proxy.log > "$DIR/05_proxy_log_tail.txt"
    echo "lines: $(wc -l < "$DIR/05_proxy_log_tail.txt")" | tee -a "$DIR/00_summary.txt"
    grep -c 'urltest.*503\|ERROR\|i/o timeout\|connection refused\|no route' "$DIR/05_proxy_log_tail.txt" 2>/dev/null | { read _v; echo "error lines: $_v"; } | tee -a "$DIR/00_summary.txt"
fi

# 6. Routing — does direct probe take a different path than proxy?
echo "--- routing ---" | tee -a "$DIR/00_summary.txt"
ip rule show > "$DIR/06_routing.txt"
ip route show table 100 >> "$DIR/06_routing.txt" 2>/dev/null || true
ip route show | grep default | tee -a "$DIR/00_summary.txt"

# 7. Tproxy nft state — REJECT or tproxy?
echo "--- tproxy ---" | tee -a "$DIR/00_summary.txt"
nft list chain inet sw_lan_tproxy prerouting 2>/dev/null | grep -E 'tproxy|REJECT|reject|return' > "$DIR/07_tproxy.txt"
nft list chain inet sw_lan_tproxy prerouting 2>/dev/null | grep -c 'tproxy ip' | { read _v; echo "tproxy rules: $_v"; } | tee -a "$DIR/00_summary.txt"
nft list chain inet sw_lan_tproxy prerouting 2>/dev/null | grep -c 'REJECT\|reject' | { read _v; echo "REJECT rules: $_v"; } | tee -a "$DIR/00_summary.txt"

# 8. Killswitch — what's allowed through?
echo "--- killswitch ---" | tee -a "$DIR/00_summary.txt"
nft list set inet killswitch server_ips 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' ' > "$DIR/08_server_ips.txt"
echo "server_ips: $(cat "$DIR/08_server_ips.txt")" | tee -a "$DIR/00_summary.txt"

# 9. Auth staleness check
echo "--- auth ---" | tee -a "$DIR/00_summary.txt"
_last_ref=0
[ -f /run/surflare_last_token_refresh ] && _last_ref=$(cat /run/surflare_last_token_refresh 2>/dev/null)
_now=$(date +%s)
echo "last refresh: ${_last_ref:-0} ($(( _now - ${_last_ref:-0} ))s ago)" | tee -a "$DIR/00_summary.txt"

# 10. Active node and mode
echo "--- session ---" | tee -a "$DIR/00_summary.txt"
cat /etc/surflare/mode.conf 2>/dev/null | tee -a "$DIR/00_summary.txt"
dmesg | grep 'Session: node=' | tail -1 | tee -a "$DIR/00_summary.txt"

echo "=== saved to $DIR ===" | tee -a "$DIR/00_summary.txt"

# 11. Direct probe (already goes through sing-box via OUTPUT tproxy)
echo "--- live probe ---" | tee -a "$DIR/00_summary.txt"
curl -so /dev/null -w "direct(via-singbox): %{http_code} %{time_total}s %{remote_ip}\n" \
    --max-time 10 https://www.google.com/generate_204 2>&1 | tee -a "$DIR/00_summary.txt"
