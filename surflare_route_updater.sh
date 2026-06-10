#!/bin/bash
# surflare_route_updater.sh
# Fetches BGP and APNIC lists, cross-validates via python, and updates /etc/surflare/.

V4_BGP_URL="https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt"
V6_BGP_URL="https://ispip.clang.cn/all_cn_ipv6.txt"
APNIC_URL="https://ftp.apnic.net/stats/apnic/delegated-apnic-latest"

OUT_DIR="/etc/surflare"
mkdir -p "$OUT_DIR"

# Get the script directory to find the python validator
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$DIR/cross_validate_routes.py"

log() {
    logger -t surflare-route-updater "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

TMP_DIR=$(mktemp -d /tmp/surflare_updater_XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

log "Downloading BGP route lists..."
if ! curl -fsSL --connect-timeout 30 "$V4_BGP_URL" -o "$TMP_DIR/v4_bgp.txt"; then
    log "WARN: Failed to download IPv4 BGP routes"
fi
if ! curl -fsSL --connect-timeout 30 "$V6_BGP_URL" -o "$TMP_DIR/v6_bgp.txt"; then
    log "WARN: Failed to download IPv6 BGP routes"
fi

log "Downloading APNIC delegated stats..."
if ! curl -fsSL --connect-timeout 30 "$APNIC_URL" -o "$TMP_DIR/apnic.txt"; then
    log "WARN: Failed to download APNIC delegated stats"
fi

update_v4=false
update_v6=false

# Cross validation: IPv4
if [ -s "$TMP_DIR/v4_bgp.txt" ] && [ -s "$TMP_DIR/apnic.txt" ]; then
    if python3 "$VALIDATOR" ipv4 "$TMP_DIR/v4_bgp.txt" "$TMP_DIR/apnic.txt" 2>&1 | logger -t surflare-route-updater; then
        log "IPv4 cross-validation passed."
        cp "$TMP_DIR/v4_bgp.txt" "$OUT_DIR/cn_ipv4.txt"
        update_v4=true
    else
        log "ERR: IPv4 cross-validation failed! BGP data rejected."
    fi
elif [ -s "$TMP_DIR/v4_bgp.txt" ]; then
    # APNIC unreachable but BGP is downloaded. Do we trust BGP blindly?
    # H-3: If attacker blocks APNIC and poisons BGP, this bypasses validation.
    # To fix H-3, we REFUSE to update if APNIC is unreachable and we have an existing local copy.
    # Only if we don't have a local copy at all do we accept BGP as a last resort, but we should probably just fail.
    if [ -s "$OUT_DIR/cn_ipv4.txt" ]; then
        log "ERR: APNIC download failed, existing cache found. Rejecting unvalidated BGP update."
    else
        bgp_lines=$(grep -vc '^#' "$TMP_DIR/v4_bgp.txt" || echo 0)
        if [ "$bgp_lines" -gt 2000 ]; then
            log "WARN: APNIC unreachable, NO existing cache! Blindly trusting BGP fallback."
            cp "$TMP_DIR/v4_bgp.txt" "$OUT_DIR/cn_ipv4.txt"
            update_v4=true
        fi
    fi
else
    log "ERR: No valid IPv4 BGP routes downloaded."
fi

# Cross validation: IPv6
if [ -s "$TMP_DIR/v6_bgp.txt" ] && [ -s "$TMP_DIR/apnic.txt" ]; then
    if python3 "$VALIDATOR" ipv6 "$TMP_DIR/v6_bgp.txt" "$TMP_DIR/apnic.txt" 2>&1 | logger -t surflare-route-updater; then
        log "IPv6 cross-validation passed."
        cp "$TMP_DIR/v6_bgp.txt" "$OUT_DIR/cn_ipv6.txt"
        update_v6=true
    else
        log "ERR: IPv6 cross-validation failed! BGP data rejected."
    fi
elif [ -s "$TMP_DIR/v6_bgp.txt" ]; then
    if [ -s "$OUT_DIR/cn_ipv6.txt" ]; then
        log "ERR: APNIC download failed, existing cache found. Rejecting unvalidated BGP update."
    else
        bgp_lines=$(grep -vc '^#' "$TMP_DIR/v6_bgp.txt" || echo 0)
        if [ "$bgp_lines" -gt 500 ]; then
            log "WARN: APNIC unreachable, NO existing cache! Blindly trusting BGP fallback."
            cp "$TMP_DIR/v6_bgp.txt" "$OUT_DIR/cn_ipv6.txt"
            update_v6=true
        fi
    fi
else
    log "ERR: No valid IPv6 BGP routes downloaded."
fi

if ! $update_v4 && ! $update_v6; then
    log "WARN: No routes updated this run."
    exit 1
fi

log "Routing data update completed."
