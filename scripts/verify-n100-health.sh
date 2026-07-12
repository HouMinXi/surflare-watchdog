#!/bin/sh
# N100 post-reboot health check -- 14-point verification
# Usage: ssh root@192.168.100.1 'sh -s' < scripts/verify-n100-health.sh
# Or:   ssh root@192.168.100.1 < scripts/verify-n100-health.sh
#
# Run this after rebooting N100. All 14 checks must PASS.

PASS=0
FAIL=0
CHECK() {
    if [ "$1" = "PASS" ]; then
        echo "  PASS  $2"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $2 -- $3"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== N100 Health Check ($(date '+%H:%M:%S')) ==="
echo "uptime: $(awk '{printf "%dm%ds", int($1/60), int($1%60)}' /proc/uptime 2>/dev/null)"
echo ""

# 1. SmartDNS process
pgrep -f "smartdns -f" >/dev/null 2>&1 && CHECK PASS "1. SmartDNS process running" || CHECK FAIL "1. SmartDNS process" "not running"

# 2. SmartDNS port 6053
netstat -tunlp 2>/dev/null | grep -q ":6053.*smartdns" && CHECK PASS "2. SmartDNS on port 6053" || CHECK FAIL "2. SmartDNS port" "not on 6053"

# 3. SmartDNS log: no bind errors
grep -q "bind.*failed" /var/log/smartdns/smartdns.log 2>/dev/null && CHECK FAIL "3. SmartDNS bind errors" "found in log" || CHECK PASS "3. SmartDNS no bind errors"

# 4. procd crash loops: zero
CRASH=$(logread 2>/dev/null | grep -c "crash loop")
[ "$CRASH" = "0" ] && CHECK PASS "4. Zero crash loops" || CHECK FAIL "4. Crash loops" "$CRASH found"

# 5. dnsmasq on port 53
netstat -tunlp 2>/dev/null | grep -q ":53.*dnsmasq" && CHECK PASS "5. dnsmasq on port 53" || CHECK FAIL "5. dnsmasq port 53" "not found"

# 6. smartdns-custom deleted
[ ! -f /etc/init.d/smartdns-custom ] && CHECK PASS "6. smartdns-custom deleted" || CHECK FAIL "6. smartdns-custom" "still exists"

# 7. Watchdog running
pgrep -f "[s]urflare_watchdog.sh" >/dev/null 2>&1 && CHECK PASS "7. Watchdog running" || CHECK FAIL "7. Watchdog" "not running"

# 8. VPN exit US
EXIT=$(curl -s --max-time 5 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
[ "$EXIT" = "US" ] && CHECK PASS "8. VPN exit US" || CHECK FAIL "8. VPN exit" "got '$EXIT'"

# 9. Proxy fd limits
PID=$(pgrep -f "[s]urflare-proxy" | head -1)
FD=$(awk '/Max open files/{print $4}' /proc/$PID/limits 2>/dev/null)
[ "$FD" = "65535" ] && CHECK PASS "9. Proxy fd 65535" || CHECK FAIL "9. Proxy fd" "got $FD"

# 10. bypass_devices set populated
ELEM=$(nft list set inet sw_lan_tproxy bypass_devices 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ -n "$ELEM" ] && CHECK PASS "10. bypass_devices populated ($ELEM)" || CHECK FAIL "10. bypass_devices" "empty set"

# 11. bypass_devices spam: zero in last 60s
SPAM=$(dmesg 2>/dev/null | grep "bypass_devices empty" | tail -1 | awk '{print $2}' | tr -d '[]')
NOW=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
if [ -n "$SPAM" ] && [ "$NOW" -gt 0 ]; then
    AGE=$((NOW - SPAM))
    [ "$AGE" -gt 120 ] && CHECK PASS "11. No recent bypass_devices spam (${AGE}s ago)" || CHECK FAIL "11. bypass_devices spam" "last ${AGE}s ago"
else
    CHECK PASS "11. No bypass_devices spam"
fi

# 12. nftables: 6 tables
TABLES=$(nft list tables 2>/dev/null | grep -c "table")
[ "$TABLES" -ge 6 ] && CHECK PASS "12. nft tables ($TABLES)" || CHECK FAIL "12. nft tables" "only $TABLES"

# 13. BPF keepalive loaded
BPF=$(ls /sys/fs/bpf/surflare_* 2>/dev/null | wc -l)
[ "$BPF" -ge 2 ] && CHECK PASS "13. BPF keepalive ($BPF programs)" || CHECK FAIL "13. BPF" "only $BPF"

# 14. SmartDNS init.d fix preserved (auto_set_dnsmasq guard)
grep -q "_auto_set.*return 0" /etc/init.d/smartdns 2>/dev/null && CHECK PASS "14. SmartDNS init.d fix present" || CHECK FAIL "14. init.d fix" "guard not found"

echo ""
echo "=== Result: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ] && echo "ALL PASS" || echo "SOME FAILURES -- investigate before declaring complete"
