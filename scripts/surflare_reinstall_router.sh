#!/bin/sh
# shellcheck disable=SC2016  # command strings are expanded on the remote host
# Rebuild the router from this tree.
#
# A reboot keeps the box. A minor sysupgrade keeps what /etc/sysupgrade.conf
# names. A major version jump is usually flashed clean, and then every file
# this repository owns has to be put back by hand -- fourteen of them, plus
# their modes, the cron entries and the init scripts that must be enabled.
# That knowledge used to live in whatever the last person remembered.
#
# This reads the same scripts/installed-files.list the drift and upgrade checks
# read, so the three tools can never disagree about what this repository owns.
#
# Usage: surflare_reinstall_router.sh [--remote HOST] [--mode rule|global] [--dry-run] [--no-restart]
# Exit: 0 every file landed, 1 something failed, 2 bad arguments or missing list.
set -u

REMOTE="${REMOTE:-root@192.168.100.1}"
MODE="${MODE:-rule}"
SCP_CMD="${SCP_CMD:-scp}"
SSH_CMD="${SSH_CMD:-ssh}"
DRY_RUN=""
RESTART=1

while [ $# -gt 0 ]; do
	case "$1" in
	--remote) REMOTE="$2"; shift 2 ;;
	--mode) MODE="$2"; shift 2 ;;
	--dry-run) DRY_RUN=1; shift ;;
	--no-restart) RESTART=""; shift ;;
	*) echo "usage: $0 [--remote HOST] [--mode rule|global] [--dry-run] [--no-restart]" >&2; exit 2 ;;
	esac
done

REPO=$(cd "$(dirname "$0")/.." && pwd)
LIST="$REPO/scripts/installed-files.list"
[ -f "$LIST" ] || { echo "FATAL: $LIST missing" >&2; exit 2; }

cd "$REPO" || exit 2

pairs=$(grep -v '^#' "$LIST" | grep -v '^$' | sed "s|@MODE@|$MODE|")

# A sysctl drop-in is data; everything else this tree installs is executable.
mode_for() {
	case "$1" in
	/etc/sysctl.d/*) echo 644 ;;
	*) echo 755 ;;
	esac
}

PAIRFILE=$(mktemp) || exit 2
trap 'rm -f "$PAIRFILE"' EXIT INT TERM
failed=0
count=0
# The list goes through a file, not a pipe: a loop on the right of a pipe runs
# in a subshell and every count it increments is discarded.
printf '%s\n' "$pairs" > "$PAIRFILE"
while IFS= read -r p; do
	local_path=${p%%:*}
	remote_path=${p#*:}
	mode=$(mode_for "$remote_path")
	count=$((count + 1))
	if [ ! -f "$local_path" ]; then
		echo "MISSING IN TREE: $local_path" >&2
		failed=$((failed + 1))
		continue
	fi
	if [ -n "$DRY_RUN" ]; then
		echo "would install $local_path -> $remote_path ($mode)"
		continue
	fi
	if ! $SCP_CMD -q "$local_path" "$REMOTE:$remote_path" >/dev/null 2>&1; then
		echo "FAILED: $local_path -> $remote_path" >&2
		failed=$((failed + 1))
	fi
	$SSH_CMD -n "$REMOTE" "chmod $mode '$remote_path'" >/dev/null 2>&1 || \
		{ echo "FAILED: chmod $remote_path" >&2; failed=$((failed + 1)); }
done < "$PAIRFILE"

# The services and cron lines are part of the install: a file in place but not
# enabled is the state this box was in for months with a stale updater.
enrol() {
	[ -n "$DRY_RUN" ] && { echo "would $1"; return 0; }
	$SSH_CMD -n "$REMOTE" "$2" >/dev/null 2>&1 || { echo "FAILED: $1" >&2; failed=$((failed + 1)); }
}

enrol "enable surflare-watchdog at boot" \
	'/etc/init.d/surflare-watchdog enable'
enrol "enable the receive-spread assert at boot" \
	'/etc/init.d/surflare-rps-assert enable'
enrol "keep the rps assert in cron every five minutes" \
	'crontab -l 2>/dev/null | grep -q surflare_rps_assert || (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/sbin/surflare_rps_assert.sh >> /dev/null 2>&1") | crontab -'
enrol "keep the deployed files across a sysupgrade" \
	'for f in /etc/init.d/surflare-rps-assert /etc/hotplug.d/net/30-rps-wan-eth0 /etc/sysctl.d/13-netdev-backlog.conf /etc/surflare-lan-tproxy.nft /etc/surflare/; do grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf; done'
enrol "apply the backlog setting now" \
	'sysctl -p /etc/sysctl.d/13-netdev-backlog.conf'
enrol "assert the receive spread now" \
	'/usr/local/sbin/surflare_rps_assert.sh || true'

if [ -n "$RESTART" ]; then
	enrol "restart the watchdog (it adopts a running proxy)" \
		'/etc/init.d/surflare-watchdog restart'
fi

if [ -n "$DRY_RUN" ]; then
	echo "RESULT: dry run, $count files would be installed"
	exit 0
fi
if [ "$failed" -ne 0 ]; then
	echo "RESULT: $failed steps failed out of $count files" >&2
	exit 1
fi
echo "RESULT: $count files installed and the services enrolled"