#!/bin/bash
# surflare_route_updater.sh
# Fetches BGP and APNIC lists, cross-validates, and updates /etc/surflare/.

set -eo pipefail

V4_BGP_URL="https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt"
V6_BGP_URL="https://ispip.clang.cn/all_cn_ipv6.txt"
APNIC_URL="https://ftp.apnic.net/stats/apnic/delegated-apnic-latest"

OUT_DIR="/etc/surflare"
mkdir -p "$OUT_DIR"

log() {
    logger -t surflare-route-updater "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

TMP_DIR=$(mktemp -d /tmp/surflare_updater_XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

log "Downloading BGP route lists..."
curl -fsSL --connect-timeout 30 "$V4_BGP_URL" -o "$TMP_DIR/v4_bgp.txt" || true
curl -fsSL --connect-timeout 30 "$V6_BGP_URL" -o "$TMP_DIR/v6_bgp.txt" || true

log "Downloading APNIC delegated stats..."
curl -fsSL --connect-timeout 30 "$APNIC_URL" -o "$TMP_DIR/apnic.txt" || true

update_v4=false
update_v6=false

# Cross validation: IPv4
if [ -s "$TMP_DIR/v4_bgp.txt" ] && [ -s "$TMP_DIR/apnic.txt" ]; then
    awk -F\| '/CN\|ipv4/ { printf("%s/%d\n", $4, 32-log($5)/log(2)) }' "$TMP_DIR/apnic.txt" > "$TMP_DIR/v4_apnic.txt"
    bgp_lines=$(grep -vc '^#' "$TMP_DIR/v4_bgp.txt" || echo 0)
    apnic_lines=$(wc -l < "$TMP_DIR/v4_apnic.txt" || echo 0)
    
    if [ "$bgp_lines" -gt 2000 ] && [ "$apnic_lines" -gt 5000 ]; then
        log "IPv4 validation passed: BGP has $bgp_lines routes, APNIC has $apnic_lines routes."
        cp "$TMP_DIR/v4_bgp.txt" "$OUT_DIR/cn_ipv4.txt"
        update_v4=true
    else
        log "WARN: IPv4 validation failed (BGP: $bgp_lines, APNIC: $apnic_lines). Skipping update."
    fi
elif [ -s "$TMP_DIR/v4_bgp.txt" ]; then
    bgp_lines=$(grep -vc '^#' "$TMP_DIR/v4_bgp.txt" || echo 0)
    if [ "$bgp_lines" -gt 2000 ]; then
        log "WARN: APNIC download failed, but BGP looks valid ($bgp_lines routes). Using BGP fallback."
        cp "$TMP_DIR/v4_bgp.txt" "$OUT_DIR/cn_ipv4.txt"
        update_v4=true
    fi
else
    log "ERR: Failed to download IPv4 BGP routes."
fi

# Cross validation: IPv6
if [ -s "$TMP_DIR/v6_bgp.txt" ] && [ -s "$TMP_DIR/apnic.txt" ]; then
    awk -F\| '/CN\|ipv6/ { printf("%s/%d\n", $4, $5) }' "$TMP_DIR/apnic.txt" > "$TMP_DIR/v6_apnic.txt"
    bgp_lines=$(grep -vc '^#' "$TMP_DIR/v6_bgp.txt" || echo 0)
    apnic_lines=$(wc -l < "$TMP_DIR/v6_apnic.txt" || echo 0)
    
    if [ "$bgp_lines" -gt 500 ] && [ "$apnic_lines" -gt 1000 ]; then
        log "IPv6 validation passed: BGP has $bgp_lines routes, APNIC has $apnic_lines routes."
        cp "$TMP_DIR/v6_bgp.txt" "$OUT_DIR/cn_ipv6.txt"
        update_v6=true
    else
        log "WARN: IPv6 validation failed (BGP: $bgp_lines, APNIC: $apnic_lines). Skipping update."
    fi
elif [ -s "$TMP_DIR/v6_bgp.txt" ]; then
    bgp_lines=$(grep -vc '^#' "$TMP_DIR/v6_bgp.txt" || echo 0)
    if [ "$bgp_lines" -gt 500 ]; then
        log "WARN: APNIC download failed, but BGP looks valid ($bgp_lines routes). Using BGP fallback."
        cp "$TMP_DIR/v6_bgp.txt" "$OUT_DIR/cn_ipv6.txt"
        update_v6=true
    fi
else
    log "ERR: Failed to download IPv6 BGP routes."
fi

if ! $update_v4 && ! $update_v6; then
    log "WARN: No routes updated this run."
    exit 1
fi

log "Routing data update completed."
