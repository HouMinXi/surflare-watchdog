#!/bin/sh
# Keep a record of receive drops on the WAN port.
#
# rx_missed_errors rose in three baseline windows on 2026-10-25 (+960 / +9694 /
# +17202), read zero after RPS was enabled, and then read zero again with RPS
# removed -- so the counter is intermittent and nothing that day could attribute
# it. There is no way to force the condition on demand: eth0 is the PPPoE WAN,
# and the only way to fill its ring is real downstream traffic.
#
# An unattributable counter that nobody samples stays unattributable. This
# writes a line only when something changed, into RAM, with enough context (the
# softnet drop total and the carrier-change count) for the next reader to tell
# a NIC-level drop apart from a backlog overflow. Silence means nothing has
# moved.
#
# Usage: surflare_rx_watch.sh [iface]      (cron: every 5 minutes)
set -u

IFACE="${1:-${IFACE:-eth0}}"
STATE="${STATE:-/tmp/surflare-rx-watch.state}"
LOG="${LOG:-/tmp/surflare-rx-watch.log}"
SYSFS="${SYSFS:-/sys/class/net/$IFACE}"

read_stat() { cat "$SYSFS/statistics/$1" 2>/dev/null || echo ""; }

missed=$(read_stat rx_missed_errors)
[ -n "$missed" ] || exit 0
fifo=$(read_stat rx_fifo_errors)
carrier=$(cat "$SYSFS/carrier_changes" 2>/dev/null || echo 0)
# softnet column 2 counts packets dropped because the backlog was full, which is
# the software-side counterpart of a NIC ring miss.
# /proc/net/softnet_stat prints every column in hex.  Reading it as decimal
# reported 10 where the file said 10 (16) for a quiet CPU and 41410 for a busy
# one, i.e. a number that never matched what the file actually contained.
SOFTNET="${SOFTNET:-/proc/net/softnet_stat}"
soft=$(awk '
	function hex2dec(h,   i, d, n, c) {
		n = 0; h = tolower(h)
		for (i = 1; i <= length(h); i++) {
			c = index("0123456789abcdef", substr(h, i, 1)) - 1
			if (c < 0) return n
			n = n * 16 + c
		}
		return n
	}
	{ s += hex2dec($2) }
	END { print s + 0 }
' "$SOFTNET" 2>/dev/null || echo 0)

prev=""
[ -f "$STATE" ] && prev=$(cat "$STATE" 2>/dev/null)
now="$missed $fifo $carrier $soft"
if [ "$now" = "$prev" ]; then
	exit 0
fi
printf '%s\n' "$now" > "$STATE"

# First run just records the baseline; there is no delta to report yet.
[ -n "$prev" ] || exit 0

set -f          # the state line is split on purpose; a '*' in it is data
# shellcheck disable=SC2086  # splitting is the point of the line below
set -- $prev
set +f
d_missed=$((missed - $1))
d_fifo=$((fifo - $2))
d_soft=$((soft - $4))
[ "$d_missed" -eq 0 ] && [ "$d_fifo" -eq 0 ] && [ "$d_soft" -eq 0 ] && [ "$carrier" = "$3" ] && exit 0

printf '%s iface=%s missed=+%s fifo=+%s softnet_drop=+%s carrier_changes=%s\n' \
	"$(date '+%F %T')" "$IFACE" "$d_missed" "$d_fifo" "$d_soft" "$carrier" >> "$LOG"

# RAM is finite and this runs forever; keep the last 100 events.
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
	tail -n 100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exit 0
