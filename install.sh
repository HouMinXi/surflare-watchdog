#!/bin/bash
# surflare-watchdog installer
# Supports: systemd, OpenRC, procd (OpenWrt/iStoreOS), runit
# Service files live in services/<init>/ and are symlinked (systemd) or
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
# Install binaries (always copied so they work without repo present)
# ---------------------------------------------------------------------------
install -m 755 "$REPO/surflare_watchdog.sh"       /usr/local/sbin/surflare_watchdog.sh
install -m 755 "$REPO/surflare_early_detector.sh" /usr/local/sbin/surflare_early_detector.sh
install -m 755 "$REPO/surflare_node_probe.sh"     /usr/local/sbin/surflare_node_probe.sh
install -m 755 "$REPO/surflare_l4_probe.sh"      /usr/local/sbin/surflare_l4_probe.sh
install -m 755 "$REPO/surflare_log_health.sh"    /usr/local/sbin/surflare_log_health.sh
install -m 755 "$REPO/surflare_route_updater.sh"  /usr/local/sbin/surflare_route_updater.sh
install -m 755 "$REPO/surflare-update.sh"         /usr/local/sbin/surflare-update.sh
install -m 755 "$REPO/cross_validate_routes.py"   /usr/local/sbin/cross_validate_routes.py
install -m 755 "$REPO/setup_auth.sh"              /usr/local/sbin/setup_auth.sh

mkdir -p /usr/local/share/surflare/routes
cp "$REPO/routes/cn_ipv4.txt" /usr/local/share/surflare/routes/
cp "$REPO/routes/cn_ipv6.txt" /usr/local/share/surflare/routes/

# ---------------------------------------------------------------------------
# Service installation (symlink for systemd; cp+chmod for others)
# ---------------------------------------------------------------------------
SVC="$REPO/services"

case "$INIT" in
systemd)
    SD=/etc/systemd/system
    # Copy unit files (systemd does not reliably follow symlinks to home dirs).
    # To update after git pull: re-run install.sh or:
    #   sudo cp services/systemd/*.service services/systemd/*.timer /etc/systemd/system/
    #   sudo systemctl daemon-reload && sudo systemctl restart surflare-watchdog
    for unit in surflare-watchdog.service \
                surflare-early-detector.service \
                surflare-route-updater.service \
                surflare-route-updater.timer \
                surflare-update.service \
                surflare-update.timer; do
        cp "$SVC/systemd/$unit" "$SD/$unit"
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
        cp "$SVC/openrc/$svc" /etc/init.d/
        chmod 755 "/etc/init.d/$svc"
        rc-update add "$svc" default || true
    done
    ;;

procd)
    for svc in surflare-watchdog surflare-early-detector; do
        cp "$SVC/procd/$svc" /etc/init.d/
        chmod 755 "/etc/init.d/$svc"
        /etc/init.d/"$svc" enable || true
    done

    # LAN transparent proxy: install nft rule file used by _install_lan_tproxy().
    # The watchdog loads this after VPN connects so all br-lan devices are
    # transparently proxied through surflare-proxy without per-device config.
    # Requires kmod-nft-tproxy: opkg install kmod-nft-tproxy
    cp "$REPO/surflare-lan-tproxy.nft" /etc/surflare-lan-tproxy.nft
    chmod 644 /etc/surflare-lan-tproxy.nft
    echo "  LAN tproxy rule installed -> /etc/surflare-lan-tproxy.nft"
    ;;

runit)
    for svc in surflare-watchdog surflare-early-detector; do
        cp -r "$SVC/runit/$svc" /etc/sv/
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
( crontab -l 2>/dev/null | grep -v surflare_node_probe | grep -v surflare_l4_probe | grep -v surflare_log_health
  echo "$LOG_HEALTH_CRON" ) | crontab -
# Note: surflare_node_probe.sh is available as a manual diagnostic tool only.

echo ""
echo "Installation complete."
echo "  Start watchdog : systemctl start surflare-watchdog  (or service equivalent)"
echo "  Update workflow: git pull && sudo cp services/systemd/*.{service,timer} /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl restart surflare-watchdog"
