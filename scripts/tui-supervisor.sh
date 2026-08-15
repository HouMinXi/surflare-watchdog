#!/bin/sh
# tui-supervisor.sh -- keep the interactive surflare client alive and
# pinned to the dedicated exit.
#
# WHY THIS EXISTS: transit relays stop authorizing the dedicated
# (private) exit a few minutes after connect unless an interactive
# client session is present; without one every relay rejects with
# socks5 code=2 and the node dies inside 16 minutes (measured n=4,
# 2026-08-15). A live TUI held the same exit for hours with zero
# rejections. The renewal rides the client's own API session, which
# plain `surflare status`/`ping` calls do not provide (measured).
#
# The watchdog's reconnect path runs `killall surflare`, which kills
# this TUI; the every-minute cron here respawns it. After a watchdog
# rotation to a city node we wait GRACE_S before re-pinning so both
# sides are never reconnecting at once.
#
# Navigation expects the TUI's Chinese menu labels; if a surflare
# update changes them the pin fails, the circuit breaker idles the
# supervisor after 10 strikes and says so once.
#
# Config: /etc/surflare/dedicated.conf (see n100/config/dedicated.conf
# in this repo). Missing config or ENABLED=0 -> exit immediately, so
# letting the subscription lapse needs no code change.
#
# Cron:  * * * * * /usr/local/sbin/tui-supervisor.sh

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF=/etc/surflare/dedicated.conf
SOCK=/tmp/tui.sock
# One instance at a time: pin_dedicated spans ~25s and cron fires every
# minute; a slow TUI could otherwise let two runs overlap on SOCK/FAILS.
LOCK=/run/tui_supervisor.lock
exec 9>"$LOCK"
flock -n 9 || exit 0

STAMP=/run/tui_supervisor.stamp
FAILS=/run/tui_supervisor.fails

[ -f "$CONF" ] || exit 0
# Safe parse (same style as mode.conf in the watchdog): accept only the
# known assignments, never source the file as shell code.
_conf_get() {
	grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'"
}
ENABLED=$(_conf_get ENABLED)
DED_NODE=$(_conf_get DED_NODE)
DED_SEARCH=$(_conf_get DED_SEARCH)
GRACE_S=$(_conf_get GRACE_S)
STORM_ROT_MIN=$(_conf_get STORM_ROT_MIN)
STORM_WINDOW_S=$(_conf_get STORM_WINDOW_S)
[ "$ENABLED" = "1" ] || exit 0
[ -n "$DED_NODE" ] || exit 0
GRACE_S=${GRACE_S:-300}
DED_SEARCH=${DED_SEARCH:-65.195}
STORM_ROT_MIN=${STORM_ROT_MIN:-2}
STORM_WINDOW_S=${STORM_WINDOW_S:-600}

# Storm backoff: when the watchdog is rotating fast (relay-wide storm,
# typically Asian evening peak), re-pinning the dedicated exit only
# joins the flapping -- every node dies within minutes, ours included.
# Read the watchdog's rotation counter delta since the last run and
# skip pinning while the rate stays high. Files only, no CLI call, so
# this also works while `surflare status` is blocked mid-reconnect.
SNAP=/run/tui_supervisor.snapshot
_rot=$(grep -oE "\"rotations\":[0-9]+" /var/log/surflare/diag_state.json 2>/dev/null | grep -oE "[0-9]+" | head -1)
_now=$(date +%s)
_ts0=0; _r0=0
if [ -f "$SNAP" ]; then
	read -r _ts0 _r0 < "$SNAP" 2>/dev/null || { _ts0=0; _r0=0; }
fi
echo "$_now ${_rot:-0}" > "$SNAP"
if [ -n "$_rot" ] && [ -n "$_r0" ] && [ "$_r0" != "0" ] \
	&& [ $(( _rot - _r0 )) -ge "$STORM_ROT_MIN" ] \
	&& [ $(( _now - _ts0 )) -le "$STORM_WINDOW_S" ]; then
	exit 0
fi

# Navigate a fresh TUI to the dedicated node via the server-list search
# box: open server selection, type the search text (list filters to the
# node), move past the two fixed list header rows onto the first result,
# select it. Selecting a server connects immediately.
pin_dedicated() {
	sexpect -s "$SOCK" kill 2>/dev/null
	rm -f "$SOCK"
	pkill -x surflare 2>/dev/null
	sleep 1
	sexpect -s "$SOCK" spawn -nohup -T xterm surflare >/dev/null 2>&1 || return 1
	sleep 6
	sexpect -s "$SOCK" expect -t 10 "服务器" >/dev/null 2>&1 || return 1
	sexpect -s "$SOCK" send -cr
	sleep 2
	sexpect -s "$SOCK" expect -t 5 "搜索" >/dev/null 2>&1 || return 1
	sexpect -s "$SOCK" send "$DED_SEARCH"
	sleep 2
	sexpect -s "$SOCK" send -c "\x1b[B"
	sleep 1
	sexpect -s "$SOCK" send -c "\x1b[B"
	sleep 1
	sexpect -s "$SOCK" send -cr
	sleep 12
	# -F: the node tag contains dots and parens, not a regex
	surflare status 2>/dev/null | grep -Fq "$DED_NODE"
}

note() { logger -t tui-supervisor "$1"; }

# `local` is fine here: this script runs on iStoreOS where /bin/sh is
# busybox ash, which supports it (verified by sh -x trace).
# shellcheck disable=SC3043  # local is supported by busybox ash
fail_count() { local c; c=$(cat "$FAILS" 2>/dev/null); echo "${c:-0}"; }
bump_fail() {
	# shellcheck disable=SC3043  # local is supported by busybox ash
	local n
	n=$(( $(fail_count) + 1 ))
	echo "$n" > "$FAILS"
	# Log the trip exactly once, at the moment the count reaches 10.
	[ "$n" -eq 10 ] && note "pin failed 10x consecutively, going idle (check DED_NODE/subscription)"
}
clear_fail() { rm -f "$FAILS"; }

# Circuit breaker: after 10 consecutive failed pins (node retired,
# catalog changed, TUI layout changed) stop touching the system; log
# the trip once (count exactly 10), stay silent on later runs. A
# healthy state (dedicated + live TUI) or a successful pin resets it.
# Slow retry: after an hour idle the counter is cleared, so a renewed
# subscription or recovered catalog is picked up without manual
# intervention (the FAILS mtime freezes at the 10th failure).
_n=$(fail_count)
if [ "$_n" -ge 10 ]; then
	_age=0
	[ -f "$FAILS" ] && _age=$(( $(date +%s) - $(stat -c %Y "$FAILS") ))
	if [ "$_age" -ge 3600 ]; then
		rm -f "$FAILS"
		note "circuit breaker retry after 1h idle"
	else
		exit 0
	fi
fi

srv=$(surflare status 2>/dev/null | grep "Server:" | head -1 | sed "s/.*Server: *//;s/ *\$//")

if [ "$srv" = "$DED_NODE" ]; then
	rm -f "$STAMP"
	if pgrep -x surflare >/dev/null; then
		clear_fail
		exit 0
	fi
	# On the dedicated node but the renewing client is gone: restore it
	# now, before the relays start rejecting again.
	if pin_dedicated; then
		clear_fail
		note "TUI respawned on dedicated"
	else
		bump_fail
		note "WARN: pin failed x$(fail_count) (on-dedicated respawn)"
	fi
	exit 0
fi

# Not on the dedicated node: grace-gate the re-pin so a watchdog city
# fallback settles first.
if [ ! -f "$STAMP" ]; then
	touch "$STAMP"
	exit 0
fi
age=$(( $(date +%s) - $(stat -c %Y "$STAMP") ))
[ "$age" -lt "$GRACE_S" ] && exit 0

if pin_dedicated; then
	clear_fail
	rm -f "$STAMP"
	note "re-pinned to dedicated after ${age}s on $srv"
else
	bump_fail
	note "WARN: pin failed x$(fail_count) (was on $srv)"
fi
