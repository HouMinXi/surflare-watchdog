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
TUI_LOG=/tmp/tui_supervisor_tui.log
# One instance at a time: pin_dedicated spans up to ~55s in the worst
# case (6s spawn + 12s x expect gates + 40 steps x 0.6s + settle +
# 12s connect) and cron fires every
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
GRACE_S=$(_conf_get GRACE_S)
STORM_ROT_MIN=$(_conf_get STORM_ROT_MIN)
STORM_WINDOW_S=$(_conf_get STORM_WINDOW_S)
[ "$ENABLED" = "1" ] || exit 0
[ -n "$DED_NODE" ] || exit 0
GRACE_S=${GRACE_S:-300}
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

# Navigate a fresh TUI to the dedicated node by reading the screen:
# open server selection, then step the cursor down one row at a time,
# re-reading the captured pty log after each step, until the cursor
# marker (▸) sits on the row containing DED_NODE (the paren form
# "Name(ip)" -- the search-key/verify-key split used a looser substring
# that could match a sibling dedicated node; one key kills that whole
# ambiguity class). Selecting a row connects immediately.
#
# WHY NOT THE SEARCH BOX: surflare v4.3.1's server-list search field
# only accepts mouse focus -- typing into it via the pty does nothing
# (measured 2026-09-26: placeholder stays, list never filters). The old
# search-filter-then-arrow assumption landed the cursor on the first
# dedicated row, which is whichever IP surflare happens to list first,
# Screen-stepping is list-order independent: retired IPs that
# drop off the list just shift the row count and the loop re-finds
# the target row.
# WHY THE LOGFILE, NOT expect_out: the TUI redraws only the rows that
# change, so an expect on the page title times out once the title
# scrolls out of the lookback window and expect_out comes back empty
# (measured). The spawn logfile is cumulative: the last line carrying
# the cursor marker is always the current cursor row.
_cursor_row() {
	grep "▸" "$TUI_LOG" 2>/dev/null | tail -1
}

pin_dedicated() {
	# Tell the watchdog this gap is a pin, not a lost tunnel.  The
	# watchdog holds the exit while the file is in the future and
	# resumes normal recovery once it expires.  90s covers one pin
	# (measured worst case ~55s) without masking a pin that dies.
	# Every failure path must drop the marker: the process is already
	# dead, and a marker left behind hides the next real outage.
	date -d "+90 seconds" +%s > "${SURFLARE_DED_PIN_FILE:-/run/surflare_ded_pin_until}" 2>/dev/null || \
		echo $(( $(date +%s) + 90 )) > "${SURFLARE_DED_PIN_FILE:-/run/surflare_ded_pin_until}"
	# pin_abort's own return only leaves pin_abort.  Callers must
	# follow it with "|| return" (and a break inside the loop) or the
	# walk continues and sends Enter after the process is already dead.
	pin_abort() { rm -f "${SURFLARE_DED_PIN_FILE:-/run/surflare_ded_pin_until}"; return 1; }
	sexpect -s "$SOCK" kill 2>/dev/null
	sleep 1
	# kill terminates the child but leaves sexpect's daemon bound to
	# $SOCK; unlinking the socket below orphans it (with unreaped
	# zombie children).  Sweep daemons for this socket first so a
	# long-lived router does not stack one pair per pin attempt
	# (measured 2026-10-18: six stacked daemons after a reboot loop).
	# ERE-escape the socket path: a dot inside it is a metacharacter
	# and would match foreign sockets (e.g. /tmp/tui-sockX).
	_sock_re=$(printf '%s' "$SOCK" | sed 's/[^a-zA-Z0-9_/-]/\\&/g')
	pkill -f "sexpect -s $_sock_re( |$)" 2>/dev/null
	rm -f "$SOCK" "$TUI_LOG"
	pkill -x surflare 2>/dev/null
	sleep 1
	sexpect -s "$SOCK" spawn -nohup -T xterm -logf "$TUI_LOG" surflare >/dev/null 2>&1 || { pin_abort || return; }
	sleep 6
	# A client reset (or a fresh install) opens the TUI on the language
	# picker instead of the main menu -- measured after the 2026-10-18
	# reboot: every pin timed out on the gate below while the TUI sat
	# on "Select Language".  Pick Chinese (the menu labels this script
	# navigates are Chinese), then re-apply the main-menu gate.
	if ! sexpect -s "$SOCK" expect -t 8 "服务器" >/dev/null 2>&1; then
		sexpect -s "$SOCK" expect -t 6 "选择语言" >/dev/null 2>&1 || { pin_abort || return; }
		# The picker cursor starts on English (row 1) and Chinese is row
		# 5, so it takes 4 down keys; the loop must run 5 check-first
		# iterations or the row-5 check never happens (the 4-iteration
		# version pressed the 4th down and exited without looking -- all
		# pins through the picker path aborted).  One down key per send
		# with a highlighted-row check before each step: a single burst
		# of four escapes registered only one on the 2026-10-18 picker
		# and the Enter after it saved Deutsch, a language no gate in
		# this script can read.  Enter is pressed only when the cursor
		# provably sits on Chinese.
		_picker_ok=0
		_k=0
		while [ "$_k" -lt 6 ]; do
			# 2000 bytes: the pty log is cumulative and the picker screen
			# is a full redraw; 400 cut the highlight row on taller renders.
			if tail -c 2000 "$TUI_LOG" 2>/dev/null | grep -q "▸ 中文"; then
				_picker_ok=1
				break
			fi
			sexpect -s "$SOCK" send -c "\x1b[B" >/dev/null 2>&1
			sleep 1
			_k=$((_k + 1))
		done
		[ "$_picker_ok" = "1" ] || { pin_abort || return; }
		sexpect -s "$SOCK" send -cr >/dev/null 2>&1
		sleep 3
		sexpect -s "$SOCK" expect -t 10 "服务器" >/dev/null 2>&1 || { pin_abort || return; }
	fi
	sexpect -s "$SOCK" send -cr
	sleep 2
	sexpect -s "$SOCK" expect -t 5 "选择服务器" >/dev/null 2>&1 || { pin_abort || return; }

	# Step the cursor down, re-reading the cursor row after each
	# keypress, until it sits on the target row. The cursor starts on
	# the first list row ("← 返回"); MAX_STEPS bounds the walk so a
	# missing/renamed node cannot loop forever (the list is long; the
	# dedicated section is always near the top).
	# shellcheck disable=SC3043  # local is supported by busybox ash
	local steps=0 row
	# shellcheck disable=SC3043
	local MAX_STEPS=40
	while :; do
		row=$(_cursor_row)
		case "$row" in
			*"$DED_NODE"*) break ;;
		esac
		[ "$steps" -ge "$MAX_STEPS" ] && { pin_abort || return; }
		sexpect -s "$SOCK" send -c "\x1b[B"
		steps=$((steps + 1))
		sleep 0.6
	done
	# Redraw lag: the cursor row seen at the break may be a stale frame
	# from before the last keypress (the TUI redraws only changed rows).
	# Re-read once after a settle delay and require the match to hold;
	# otherwise we would Enter the neighbor row. Fail (the next cron
	# minute retries fresh) rather than connect blind.
	sleep 1
	case "$(_cursor_row)" in
		*"$DED_NODE"*) ;;
		*) pin_abort || return ;;
	esac

	sexpect -s "$SOCK" send -cr
	sleep 12
	# -F: the node tag contains dots and parens, not a regex
	surflare status 2>/dev/null | grep -Fq "$DED_NODE" || { pin_abort || return; }
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

# Substring, not equality: the status line renders the node with an
# operator suffix ("United States(12.104.12.149)AT&T") while DED_NODE
# carries only the "Name(ip)" form, so an exact match never fires and a
# healthy dedicated session would be re-pinned every GRACE_S window.
case "$srv" in
	*"$DED_NODE"*) srv_is_dedicated=1 ;;
	*) srv_is_dedicated=0 ;;
esac

if [ "$srv_is_dedicated" = "1" ]; then
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
