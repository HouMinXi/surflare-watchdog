#!/bin/bash
# surflare_route_updater.sh
# Fetches BGP and APNIC lists, cross-validates via python, and updates /etc/surflare/.
# Also updates cn_ipv4_extra.txt (cloud CDN APAC bypass), three-source:
#   Source A: RIPE AS routing consistency (IRR+BGP, gold standard)
#   Source B: cloud-ip-ranges.com (RADB AS-SET, >=90% cross-check)
#   Source C: APNIC delegated stats (APAC geographic filter: HK/SG/TW/JP/KR/MO)

V4_BGP_URL="https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt"
V6_BGP_URL="https://ispip.clang.cn/all_cn_ipv6.txt"
APNIC_URL="https://ftp.apnic.net/stats/apnic/delegated-apnic-latest"

# Cloud CDN -- Source A: RIPE AS routing consistency (IRR+BGP, >=10 peers)
# Returns per-prefix {in_bgp, in_whois} flags; gold standard for routing truth
RIPE_CONSIST_TENCENT="https://stat.ripe.net/data/as-routing-consistency/data.json?resource=AS132203"
RIPE_CONSIST_ALIBABA="https://stat.ripe.net/data/as-routing-consistency/data.json?resource=AS45102"
RIPE_CONSIST_ALICDN="https://stat.ripe.net/data/as-routing-consistency/data.json?resource=AS24429"

# Cloud CDN -- Source B: disposable/cloud-ip-ranges (RADB AS-SET, independent)
# GitHub raw -- daily auto-updated by cloud-ip-ranges-crawler CI
_CIDR_BASE="https://raw.githubusercontent.com/disposable/cloud-ip-ranges/master/txt"
CLOUD_TENCENT_URL="${_CIDR_BASE}/tencent.txt"
CLOUD_ALIBABA_URL="${_CIDR_BASE}/alibaba.txt"

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
    output=$(python3 "$VALIDATOR" ipv4 "$TMP_DIR/v4_bgp.txt" "$TMP_DIR/apnic.txt" 2>&1)
    rc=$?
    if [ -n "$output" ]; then
        echo "$output" | logger -t surflare-route-updater
    fi
    if [ "$rc" -eq 0 ]; then
        log "IPv4 cross-validation passed."
        cp "$TMP_DIR/v4_bgp.txt" "$OUT_DIR/cn_ipv4.txt"
        update_v4=true
    else
        log "ERR: IPv4 cross-validation failed! BGP data rejected."
    fi
elif [ -s "$TMP_DIR/v4_bgp.txt" ]; then
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
    output=$(python3 "$VALIDATOR" ipv6 "$TMP_DIR/v6_bgp.txt" "$TMP_DIR/apnic.txt" 2>&1)
    rc=$?
    if [ -n "$output" ]; then
        echo "$output" | logger -t surflare-route-updater
    fi
    if [ "$rc" -eq 0 ]; then
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

# ---------------------------------------------------------------------------
# Cloud CDN extra bypass (cn_ipv4_extra.txt) -- three-source validation
#
# Source A: RIPE AS routing consistency (IRR + BGP, gold standard, >=10 peers)
#   Endpoint: stat.ripe.net/data/as-routing-consistency/data.json
#   Provides per-prefix {in_bgp, in_whois} flags; only in_bgp AND in_whois kept.
# Source B: cloud-ip-ranges.com (RADB AS-SET, daily) -- cross-check gate >=90%
# Source C: APNIC delegated stats (APAC geographic filter) -- reuses apnic.txt
#
# Covers: Tencent Cloud Intl (AS132203) + Alibaba Cloud Intl (AS45102, AS24429)
# ---------------------------------------------------------------------------
CLOUD_VALIDATOR="$DIR/cross_validate_cloud_cdn.py"
if [ ! -f "$CLOUD_VALIDATOR" ]; then
    log "WARN: cross_validate_cloud_cdn.py missing; skipping extra update"
else
    log "Cloud CDN extra: downloading Source A (RIPE AS routing consistency)..."
    ripe_ok=true
    for pair in "tencent:$RIPE_CONSIST_TENCENT" \
                "alibaba:$RIPE_CONSIST_ALIBABA" \
                "alibabacdn:$RIPE_CONSIST_ALICDN"; do
        name="${pair%%:*}"
        url="${pair#*:}"
        if ! curl -fsSL --connect-timeout 30 --max-time 300 "$url" \
                -o "$TMP_DIR/consist_${name}.json"; then
            log "WARN: Failed to download RIPE consistency for ${name}"
            ripe_ok=false
        fi
    done

    log "Cloud CDN extra: downloading Source B (cloud-ip-ranges RADB AS-SET)..."
    cloud_ok=true
    for pair in "tencent:$CLOUD_TENCENT_URL" "alibaba:$CLOUD_ALIBABA_URL"; do
        name="${pair%%:*}"
        url="${pair#*:}"
        if ! curl -fsSL --connect-timeout 30 "$url" \
                -o "$TMP_DIR/cloud_${name}.txt"; then
            log "WARN: Failed to download cloud-ip-ranges for ${name}"
            cloud_ok=false
        fi
    done

    if $ripe_ok && $cloud_ok; then
        # Merge three RIPE consistency JSONs into one (P3-2: single block)
        python3 - "$TMP_DIR/consist_tencent.json" \
                   "$TMP_DIR/consist_alibaba.json" \
                   "$TMP_DIR/consist_alibabacdn.json" \
                   "$TMP_DIR/consist_merged.json" << 'PYEOF'
import json, sys
merged = {'data': {'prefixes': []}}
for path in sys.argv[1:-1]:
    try:
        with open(path) as f:
            d = json.load(f)
        merged['data']['prefixes'].extend(
            d.get('data', {}).get('prefixes', []))
    except Exception as e:
        print(f'WARN merge {path}: {e}', file=sys.stderr)
with open(sys.argv[-1], 'w') as f:
    json.dump(merged, f)
print(f"Merged {len(merged['data']['prefixes'])} consistency entries")
PYEOF

        # Merge cloud-ip-ranges files into one Source B file
        cat "$TMP_DIR/cloud_tencent.txt" "$TMP_DIR/cloud_alibaba.txt" \
            | grep -v '^#' | grep -v '^[[:space:]]*$' | sort -u \
            > "$TMP_DIR/cloud_combined.txt"

        # Source C: reuse APNIC delegated stats (already downloaded above)
        apnic_ref="$TMP_DIR/apnic.txt"
        if [ ! -s "$apnic_ref" ]; then
            log "WARN: APNIC unavailable; skipping APAC geo-filter"
            ripe_ok=false
        fi

        # P3-3: guard cn_v4_ref against empty/missing path
        cn_v4_ref="${OUT_DIR}/cn_ipv4.txt"
        if [ ! -f "$cn_v4_ref" ]; then
            cn_v4_ref="$TMP_DIR/v4_bgp.txt"
        fi
        if [ ! -f "$cn_v4_ref" ]; then
            log "WARN: no cn_ipv4 reference; dedup step skipped"
            cn_v4_ref="/dev/null"
        fi

        if $ripe_ok; then
            output=$(python3 "$CLOUD_VALIDATOR" \
                "$TMP_DIR/consist_merged.json" \
                "$TMP_DIR/cloud_combined.txt" \
                "$apnic_ref" \
                "$cn_v4_ref" \
                "$TMP_DIR/cn_ipv4_extra.txt" 2>&1)
            rc=$?
            echo "$output" | logger -t surflare-route-updater
            log "Cloud CDN validator: $output"

            if [ "$rc" -eq 0 ] && [ -s "$TMP_DIR/cn_ipv4_extra.txt" ]; then
                cp "$TMP_DIR/cn_ipv4_extra.txt" "$OUT_DIR/cn_ipv4_extra.txt"
                extra_count=$(grep -vc '^#' "$OUT_DIR/cn_ipv4_extra.txt" \
                    2>/dev/null || echo 0)
                log "Cloud CDN extra bypass updated: ${extra_count} APAC CIDRs"
            else
                log "ERR: Cloud CDN validation failed; extra file unchanged"
            fi
        else
            log "WARN: APNIC unavailable; skipping CDN validator"
        fi
    else
        log "WARN: Source download incomplete; skipping cloud CDN extra update"
    fi
fi

log "Routing data update completed."
