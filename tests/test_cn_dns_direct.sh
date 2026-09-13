#!/usr/bin/env bash
# T9b/T16 + static invariants for the cn_dns_direct install
# (spec 2026-09-12-cn-dns-view).  The nft template is extracted from the
# real watchdog heredoc -- never duplicated here -- and loaded inside an
# isolated user+net namespace (unshare -Urn).  Each namespace lives for
# one sh -c invocation, so multi-step sequences stay in a single call.
set -u
cd "$(dirname "$0")/.."
WD="surflare_watchdog.sh"
PROCD="router/services/procd/surflare-watchdog"
CONF="router/smartdns/custom.conf.example"
NS="unshare -Urn"
fail=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk '/^destroy table inet cn_dns_direct$/,/^NFTEOF$/' "$WD" | sed '/^NFTEOF$/d' > "$TMP/tpl.nft"

# --- structural invariants on the extracted template ---
[ -s "$TMP/tpl.nft" ] && ok "template extracted" || bad "template empty"
head -1 "$TMP/tpl.nft" | grep -qx 'destroy table inet cn_dns_direct' \
    && ok "destroy is first line" || bad "destroy not first line"
grep -q 'type route hook output priority -160;' "$TMP/tpl.nft" \
    && ok "priority -160" || bad "priority -160 missing"
[ "$(grep -c 'counter accept' "$TMP/tpl.nft")" -eq 2 ] \
    && ok "counter accept x2" || bad "counter accept count != 2"
for ip in 223.5.5.5 223.6.6.6 120.53.53.53 1.12.12.12 119.29.29.29 114.114.114.114; do
    grep -q "$ip" "$TMP/tpl.nft" || bad "dns_anycast missing $ip"
done

# --- T9b: dry-run, then load and inspect in one namespace ---
if $NS nft -c -f "$TMP/tpl.nft" 2>"$TMP/dry.err"; then
    ok "nft -c rc=0"
else
    bad "nft -c rc!=0: $(head -1 "$TMP/dry.err")"
fi

OUT="$($NS sh -c 'nft -f "$1" && nft -j list chain inet cn_dns_direct output' _ "$TMP/tpl.nft" 2>/dev/null)"
echo "$OUT" | grep -q '"prio": -160' && ok "json prio -160" || bad "json prio not -160"

CNT="$($NS sh -c 'nft -f "$1" && nft list chain inet cn_dns_direct output' _ "$TMP/tpl.nft" 2>/dev/null | grep -c 'counter packets')"
[ "$CNT" -eq 2 ] && ok "counter packets on both rules" || bad "counter rules=$CNT want 2"

# --- T16: two consecutive loads stay at one rule per port group ---
SEQ="$($NS sh -c 'nft -f "$1" && nft -f "$1" && nft list chain inet cn_dns_direct output' _ "$TMP/tpl.nft" 2>/dev/null | grep -c 'meta mark set')"
[ "$SEQ" -eq 2 ] && ok "double load keeps 2 rules" || bad "double load rules=$SEQ want 2"

# --- injection 1: drop '=' after elements -> dry-run must FAIL ---
sed 's/elements = {/elements {/' "$TMP/tpl.nft" > "$TMP/bad.nft"
if $NS nft -c -f "$TMP/bad.nft" 2>"$TMP/bad.err"; then
    bad "injected 'elements {' passed nft -c"
else
    grep -q "expecting '='" "$TMP/bad.err" \
        && ok "injection elements-{ rc!=0 with expecting '='" \
        || bad "injection error text unexpected: $(head -1 "$TMP/bad.err")"
fi

# --- injection 2: drop destroy -> double load duplicates (teeth for T16) ---
grep -v '^destroy table inet cn_dns_direct$' "$TMP/tpl.nft" > "$TMP/nodestroy.nft"
DUP="$($NS sh -c 'nft -f "$1" && nft -f "$1" && nft list chain inet cn_dns_direct output' _ "$TMP/nodestroy.nft" 2>/dev/null | grep -c 'meta mark set')"
[ "$DUP" -eq 4 ] && ok "injection no-destroy duplicates to 4" || bad "no-destroy double load gave $DUP, want 4"

# --- call sites / teardown / syntax ---
CALLS="$(grep -c '^[[:space:]]*_install_cn_dns_direct$' "$WD")"
[ "$CALLS" -eq 6 ] && ok "6 call sites" || bad "call sites=$CALLS want 6"
grep -q '^_install_cn_dns_direct() {' "$WD" && ok "function defined" || bad "function missing"
grep -q 'nft delete table inet cn_dns_direct' "$WD" && ok "teardown in watchdog" || bad "teardown missing in watchdog"
grep -q 'nft delete table inet cn_dns_direct' "$PROCD" && ok "teardown in procd" || bad "teardown missing in procd"
bash -n "$WD" && ok "bash -n watchdog" || bad "bash -n watchdog"
bash -n "$PROCD" && ok "bash -n procd" || bad "bash -n procd"

# --- T8 repo side: no plain-UDP domestic upstreams in the example conf ---
if grep -qE '^server [0-9].*-group domestic' "$CONF"; then
    bad "plain-UDP domestic upstream still in $CONF"
else
    ok "no plain-UDP domestic upstream in example conf"
fi

exit "$fail"
