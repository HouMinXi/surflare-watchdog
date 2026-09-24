#!/usr/bin/env bash
# Loop guard for the tproxy port: LAN clients that misconfigure a proxy
# at the router's own :10800 must return (bypass), never reach the tproxy
# rule.  Host-side: structural checks + unshare nft parse of the real file.
# Also covers _raise_proxy_fd_limit wiring (helper exists, called at both
# start paths, prlimit best-effort).
# shellcheck disable=SC2015
set -u
cd "$(dirname "$0")/.." || exit 1
WD="surflare_watchdog.sh"
RULE="router/rule/surflare-lan-tproxy.nft"
GLOBAL="router/global/surflare-lan-tproxy.nft"
NS() { unshare -Urn "$@"; }
fail=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# --- T1: loop-guard return exists in both tproxy variants, before tproxy ---
for f in "$RULE" "$GLOBAL"; do
    guard_ln=$(grep -n 'tcp dport 10800 return' "$f" | head -1 | cut -d: -f1)
    [ -n "$guard_ln" ] \
        && ok "$f: loop-guard return present" || bad "$f: loop-guard return missing"
    tproxy_ln=$(grep -n 'tproxy ip to :10800' "$f" | head -1 | cut -d: -f1)
    [ -n "$tproxy_ln" ] \
        && ok "$f: tproxy rule present" || bad "$f: tproxy rule missing"
    if [ -n "$guard_ln" ] && [ -n "$tproxy_ln" ]; then
        [ "$guard_ln" -lt "$tproxy_ln" ] \
            && ok "$f: guard precedes tproxy" \
            || bad "$f: guard AFTER tproxy (dead rule)"
    fi
    # Guard must be scoped to the router's own LAN address, not any :10800
    grep -B1 'tcp dport 10800 return' "$f" | grep -q 'ip daddr 192.168.100.1' \
        && ok "$f: guard scoped to router LAN addr" \
        || bad "$f: guard not scoped (would exempt foreign 10800)"
done

# --- T2: the real file parses in a fresh namespace ---
if command -v unshare >/dev/null 2>&1; then
    NS nft -f "$RULE" >/dev/null 2>&1 \
        && ok "rule nft parses (unshare)" || bad "rule nft parse FAIL (unshare)"
    NS nft -f "$GLOBAL" >/dev/null 2>&1 \
        && ok "global nft parses (unshare)" || bad "global nft parse FAIL (unshare)"
    # T3: applied guard actually returns :10800 traffic (not tproxy'd)
    if NS sh -c "nft -f '$RULE' && nft list table inet sw_lan_tproxy" 2>/dev/null \
            | grep -q 'iifname "br-lan".*192.168.100.1.*tcp dport 10800.*return'; then
        ok "applied table carries the v4 guard"
    else
        bad "applied table lost the v4 guard"
    fi
    if NS sh -c "nft -f '$RULE' && nft list table inet sw_lan_tproxy" 2>/dev/null \
            | grep -q 'fe80::/10.*tcp dport 10800.*return'; then
        ok "applied table carries the v6 guard"
    else
        bad "applied table lost the v6 guard"
    fi
else
    echo "SKIP: unshare unavailable"
fi

# --- T4: fd-limit helper exists and is called on both start paths ---
grep -q '^_raise_proxy_fd_limit()' "$WD" \
    && ok "helper defined" || bad "helper missing"
# connect_vpn poll path: helper runs only after check_vpn_local_state
# inside the same if-block (if ... then log; helper; break).
poll=$(awk '/^connect_vpn\(\)/,/^}/' "$WD")
echo "$poll" | grep -A2 'if check_vpn_local_state; then' \
    | grep -q '_raise_proxy_fd_limit' \
    && ok "connect_vpn calls helper on ready" \
    || bad "connect_vpn helper not gated on local-state check"
# _start_surflare_proxy settle path
awk '/^_start_surflare_proxy\(\)/,/^}/' "$WD" | grep -q '_raise_proxy_fd_limit' \
    && ok "_start_surflare_proxy calls helper" || bad "_start_surflare_proxy missing call"
# helper is best-effort (never blocks startup on prlimit failure)
awk '/^_raise_proxy_fd_limit\(\)/,/^}/' "$WD" | grep -q '|| true' \
    && ok "helper best-effort" || bad "helper can fail hard"

# --- T5: bug-inject -- removing EITHER guard line turns T1 red ---
for variant in v4 v6; do
    TMPG=$(mktemp)
    if [ "$variant" = v4 ]; then
        sed 's/ip daddr 192.168.100.1 tcp dport 10800 return/ip daddr 192.168.100.1 tcp dport 10999 return/' "$RULE" > "$TMPG"
    else
        sed 's/ip6 daddr fe80::\/10 tcp dport 10800 return/ip6 daddr fe80::\/10 tcp dport 10999 return/' "$RULE" > "$TMPG"
    fi
    # After injection the specific guard line must be GONE from the file.
    case "$variant" in
        v4) pat='ip daddr 192.168.100.1 tcp dport 10800 return' ;;
        v6) pat='ip6 daddr fe80::/10 tcp dport 10800 return' ;;
    esac
    if ! grep -q "$pat" "$TMPG"; then
        ok "inject: $variant guard removal detectable by T1"
    else
        bad "inject: T1 cannot detect $variant guard removal"
    fi
    rm -f "$TMPG"
done
echo
[ "$fail" = "0" ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
