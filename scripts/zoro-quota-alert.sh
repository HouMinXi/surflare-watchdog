#!/bin/bash
# zoro-quota-alert: page via ServerChan when the Zoro VPS monthly traffic
# approaches the plan quota.
#
# Threshold ladder 80/95/100 percent of QUOTA_GB. One page per ladder level
# per calendar month; at most one page per day regardless of level. A page
# counts only when ServerChan answers 200; anything else is logged and
# retried on the next run. Reads vnstat's current month for the configured
# interface.
#
# Deployment assumptions (stated, not enforced): run from root cron with a
# fixed environment; /etc/zoro/quota.conf is root:root 600; the state dir
# is created 700. The ZORO_QUOTA_* env overrides exist for the test harness
# and must not be controllable by whoever invokes the cron job.
#
# Config (/etc/zoro/quota.conf, root 600):
#   SENDKEY=...     ServerChan send key (same channel as the N100 watchdog)
#   QUOTA_GB=1000   monthly traffic quota in GB
#   IFACE=ens17     interface to measure (default ens17)
#
# Env overrides exist for the test harness only.
set -u
umask 077

CONF="${ZORO_QUOTA_CONF:-/etc/zoro/quota.conf}"
STATE="${ZORO_QUOTA_STATE_DIR:-/var/lib/zoro-quota-alert}"
LOG="${ZORO_QUOTA_LOG:-/var/log/zoro-quota-alert.log}"

if [ ! -r "$CONF" ]; then
	echo "$(date -Is) no $CONF" >>"$LOG" 2>/dev/null
	exit 0
fi
_conf_owner=$(stat -c '%u' "$CONF" 2>/dev/null)
_conf_mode=$(stat -c '%a' "$CONF" 2>/dev/null)
if [ "$(id -u)" -eq 0 ] && [ "$_conf_owner" != "0" ]; then
	echo "$(date -Is) refusing conf owner=$_conf_owner" >>"$LOG" 2>/dev/null
	exit 1
fi
if [ "${_conf_mode:-999}" -gt 600 ] 2>/dev/null; then
	echo "$(date -Is) refusing conf mode=$_conf_mode" >>"$LOG" 2>/dev/null
	exit 1
fi
# shellcheck disable=SC1090
. "$CONF"
iface="${IFACE:-ens17}"

if [ -z "${QUOTA_GB:-}" ]; then
	echo "$(date -Is) QUOTA_GB unset" >>"$LOG" 2>/dev/null
	exit 0
fi
case $QUOTA_GB in
''|*[!0-9]*) echo "$(date -Is) QUOTA_GB not numeric" >>"$LOG" 2>/dev/null; exit 1 ;;
esac
if [ "$QUOTA_GB" -eq 0 ]; then
	echo "$(date -Is) QUOTA_GB is zero" >>"$LOG" 2>/dev/null
	exit 1
fi
if [ -z "${SENDKEY:-}" ]; then
	echo "$(date -Is) SENDKEY unset" >>"$LOG" 2>/dev/null
	exit 1
fi

read -r month bytes <<EOF
$(vnstat -i "$iface" --json m 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    m = d["interfaces"][0]["traffic"].get("month") or []
    if not m:
        print("- 0")
    else:
        print("%04d-%02d %d" % (m[0]["date"]["year"], m[0]["date"]["month"], m[0]["rx"] + m[0]["tx"]))
except Exception:
    print("! 0")
')
EOF
case $month in
''|!) echo "$(date -Is) measurement pipeline broken" >>"$LOG" 2>/dev/null; exit 1 ;;
-)   echo "$(date -Is) vnstat month record missing" >>"$LOG" 2>/dev/null; exit 0 ;;
esac
case $bytes in
''|*[!0-9]*) echo "$(date -Is) measurement bytes not numeric" >>"$LOG" 2>/dev/null; exit 1 ;;
esac

used_gb=$(( bytes / 1000000000 ))
pct=$(( bytes * 100 / (QUOTA_GB * 1000000000) ))

level=0
[ "$pct" -ge 80 ] && level=80
[ "$pct" -ge 95 ] && level=95
[ "$pct" -ge 100 ] && level=100
[ "$level" -gt 0 ] || exit 0

mkdir -p "$STATE" 2>/dev/null
chmod 700 "$STATE" 2>/dev/null
if [ ! -w "$STATE" ]; then
	echo "$(date -Is) state dir $STATE not writable" >>"$LOG" 2>/dev/null
	exit 1
fi
today=$(date +%F)
sent_today="$STATE/sent-$today"
[ -e "$sent_today" ] && exit 0
stamp="$STATE/level-$month"
prev=$(cat "$stamp" 2>/dev/null || echo 0)
[ "$level" -le "$prev" ] && exit 0

title="zoro VPS traffic ${pct}% of monthly quota"
desp="${iface} ${month} total ${used_gb} GB / ${QUOTA_GB} GB (${pct}%), level ${level}"
if ! _code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
	-d "title=${title}" -d "desp=${desp}" \
	"https://sctapi.ftqq.com/${SENDKEY}.send" 2>>"$LOG"); then
	echo "$(date -Is) page failed to send level=${level}" >>"$LOG"
	exit 1
fi
if [ "$_code" != "200" ]; then
	echo "$(date -Is) page failed http_code=${_code:-none} level=${level}" >>"$LOG"
	exit 1
fi
echo " $(date -Is) level=${level} used=${used_gb}GB quota=${QUOTA_GB}GB month=${month}" >>"$LOG"
printf '%s\n' "$level" >"$stamp" || exit 1
touch "$sent_today" || exit 1
