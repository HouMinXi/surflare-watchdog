#!/bin/sh
# Would a firmware upgrade keep the files this repository depends on?
#
# A reboot keeps everything. A sysupgrade keeps only what /etc/sysupgrade.conf
# and /lib/upgrade/keep.d/* name, and on 2026-10-25 three things this tree had
# just deployed were on neither list -- the init script, the hotplug hook and
# the sysctl drop-in. They had been verified to survive a reboot, which is not
# the same question. An upgrade would have taken them quietly.
#
# Reads the same scripts/installed-files.list the drift check reads, so a newly
# installed file cannot be forgotten by one tool while the other still checks
# it.
#
# Usage: surflare_upgrade_audit.sh [--remote HOST] [--mode rule|global]
# Exit: 0 everything is kept, 1 something would be lost, 2 could not ask.
set -u

REMOTE="${REMOTE:-root@192.168.100.1}"
MODE="${MODE:-rule}"
SSH_CMD="${SSH_CMD:-ssh}"
KEEP_CMD="${KEEP_CMD:-cat /etc/sysupgrade.conf /lib/upgrade/keep.d/* 2>/dev/null}"

while [ $# -gt 0 ]; do
	case "$1" in
	--remote) REMOTE="$2"; shift 2 ;;
	--mode) MODE="$2"; shift 2 ;;
	*) echo "usage: $0 [--remote HOST] [--mode rule|global]" >&2; exit 2 ;;
	esac
done

REPO=$(cd "$(dirname "$0")/.." && pwd)
LIST="$REPO/scripts/installed-files.list"
[ -f "$LIST" ] || { echo "FATAL: $LIST missing" >&2; exit 2; }

TMP=$(mktemp -d)
TMPLIST="$TMP/pairs"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC2086  # a fixed command line, not user input
$SSH_CMD -n "$REMOTE" "$KEEP_CMD" > "$TMP/keep" 2>/dev/null || true
if [ ! -s "$TMP/keep" ]; then
	echo "FATAL: could not read the keep rules from $REMOTE" >&2
	exit 2
fi
grep -v '^[[:space:]]*#' "$TMP/keep" | grep -v '^[[:space:]]*$' | sed 's/[[:space:]]*$//' > "$TMP/keep.clean"

covered() {
	_p=$1
	while IFS= read -r _e; do
		case "$_e" in
		*/)
			case "$_p" in "$_e"*) return 0 ;; esac
			;;
		*)
			[ "$_p" = "$_e" ] && return 0
			case "$_p" in "$_e"/*) return 0 ;; esac
			;;
		esac
	done < "$TMP/keep.clean"
	return 1
}

lost=0
kept=0
grep -v '^#' "$LIST" | grep -v '^$' | sed "s|@MODE@|$MODE|" > "$TMPLIST" || true
while IFS= read -r p; do
	remote_path=${p#*:}
	if covered "$remote_path"; then
		printf '%-46s %s\n' "$remote_path" kept
		kept=$((kept + 1))
	else
		printf '%-46s %s\n' "$remote_path" "WOULD-BE-LOST"
		lost=$((lost + 1))
	fi
done < "$TMPLIST"

if [ "$lost" -eq 0 ]; then
	echo "RESULT: an upgrade would keep all $kept files"
	exit 0
fi
echo "RESULT: $lost of $((lost + kept)) files would be lost; add them to /etc/sysupgrade.conf"
exit 1
