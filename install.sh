#!/bin/bash
set -eo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

echo "Installing surflare-watchdog..."

# Install scripts
cp surflare_watchdog.sh /usr/local/sbin/
chmod 755 /usr/local/sbin/surflare_watchdog.sh

cp surflare_route_updater.sh /usr/local/sbin/
chmod 755 /usr/local/sbin/surflare_route_updater.sh

cp cross_validate_routes.py /usr/local/sbin/
chmod 755 /usr/local/sbin/cross_validate_routes.py

# Install baseline routes
mkdir -p /usr/local/share/surflare/routes
cp routes/cn_ipv4.txt /usr/local/share/surflare/routes/
cp routes/cn_ipv6.txt /usr/local/share/surflare/routes/

# Install systemd services and timers
cp surflare-route-updater.service /etc/systemd/system/
cp surflare-route-updater.timer /etc/systemd/system/
if [ -f surflare-update.service ]; then
    cp surflare-update.service /etc/systemd/system/
    cp surflare-update.timer /etc/systemd/system/
fi

# Resume hook
ln -sf /usr/local/sbin/surflare_watchdog.sh /etc/systemd/system-sleep/surflare-resume.sh

systemctl daemon-reload
systemctl enable --now surflare-route-updater.timer || true
if [ -f surflare-update.timer ]; then
    systemctl enable --now surflare-update.timer || true
fi

echo "Installation complete."
