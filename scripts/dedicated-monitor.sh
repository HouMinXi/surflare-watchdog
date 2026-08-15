#!/bin/sh
# dedicated-monitor.sh -- append-only evidence sampler for the
# dedicated-exit experiment. One JSON line per run, analysis never
# rewrites the log.
#
# PRE-REGISTERED verdicts (frozen 2026-08-15, before data):
#   PASS: dedicated session >= 4h continuous AND ttfb_p50 <= 5s AND
#         curl success >= 95%;  OR dedicated >= 1h during 16-18 CST peak
#   FAIL: 3 consecutive dedicated sessions < 1h under single watchdog
#   ABORT: total egress outage > 10 min -> restore multi-candidate
#
# Cron:  */5 * * * * /usr/local/sbin/dedicated-monitor.sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=${DED_LOG:-/var/log/dedicated-experiment.jsonl}

ts=$(date +%s)
node=$(surflare status 2>/dev/null | grep "Server:" | head -1 | sed "s/.*Server: *//;s/ *\$//")
eg=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null)
m=$(curl -s -o /dev/null -w "%{http_code} %{time_starttransfer}" --max-time 12 https://ipinfo.io/json 2>/dev/null)
hcode=$(echo "$m" | awk "{print \$1}")
ttfb=$(echo "$m" | awk "{print \$2}")
d=$(cat /var/log/surflare/diag_state.json 2>/dev/null)
reconn=$(echo "$d" | jq -r ".stats.reconnects" 2>/dev/null)
rot=$(echo "$d" | jq -r ".stats.rotations" 2>/dev/null)
s503=$(echo "$d" | jq -r ".stats.503s" 2>/dev/null)
fd=$(echo "$d" | jq -r ".fd.count" 2>/dev/null)
ctp=$(echo "$d" | jq -r ".conntrack.pct" 2>/dev/null)
c2=$(grep -c "code=2" /var/log/surflare/surflare-proxy.log 2>/dev/null)
cc=$(grep -c "closed network connection" /var/log/surflare/surflare-proxy.log 2>/dev/null)
wd=$(pgrep -f "surflare_watchdog.sh" 2>/dev/null | wc -l)
ka_age=999
[ -f /run/keepalive_ran ] && ka_age=$(( $(date +%s) - $(stat -c %Y /run/keepalive_ran) ))
printf "{\"ts\":%s,\"node\":\"%s\",\"egress\":\"%s\",\"hcode\":\"%s\",\"ttfb\":\"%s\",\"reconn\":\"%s\",\"rot\":\"%s\",\"s503\":\"%s\",\"fd\":\"%s\",\"ctp\":\"%s\",\"code2\":%s,\"closedconn\":%s,\"wd\":%s,\"ka_age_s\":%s}\n" \
 "$ts" "$node" "$eg" "$hcode" "$ttfb" "$reconn" "$rot" "$s503" "$fd" "$ctp" "$c2" "$cc" "$wd" "$ka_age" >> "$LOG"
