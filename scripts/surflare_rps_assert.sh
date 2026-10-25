#!/bin/sh
# Keep the WAN receive queue spread across cpu1-3.
#
# Why this is not just the hotplug hook: that hook fires when the interface
# appears, and nothing fires when the queues are rebuilt underneath it.  On
# 2026-10-25 the router was found with rps_cpus back at 0 while the hook's own
# log line still said it had been set to e -- eth0 had seen twelve carrier
# changes, and every one of them was a chance for the setting to be lost
# silently.  A single-core router with a healthy-looking log is the kind of
# state that is only noticed when someone asks why the line is slow.
#
# Idempotent on purpose: it writes only when the value differs, so running it
# every few minutes costs one read.
#
# Rollback: remove the cron entry, then
#   echo 0 > /sys/class/net/eth0/queues/rx-0/rps_cpus
set -u

QUEUE="${QUEUE:-/sys/class/net/eth0/queues/rx-0/rps_cpus}"
WANT="${WANT:-e}"

[ -e "$QUEUE" ] || exit 0

cur=$(cat "$QUEUE" 2>/dev/null) || exit 0
[ "$cur" = "$WANT" ] && exit 0

if echo "$WANT" > "$QUEUE" 2>/dev/null; then
	[ -n "${QUIET:-}" ] || logger -t rps-wan \
		"re-asserted $(printf '%s' "$QUEUE" | sed 's|/sys/class/net/||;s|/queues/.*||') receive spread (was ${cur:-unreadable})"
	exit 0
fi
[ -n "${QUIET:-}" ] || logger -t rps-wan "WARN: could not set $QUEUE"
exit 1
