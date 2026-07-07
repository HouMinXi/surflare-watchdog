#!/usr/bin/env bash
# Deploy surflare_watchdog.sh to N100 router with syntax check, backup,
# user gate, and auto-rollback on crash.
#
# Runs from the developer machine (Z66 or Mac), NOT on N100.
# Scope: watchdog script only.  Init.d scripts, helper scripts, and
# tproxy nft files deploy via manual scp.
# bypass-macs.conf is NOT deployed -- scp single-file; N100 version
# is authoritative (contains real MACs, repo has sanitized fakes).

set -euo pipefail

N100="root@192.168.100.1"
REMOTE_WATCHDOG="/usr/local/sbin/surflare_watchdog.sh"
DEPLOY_WAIT=30
LOCAL_WATCHDOG="${1:-surflare_watchdog.sh}"

if [ ! -f "$LOCAL_WATCHDOG" ]; then
    echo "FATAL: $LOCAL_WATCHDOG not found"
    exit 1
fi

# Step 1: Local syntax check
echo "Validating syntax..."
if ! bash -n "$LOCAL_WATCHDOG"; then
    echo "FATAL: syntax check failed, aborting deploy"
    exit 1
fi
echo "Syntax OK"

# Step 2: Deploy to N100
echo "Deploying to N100..."
if ! scp "$LOCAL_WATCHDOG" "${N100}:${REMOTE_WATCHDOG}.new"; then
    echo "FATAL: scp failed"
    exit 1
fi

# Backup current version, then atomic replace
# shellcheck disable=SC2087
ssh "$N100" <<DEPLOY
if [ -f "$REMOTE_WATCHDOG" ]; then
    cp "$REMOTE_WATCHDOG" "${REMOTE_WATCHDOG}.prev"
else
    echo "WARN: first deploy, no .prev backup available"
fi
mv "${REMOTE_WATCHDOG}.new" "$REMOTE_WATCHDOG"
chmod +x "$REMOTE_WATCHDOG"
DEPLOY

echo "Deployed.  Showing diff (first 50 lines):"
ssh "$N100" "diff '${REMOTE_WATCHDOG}.prev' '$REMOTE_WATCHDOG' 2>/dev/null | head -50" || true

# Step 3: User gate (local prompt)
read -r -p "Restart watchdog on N100? [y/N] " _confirm
if [ "${_confirm,,}" != "y" ]; then
    echo "Aborted by user."
    if ssh "$N100" "test -f '${REMOTE_WATCHDOG}.prev'"; then
        echo "Rolling back to .prev..."
        ssh "$N100" "mv '${REMOTE_WATCHDOG}.prev' '$REMOTE_WATCHDOG'"
    fi
    exit 0
fi

# Step 4: Restart and monitor
echo "Restarting watchdog..."
ssh "$N100" "/etc/init.d/surflare-watchdog restart"
echo "Waiting ${DEPLOY_WAIT}s for crash check..."
sleep "$DEPLOY_WAIT"

# Crash check via PID file (not pgrep -- avoids ssh shell self-match)
if ssh "$N100" 'kill -0 "$(cat /run/surflare_watchdog.pid 2>/dev/null)" 2>/dev/null'; then
    echo "Deploy OK -- watchdog running (PID file verified)"
else
    echo "WARN: watchdog not running after ${DEPLOY_WAIT}s"
    if ssh "$N100" "test -f '${REMOTE_WATCHDOG}.prev'"; then
        echo "ROLLBACK: restoring .prev and restarting..."
        ssh "$N100" "mv '${REMOTE_WATCHDOG}.prev' '$REMOTE_WATCHDOG' && /etc/init.d/surflare-watchdog restart"
        exit 1
    else
        echo "FATAL: crash on first deploy, no .prev available -- manual intervention needed"
        exit 1
    fi
fi
