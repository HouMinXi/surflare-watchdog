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
	mode=${remote_path#*:}
	remote_path=${remote_path%%:*}
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
enrol "enable the boot lock at boot" \
	'/etc/init.d/surflare-bootlock enable'
enrol "record receive drops every five minutes" \
	'crontab -l 2>/dev/null | grep -q surflare_rx_watch || (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/sbin/surflare_rx_watch.sh >> /dev/null 2>&1") | crontab -'
enrol "keep the rps assert in cron every five minutes" \
	'crontab -l 2>/dev/null | grep -q surflare_rps_assert || (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/sbin/surflare_rps_assert.sh >> /dev/null 2>&1") | crontab -'
# /usr/local/sbin and /etc/config are kept wholesale by the base image, so only
# the rest needs a line.  The list is derived from installed-files.list: the
# hand-written version had five entries while the audit checked fifteen.
keep_paths=$(printf '%s\n' "$pairs" | cut -d: -f2 | grep -vE '^/usr/local/sbin/|^/etc/config/')
# /etc/surflare/ holds site configuration this tree does not carry (the MAC
# bypass list), so the directory is kept even though no file in it is installed.
keep_paths="$keep_paths /etc/surflare/"
enrol "keep the deployed files across a sysupgrade" \
	"for f in $keep_paths; do grep -qxF \"\$f\" /etc/sysupgrade.conf || echo \"\$f\" >> /etc/sysupgrade.conf; done"
enrol "warn when the site MAC list is missing" \
	'test -e /etc/surflare/bypass-macs.conf || echo "WARN: /etc/surflare/bypass-macs.conf is not on this box; restore it from your backup before using AnyConnect"'
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
# The check has to come before anything that starts a service: a box that took
# half the files is not a box to restart.
if [ "$failed" -ne 0 ]; then
	echo "RESULT: $failed steps failed out of $count files; nothing was started" >&2
	exit 1
fi
echo "RESULT: $count files installed and the services enrolled"