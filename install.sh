#!/bin/bash
# surflare-watchdog installer
# Supports: systemd, OpenRC, procd (OpenWrt/iStoreOS), runit
# Service files live in laptop/services/<init>/ or router/services/<init>/ and are symlinked (systemd) or
# copied (others) so that `git pull` + daemon reload is the only update step.
# NOTE: never use `systemctl disable` on symlinked units; use systemctl stop
# then rm /etc/systemd/system/<unit> manually if uninstalling.

set -eo pipefail

[ "$(id -u)" -ne 0 ] && { echo "Run as root"; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Init system detection
# ---------------------------------------------------------------------------
detect_init() {
    [ -d /run/systemd/system ]   && { echo systemd; return; }
    [ -f /etc/openwrt_release ]  && { echo procd;   return; }
    [ -x /sbin/openrc ]          && { echo openrc;  return; }
    [ -d /etc/runit ]            && { echo runit;   return; }
    # Container / unknown: attempt systemd if systemctl exists
    command -v systemctl &>/dev/null && { echo systemd; return; }
    echo unknown
}
INIT="$(detect_init)"
echo "Detected init system: $INIT"

# ---------------------------------------------------------------------------
# Install binaries
# Common scripts go to both platforms; platform-specific only on their target.
# ---------------------------------------------------------------------------
install -m 755 "$REPO/surflare_watchdog.sh"       /usr/local/sbin/surflare_watchdog.sh
install -m 755 "$REPO/surflare_l4_probe.sh"       /usr/local/sbin/surflare_l4_probe.sh
install -m 755 "$REPO/surflare_log_health.sh"     /usr/local/sbin/surflare_log_health.sh
install -m 755 "$REPO/surflare-update.sh"         /usr/local/sbin/surflare-update.sh
install -m 755 "$REPO/cross_validate_routes.py"   /usr/local/sbin/cross_validate_routes.py
install -m 755 "$REPO/setup_auth.sh"              /usr/local/sbin/setup_auth.sh

if [ "$INIT" = "procd" ]; then
    # Router (N100/iStoreOS) -- LAN tproxy nft rule + required packages
    install -m 644 "$REPO/router/surflare-lan-tproxy.nft" /etc/surflare-lan-tproxy.nft
    echo "  LAN tproxy rule installed -> /etc/surflare-lan-tproxy.nft"
    # Guard: remove stale tproxy file from nftables.d if present.
    # fw4 includes all files in /etc/nftables.d/ as fragments; a standalone
    # table definition there breaks fw4 load and leaves the router without
    # firewall after reboot.
    if [ -f /etc/nftables.d/surflare-lan-tproxy.nft ]; then
        rm -f /etc/nftables.d/surflare-lan-tproxy.nft
        echo "  WARN: removed stale /etc/nftables.d/surflare-lan-tproxy.nft (breaks fw4)"
    fi
    mkdir -p /etc/surflare
    if [ ! -f /etc/surflare/bypass-macs.conf ]; then
        install -m 600 "$REPO/router/bypass-macs.conf.example" /etc/surflare/bypass-macs.conf
        echo "  bypass-macs.conf created -> /etc/surflare/bypass-macs.conf (edit to add devices)"
    else
        echo "  bypass-macs.conf already exists, not overwritten"
    fi
    echo "  Installing required router packages..."
    opkg update -q 2>/dev/null || true
    # Required: fill busybox gaps used by the watchdog script.
    # Without these, the listed features silently fail or produce wrong output:
    #   coreutils-paste   -- paste -sd, -  (CN bypass CIDR list join)
    #   coreutils-grep    -- grep -oP      (nft handle extraction, IRQ parsing)
    #   coreutils-sleep   -- sleep 0.1     (tcpdump readiness poll)
    #   coreutils-date    -- date +%-H     (session event log hour field)
    #   coreutils-nproc   -- nproc --all   (CPU affinity calculation)
    #   procps-ng-pkill   -- pkill -f      (node probe session cleanup)
    #   ss                -- ss -tnp       (VPN server IP extraction)
    #   coreutils-timeout -- timeout N cmd (auth / connect timeouts)
    #   conntrack         -- conntrack -F  (flush stale connections after killswitch)
    #   kmod-nft-tproxy   -- LAN tproxy kernel module
    #   kmod-nfnetlink-log -- nflog for packet trace (log ... group N)
    #   sexpect           -- PTY-based login (password not in /proc cmdline)
    install -m 755 "$REPO/router/surflare_route_updater.sh" \
        /usr/local/sbin/surflare_route_updater.sh
    install -m 755 "$REPO/cross_validate_cloud_cdn.py" \
        /usr/local/sbin/cross_validate_cloud_cdn.py
    opkg install \
        coreutils-paste coreutils-grep coreutils-sleep coreutils-date \
        coreutils-nproc procps-ng-pkill \
        ss coreutils-timeout conntrack kmod-nft-tproxy \
        kmod-nfnetlink-log sexpect \
        logrotate 2>/dev/null || true
    # F0: verify conntrack and scoped flush syntax (needed for killswitch install
    # to flush only tproxy-marked flows instead of ALL flows).  conntrack <1.4.4
    # lacks the -m filter; we fall back to `conntrack -F` in that case, but warn.
    # We probe via `conntrack -h` (side-effect free) rather than a real
    # `conntrack -D -m 0` flush, which would drop all mark=0 traffic on a live
    # router (most LAN TCP) at install time.
    if ! command -v conntrack >/dev/null 2>&1; then
        echo "WARN: conntrack not installed; watchdog will log flush errors at runtime" >&2
    elif ! conntrack -h 2>&1 | grep -q -- ' -m '; then
        echo "INFO: conntrack lacks -m filter (likely <1.4.4); watchdog will use unscoped conntrack -F" >&2
    fi
else
    # Laptop (Fedora/RHEL/systemd) -- additional diagnostic tools
    install -m 755 "$REPO/laptop/surflare_early_detector.sh" /usr/local/sbin/surflare_early_detector.sh
    install -m 755 "$REPO/laptop/surflare_node_probe.sh"     /usr/local/sbin/surflare_node_probe.sh
    install -m 755 "$REPO/laptop/surflare_route_updater.sh"  /usr/local/sbin/surflare_route_updater.sh
    # Cloud CDN validator: required by surflare_route_updater.sh for extra bypass CIDRs
    install -m 755 "$REPO/cross_validate_cloud_cdn.py" \
        /usr/local/sbin/cross_validate_cloud_cdn.py
fi

# F12: install logrotate config. N100 iStoreOS bundles logrotate
# (3.22.0-r1) but some OpenWrt variants use logd/logread only. Gate the
# install on the binary being present to avoid orphan config files
# (which logrotate would never read anyway). On N100 this branch
# was not hit because watchdog died at 22:42:24 before install.sh
# reached this line -- observed 2026-06-17.
if [ -d /etc/logrotate.d ] && command -v logrotate >/dev/null 2>&1; then
    install -m 644 "$REPO/etc/logrotate.d/surflare-watchdog" \
        /etc/logrotate.d/surflare-watchdog
    echo "OK: logrotate config installed (event log rotation 10M/5)"
else
    echo "WARN: logrotate not available; EVENT_LOG will grow unbounded unless rotated manually"
fi

mkdir -p /usr/local/share/surflare/routes
cp "$REPO/routes/cn_ipv4.txt" /usr/local/share/surflare/routes/
cp "$REPO/routes/cn_ipv6.txt" /usr/local/share/surflare/routes/

# ---------------------------------------------------------------------------
# Service installation (symlink for systemd; cp+chmod for others)
# ---------------------------------------------------------------------------
SVC_LAPTOP="$REPO/laptop/services"
SVC_ROUTER="$REPO/router/services"

case "$INIT" in
systemd)
    SD=/etc/systemd/system
    # Copy unit files (systemd does not reliably follow symlinks to home dirs).
    # To update after git pull: re-run install.sh or:
    #   sudo cp laptop/services/systemd/*.{service,timer} /etc/systemd/system/
    #   sudo systemctl daemon-reload && sudo systemctl restart surflare-watchdog
    for unit in surflare-watchdog.service \
                surflare-early-detector.service \
                surflare-route-updater.service \
                surflare-route-updater.timer \
                surflare-update.service \
                surflare-update.timer; do
        cp "$SVC_LAPTOP/systemd/$unit" "$SD/$unit"
    done
    # Sleep resume hook
    ln -sf /usr/local/sbin/surflare_watchdog.sh /etc/systemd/system-sleep/surflare-resume.sh
    systemctl daemon-reload
    systemctl enable surflare-watchdog.service
    systemctl enable surflare-early-detector.service
    systemctl enable --now surflare-route-updater.timer
    systemctl enable --now surflare-update.timer
    ;;

openrc)
    for svc in surflare-watchdog surflare-early-detector; do
        cp "$SVC_LAPTOP/openrc/$svc" /etc/init.d/
        chmod 755 "/etc/init.d/$svc"
        rc-update add "$svc" default || true
    done
    ;;

procd)
    # Router has only watchdog (no early-detector: nm-online not available on OpenWrt)
    cp "$SVC_ROUTER/procd/surflare-watchdog" /etc/init.d/surflare-watchdog
    chmod 755 /etc/init.d/surflare-watchdog
    /etc/init.d/surflare-watchdog enable || true
    # iStoreOS/OpenWrt: enable may not create /etc/rc.d symlink (tmpfs quirk).
    # Idempotent fallback ensures boot-time autostart on those images.
    test -L /etc/rc.d/S95surflare-watchdog || \
        ln -sf /etc/init.d/surflare-watchdog /etc/rc.d/S95surflare-watchdog
    # Boot-time lockdown (S18, before S19firewall/S20network)
    cp "$SVC_ROUTER/procd/surflare-bootlock" /etc/init.d/surflare-bootlock
    chmod 755 /etc/init.d/surflare-bootlock
    /etc/init.d/surflare-bootlock enable || true
    test -L /etc/rc.d/S18surflare-bootlock || \
        ln -sf /etc/init.d/surflare-bootlock /etc/rc.d/S18surflare-bootlock
    ;;

runit)
    for svc in surflare-watchdog surflare-early-detector; do
        cp -r "$SVC_LAPTOP/runit/$svc" /etc/sv/
        ln -sf "/etc/sv/$svc" /service/ || true
    done
    ;;

*)
    echo "WARN: unknown init system; copy service files from services/ manually"
    ;;
esac

# ---------------------------------------------------------------------------
# Node probe: 4am daily (L7 full-probe; accepts ~5min VPN disruption)
# ---------------------------------------------------------------------------
# Every 3 min: parse surflare-proxy log for real-time node health (zero VPN disruption)
LOG_HEALTH_CRON="*/3 * * * * /usr/local/sbin/surflare_log_health.sh >> /dev/null 2>&1"
# Daily 02:30: update CN IP routes (chnroutes2 BGP + cloud CDN APAC extra).
# Source frequencies: chnroutes2=daily, cloud-ip-ranges=daily, RIPE=realtime.
# Run at 02:30 to avoid collision with update-cn-domains at 03:00 Mon.
_rucron="/usr/local/sbin/surflare_route_updater.sh"
ROUTE_UPDATE_CRON="30 2 * * * $_rucron >> /dev/null 2>&1"
# Daily 04:30: run logrotate. /etc/logrotate.d/surflare-watchdog only fires
# when logrotate is actually invoked -- on N100 the binary is present
# (3.22.0-r1) but no cron trigger ran before this fix, so /var/log/surflare-proxy.log
# grew to 14MB (observed 2026-06-18). 04:30 avoids the 02:30 and 03:00 windows
# and runs before the 3-min health cron.
LOGROTATE_CRON="30 4 * * * /usr/sbin/logrotate /etc/logrotate.conf >> /var/log/logrotate.log 2>&1"
# Dead-man's switch (procd only): remove orphan killswitch if watchdog is
# not running.  Laptop/systemd does not use persistent killswitch and has
# no /etc/init.d/surflare-watchdog, so skip the cron to avoid errors.
if [ "$INIT" = "procd" ]; then
    DEADMAN_CRON="* * * * * /etc/init.d/surflare-watchdog deadman"
else
    DEADMAN_CRON=""
fi
( crontab -l 2>/dev/null \
    | grep -v surflare_node_probe | grep -v surflare_l4_probe \
    | grep -v surflare_log_health | grep -v surflare_route_updater \
    | grep -v 'logrotate /etc/logrotate.conf' \
    | grep -v 'surflare-watchdog deadman'
  echo "$LOG_HEALTH_CRON"
  echo "$ROUTE_UPDATE_CRON"
  echo "$LOGROTATE_CRON"
  if [ -n "$DEADMAN_CRON" ]; then echo "$DEADMAN_CRON"; fi ) | crontab -
# Note: surflare_node_probe.sh is available as a manual diagnostic tool only.

echo ""
echo "Installation complete."
echo "  Start watchdog : systemctl start surflare-watchdog  (or service equivalent)"
echo "  Update workflow: git pull && sudo cp laptop/services/systemd/*.{service,timer} /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl restart surflare-watchdog"
