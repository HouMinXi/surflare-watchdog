#!/bin/sh
# Report whether the files installed on the router still match this tree.
#
# Why this exists: scripts/surflare_deploy.sh deploys the watchdog and nothing
# else, while install.sh installs nine files.  A routine deploy therefore
# leaves the init script, the updater, the route updater and the nft template
# at whatever version was there before, and nothing notices.  On 2026-10-25 the
# router was found running an updater from June while the tree had a rewrite
# from October -- four months of fixes that had never reached the box, with
# every deploy reporting success.
#
# Usage: surflare_drift_check.sh [--remote root@192.168.100.1] [--mode rule|global]
# Exit: 0 all match, 1 drift or missing file, 2 could not ask.
set -u

REMOTE="${REMOTE:-root@192.168.100.1}"
MODE="${MODE:-rule}"
SSH_CMD="${SSH_CMD:-ssh}"

while [ $# -gt 0 ]; do
	case "$1" in
	--remote) REMOTE="$2"; shift 2 ;;
	--mode) MODE="$2"; shift 2 ;;
	*) echo "usage: $0 [--remote HOST] [--mode rule|global]" >&2; exit 2 ;;
	esac
done

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 2

pairs="
surflare_watchdog.sh:/usr/local/sbin/surflare_watchdog.sh
surflare_l4_probe.sh:/usr/local/sbin/surflare_l4_probe.sh
surflare_log_health.sh:/usr/local/sbin/surflare_log_health.sh
surflare-update.sh:/usr/local/sbin/surflare-update.sh
cross_validate_routes.py:/usr/local/sbin/cross_validate_routes.py
setup_auth.sh:/usr/local/sbin/setup_auth.sh
router/services/procd/surflare-watchdog:/etc/init.d/surflare-watchdog
router/surflare_route_updater.sh:/usr/local/sbin/surflare_route_updater.sh
router/ripe_fetch.py:/usr/local/sbin/ripe_fetch.py
router/${MODE}/surflare-lan-tproxy.nft:/etc/surflare-lan-tproxy.nft
scripts/surflare_rps_assert.sh:/usr/local/sbin/surflare_rps_assert.sh
router/services/procd/surflare-rps-assert:/etc/init.d/surflare-rps-assert
"

remotes=""
for p in $pairs; do
	remotes="$remotes ${p#*:}"
done

# shellcheck disable=SC2086  # the list is built above, one path per word
remote_raw=$($SSH_CMD -n "$REMOTE" "md5sum $remotes" 2>/dev/null) || remote_raw=""
if [ -z "$remote_raw" ]; then
	echo "FATAL: could not read checksums from $REMOTE" >&2
	exit 2
fi

drift=0
missing=0
for p in $pairs; do
	local_path=${p%%:*}
	remote_path=${p#*:}
	if [ ! -f "$local_path" ]; then
		printf '%-46s %s\n' "$local_path" "ABSENT-IN-TREE"
		drift=$((drift + 1))
		continue
	fi
	local_md5=$(md5sum "$local_path" | cut -d' ' -f1)
	remote_md5=$(printf '%s\n' "$remote_raw" | awk -v f="$remote_path" '$2 == f { print $1; exit }')
	if [ -z "$remote_md5" ]; then
		printf '%-46s %s\n' "$remote_path" "MISSING-ON-BOX"
		missing=$((missing + 1))
	elif [ "$local_md5" = "$remote_md5" ]; then
		printf '%-46s %s\n' "$remote_path" "match"
	else
		printf '%-46s %s\n' "$remote_path" "DRIFT ${remote_md5} -> ${local_md5}"
		drift=$((drift + 1))
	fi
done

if [ "$drift" -eq 0 ] && [ "$missing" -eq 0 ]; then
	echo "RESULT: box matches this tree"
	exit 0
fi
echo "RESULT: $drift drifted, $missing missing"
exit 1
