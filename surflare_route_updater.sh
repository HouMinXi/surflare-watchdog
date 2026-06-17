#!/bin/bash
# surflare_route_updater.sh
# Fetches BGP and APNIC lists, cross-validates via python, and updates /etc/surflare/.
# Also updates cn_ipv4_extra.txt (cloud CDN APAC bypass), three-source:
#   Source A: RIPE AS routing consistency (IRR+BGP, gold standard)
#   Source B: cloud-ip-ranges.com (RADB AS-SET, >=75% corruption-detection gate)
#   Source C: APNIC delegated stats (APAC geographic filter: HK/SG/TW/JP/KR/MO)

V4_BGP_URL="https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt"
V6_BGP_URL="https://ispip.clang.cn/all_cn_ipv6.txt"
APNIC_URL="https://ftp.apnic.net/stats/apnic/delegated-apnic-latest"

# Cloud CDN -- Source A: RIPE AS routing consistency (IRR+BGP, >=10 peers)
# Returns per-prefix {in_bgp, in_whois} flags; gold standard for routing truth.
#
# Main group (cross-checked vs Source B):
#   Tencent Cloud Intl: AS132203 (cloud compute), AS139341 (ACE CDN edge)
#   Alibaba Cloud Intl: AS45102 (primary), AS24429 (CDN peering)
#   Huawei Cloud APAC:  AS136907 (HK-reg, SG-managed)
#
# Supplement group (RIPE+APAC only; cloud-ip-ranges has no file for these):
#   Alibaba Hangzhou: AS37963 | Alibaba Singapore: AS134963 | ByteDance: AS396986
_RIPE="https://stat.ripe.net/data/as-routing-consistency/data.json?resource="
RIPE_CONSIST_TENCENT="${_RIPE}AS132203"
RIPE_CONSIST_TENCENT_ACE="${_RIPE}AS139341"
RIPE_CONSIST_ALIBABA="${_RIPE}AS45102"
RIPE_CONSIST_ALICDN="${_RIPE}AS24429"
RIPE_CONSIST_HUAWEI="${_RIPE}AS136907"
# Supplement (no cloud-ip-ranges cross-check available)
RIPE_CONSIST_ALIBABA_HZ="${_RIPE}AS37963"
RIPE_CONSIST_ALIBABA_SG="${_RIPE}AS134963"
RIPE_CONSIST_BYTEDANCE="${_RIPE}AS396986"

# Cloud CDN -- Source B: disposable/cloud-ip-ranges (RADB AS-SET, independent)
# Primary: GitHub raw (daily-updated CI). Fallback: jsDelivr CDN (caches GitHub,
# independent CDN path). Both serve identical content; fallback covers GitHub
# outages and rate limits.
_CIDR_GH="https://raw.githubusercontent.com/disposable/cloud-ip-ranges/master/txt"
_CIDR_JSD="https://cdn.jsdelivr.net/gh/disposable/cloud-ip-ranges@master/txt"
CLOUD_TENCENT_URL="${_CIDR_GH}/tencent.txt"
CLOUD_ALIBABA_URL="${_CIDR_GH}/alibaba.txt"
CLOUD_HUAWEI_URL="${_CIDR_GH}/huawei-cloud.txt"
CLOUD_TENCENT_FB="${_CIDR_JSD}/tencent.txt"
CLOUD_ALIBABA_FB="${_CIDR_JSD}/alibaba.txt"
CLOUD_HUAWEI_FB="${_CIDR_JSD}/huawei-cloud.txt"

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
# Cloud CDN extra bypass (cn_ipv4_extra.txt) -- multi-source validation
#
# Source A: RIPE AS routing consistency (IRR + BGP, gold standard, >=10 peers)
#   Main group ASNs: AS132203 AS139341 AS45102 AS24429 AS136907 (cross-checked)
#   Supplement ASNs: AS37963 AS134963 AS396986 (RIPE+APAC only, no cross-check)
# Source B: cloud-ip-ranges (RADB AS-SET) -- cross-check gate >=75% (main group)
# Source C: APNIC delegated stats (APAC geographic filter) -- reuses apnic.txt
# ---------------------------------------------------------------------------
CLOUD_VALIDATOR="$DIR/cross_validate_cloud_cdn.py"
if [ ! -f "$CLOUD_VALIDATOR" ]; then
    log "WARN: cross_validate_cloud_cdn.py missing; skipping extra update"
else
    # -----------------------------------------------------------------
    # Parallel RIPE downloads: main group (5 ASNs) + supplement (3 ASNs)
    # All launched simultaneously; wait collects results.
    # -----------------------------------------------------------------
    log "Cloud CDN extra: parallel RIPE downloads (5 main + 3 supplement ASNs)..."
    curl -fsSL --connect-timeout 30 --max-time 300 \
        "$RIPE_CONSIST_TENCENT"     -o "$TMP_DIR/consist_tencent.json"     &
    curl -fsSL --connect-timeout 30 --max-time 300 \
        "$RIPE_CONSIST_TENCENT_ACE" -o "$TMP_DIR/consist_tencent_ace.json" &
    curl -fsSL --connect-timeout 30 --max-time 300 \
        "$RIPE_CONSIST_ALIBABA"     -o "$TMP_DIR/consist_alibaba.json"     &
    curl -fsSL --connect-timeout 30 --max-time 300 \
        "$RIPE_CONSIST_ALICDN"      -o "$TMP_DIR/consist_alibabacdn.json"  &
    curl -fsSL --connect-timeout 30 --max-time 300 \
        "$RIPE_CONSIST_HUAWEI"      -o "$TMP_DIR/consist_huawei.json"      &
    curl -fsSL --connect-timeout 30 --max-time 300 \
        "$RIPE_CONSIST_ALIBABA_HZ"  -o "$TMP_DIR/consist_alibaba_hz.json"  &
    curl -fsSL --connect-timeout 30 --max-time 300 \
        "$RIPE_CONSIST_ALIBABA_SG"  -o "$TMP_DIR/consist_alibaba_sg.json"  &
    curl -fsSL --connect-timeout 30 --max-time 300 \
        "$RIPE_CONSIST_BYTEDANCE"   -o "$TMP_DIR/consist_bytedance.json"   &
    wait

    # Check main group; warn on any missing but only skip if all fail
    ripe_ok=true
    for name in tencent tencent_ace alibaba alibabacdn huawei; do
        if [ ! -s "$TMP_DIR/consist_${name}.json" ]; then
            log "WARN: RIPE download failed for main ASN: ${name}"
            ripe_ok=false
        fi
    done
    # Supplement group: failures are non-fatal (logged, skipped individually)
    for name in alibaba_hz alibaba_sg bytedance; do
        if [ ! -s "$TMP_DIR/consist_${name}.json" ]; then
            log "WARN: RIPE download failed for supplement ASN: ${name} (skipped)"
        fi
    done

    # -----------------------------------------------------------------
    # Source B downloads: tencent + alibaba + huawei-cloud (with fallback)
    # -----------------------------------------------------------------
    log "Cloud CDN extra: downloading Source B (cloud-ip-ranges RADB AS-SET)..."
    cloud_ok=true
    # Separator is '|' (not ':') -- URLs contain ':' in 'https://' so colon
    # cannot be used as a field delimiter here.
    for entry in \
        "tencent|${CLOUD_TENCENT_URL}|${CLOUD_TENCENT_FB}" \
        "alibaba|${CLOUD_ALIBABA_URL}|${CLOUD_ALIBABA_FB}" \
        "huawei|${CLOUD_HUAWEI_URL}|${CLOUD_HUAWEI_FB}"; do
        name="${entry%%|*}"
        rest="${entry#*|}"
        primary="${rest%%|*}"
        fallback="${rest#*|}"
        if curl -fsSL --connect-timeout 30 "$primary" \
                -o "$TMP_DIR/cloud_${name}.txt" 2>/dev/null; then
            log "Source B ${name}: downloaded from primary"
        elif curl -fsSL --connect-timeout 30 "$fallback" \
                -o "$TMP_DIR/cloud_${name}.txt" 2>/dev/null; then
            log "WARN: Source B ${name}: primary failed, used jsDelivr fallback"
        else
            log "WARN: Source B ${name}: both primary and fallback failed"
            cloud_ok=false
        fi
    done

    if $ripe_ok && $cloud_ok; then
        # Merge 5 main-group RIPE JSONs into consist_merged.json
        python3 - \
                "$TMP_DIR/consist_tencent.json" \
                "$TMP_DIR/consist_tencent_ace.json" \
                "$TMP_DIR/consist_alibaba.json" \
                "$TMP_DIR/consist_alibabacdn.json" \
                "$TMP_DIR/consist_huawei.json" \
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

        # Merge Source B files (tencent + alibaba + huawei-cloud)
        cat "$TMP_DIR/cloud_tencent.txt" \
            "$TMP_DIR/cloud_alibaba.txt" \
            "$TMP_DIR/cloud_huawei.txt" \
            | grep -v '^#' | grep -v '^[[:space:]]*$' | sort -u \
            > "$TMP_DIR/cloud_combined.txt"

        # Source C: reuse APNIC delegated stats (already downloaded above)
        apnic_ref="$TMP_DIR/apnic.txt"
        if [ ! -s "$apnic_ref" ]; then
            log "WARN: APNIC unavailable; skipping APAC geo-filter"
            ripe_ok=false
        fi

        # Guard cn_v4_ref against empty/missing path
        cn_v4_ref="${OUT_DIR}/cn_ipv4.txt"
        if [ ! -f "$cn_v4_ref" ]; then
            cn_v4_ref="$TMP_DIR/v4_bgp.txt"
        fi
        if [ ! -f "$cn_v4_ref" ]; then
            log "WARN: no cn_ipv4 reference; dedup step skipped"
            cn_v4_ref="/dev/null"
        fi

        # Build supplement args: only include files that exist and are non-empty
        supplement_args=()
        for name in alibaba_hz alibaba_sg bytedance; do
            if [ -s "$TMP_DIR/consist_${name}.json" ]; then
                supplement_args+=("$TMP_DIR/consist_${name}.json")
            fi
        done

        if $ripe_ok; then
            output=$(python3 "$CLOUD_VALIDATOR" \
                "$TMP_DIR/consist_merged.json" \
                "$TMP_DIR/cloud_combined.txt" \
                "$apnic_ref" \
                "$cn_v4_ref" \
                "$TMP_DIR/cn_ipv4_extra.txt" \
                "${supplement_args[@]}" 2>&1)
            rc=$?
            echo "$output" | logger -t surflare-route-updater
            log "Cloud CDN validator: $output"

            if [ "$rc" -eq 0 ] && [ -s "$TMP_DIR/cn_ipv4_extra.txt" ]; then
                cp "$TMP_DIR/cn_ipv4_extra.txt" "$OUT_DIR/cn_ipv4_extra.txt"
                # Append static Akamai APAC CIDRs (Bilibili CDN fallback nodes).
                # Akamai AS20940 is a global CDN; dynamic RIPE validation would
                # add all AS20940 prefixes worldwide. Only the APAC /24s returned
                # by AliDNS (EDNS client subnet = CN ISP IP) for akamaized.net
                # are appended. SmartDNS nameserver /akamaized.net/domestic
                # ensures phones resolve to these nodes, not US-region nodes.
                # Verified 2026-06-17: nslookup a1893.dscw10.akamai.net 223.5.5.5
                # from N100 (CN ISP IP) consistently returns 23.46.216.0/24.
                {
                    printf '# Akamai APAC static (Bilibili CDN fallback; akamaized.net via CN DNS)\n'
                    printf '23.46.216.0/24\n'
                    printf '23.67.33.0/24\n'
                    printf '23.214.95.0/24\n'
                } >> "$OUT_DIR/cn_ipv4_extra.txt"
                extra_count=$(grep -vc '^#' "$OUT_DIR/cn_ipv4_extra.txt" \
                    2>/dev/null || echo 0)
                log "Cloud CDN extra bypass updated: ${extra_count} APAC CIDRs (incl. Akamai static)"
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
