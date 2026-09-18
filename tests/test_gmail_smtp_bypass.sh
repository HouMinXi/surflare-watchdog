#!/usr/bin/env bash
# Gmail SMTP 465/587 ISP-direct bypass: tproxy return + killswitch accept.
# Host-side.  Extracts real nft from the watchdog heredoc and the two
# tproxy files.  Does not SSH to N100.
# shellcheck disable=SC2015
set -u
cd "$(dirname "$0")/.." || exit 1
WD="surflare_watchdog.sh"
RULE="router/rule/surflare-lan-tproxy.nft"
GLOBAL="router/global/surflare-lan-tproxy.nft"
SDNS="router/smartdns/gmail-smtp.conf.example"
CONF="router/smartdns/custom.conf.example"
NS="unshare -Urn"
fail=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# Whole-token 22/25 inside a dport set.  'dport.*(22|25)' also hits 425/2525.
gmail_dport_has_22_or_25() {
    grep -E 'ip daddr @gmail_smtp' "$1" | grep -qE 'dport \{[^}]*\b(22|25)\b'
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk '/^destroy table inet killswitch$/,/^NFTEOF$/' "$WD" | sed '/^NFTEOF$/d' > "$TMP/ks.nft"
[ -s "$TMP/ks.nft" ] && ok "killswitch template extracted" || bad "killswitch template empty"

# --- T1: both tproxy files declare gmail_smtp / gmail_smtp6 ---
for f in "$RULE" "$GLOBAL"; do
    grep -q 'set gmail_smtp {' "$f" \
        && ok "$f: set gmail_smtp" || bad "$f: missing set gmail_smtp"
    grep -q 'set gmail_smtp6 {' "$f" \
        && ok "$f: set gmail_smtp6" || bad "$f: missing set gmail_smtp6"
    grep -A4 'set gmail_smtp {' "$f" | grep -q 'timeout 1h' \
        && ok "$f: gmail_smtp timeout 1h" || bad "$f: gmail_smtp no 1h timeout"
done

# --- T2/T3: return is port-limited and sits before tproxy :10800 ---
gmail_return_before_tproxy() {
    local f="$1"
    # Rule line only: iifname + set + dport + return.  A comment that
    # happens to mention those tokens must not count.
    awk '
        /iifname/ && /ip daddr @gmail_smtp tcp dport/ && /return/ { g=NR }
        /tproxy ip to :10800/ && !seen++ { t=NR }
        END {
            if (!g) { print "no-gmail-return"; exit 1 }
            if (!t) { print "no-tproxy"; exit 1 }
            if (g < t) { print "ok", g, t; exit 0 }
            print "after-tproxy", g, t; exit 1
        }
    ' "$f"
}

for f in "$RULE" "$GLOBAL"; do
    if out=$(gmail_return_before_tproxy "$f"); then
        ok "$f: gmail return before tproxy ($out)"
    else
        bad "$f: gmail return not before tproxy ($out)"
    fi
    grep -E 'ip daddr @gmail_smtp tcp dport' "$f" | grep -q '465' \
        && grep -E 'ip daddr @gmail_smtp tcp dport' "$f" | grep -q '587' \
        && ok "$f: tproxy ports 465 and 587" \
        || bad "$f: tproxy gmail rule missing 465/587"
    if gmail_dport_has_22_or_25 "$f"; then
        bad "$f: tproxy gmail rule also matches 22 or 25"
    else
        ok "$f: tproxy gmail rule not 22/25"
    fi
    # A set-only return (no dport) would leak HTTPS on shared Google IPs.
    if grep -E 'ip daddr @gmail_smtp[^6].*return' "$f" | grep -qv 'tcp dport'; then
        bad "$f: gmail_smtp return without tcp dport (HTTPS leak)"
    else
        ok "$f: gmail_smtp return is port-limited"
    fi
done

# --- T4: killswitch set + forward accept, before reject, same ports ---
grep -q 'set gmail_smtp ' "$TMP/ks.nft" \
    && ok "killswitch set gmail_smtp" || bad "killswitch missing set gmail_smtp"
grep -q 'set gmail_smtp6 ' "$TMP/ks.nft" \
    && ok "killswitch set gmail_smtp6" || bad "killswitch missing set gmail_smtp6"

ks_accept_before_reject() {
    awk '
        /iifname/ && /ip daddr @gmail_smtp tcp dport/ && /accept/ { a=NR }
        /reject with icmp host-unreachable/ { r=NR }
        END {
            if (!a) { print "no-gmail-accept"; exit 1 }
            if (!r) { print "no-reject"; exit 1 }
            if (a < r) { print "ok", a, r; exit 0 }
            print "after-reject", a, r; exit 1
        }
    ' "$TMP/ks.nft"
}
if out=$(ks_accept_before_reject); then
    ok "killswitch gmail accept before reject ($out)"
else
    bad "killswitch gmail accept not before reject ($out)"
fi
grep -E 'ip daddr @gmail_smtp tcp dport' "$TMP/ks.nft" | grep -q '465' \
    && grep -E 'ip daddr @gmail_smtp tcp dport' "$TMP/ks.nft" | grep -q '587' \
    && ok "killswitch ports 465 and 587" \
    || bad "killswitch gmail rule missing 465/587"
if gmail_dport_has_22_or_25 "$TMP/ks.nft"; then
    bad "killswitch gmail rule also matches 22 or 25"
else
    ok "killswitch gmail rule not 22/25"
fi

# --- T5: SmartDNS example fills both tables, both domains, no 22/25 ---
[ -f "$SDNS" ] && ok "gmail-smtp.conf.example exists" || bad "missing $SDNS"
grep -q 'smtp.gmail.com' "$SDNS" \
    && ok "smartdns smtp.gmail.com" || bad "smartdns missing smtp.gmail.com"
grep -q 'smtp.googlemail.com' "$SDNS" \
    && ok "smartdns smtp.googlemail.com" || bad "smartdns missing smtp.googlemail.com"
grep -q 'sw_lan_tproxy#gmail_smtp' "$SDNS" \
    && grep -q 'killswitch#gmail_smtp' "$SDNS" \
    && ok "smartdns nftset both tables" \
    || bad "smartdns nftset not dual-table"
grep -q 'speed-check-mode none' "$SDNS" \
    && ok "smartdns speed-check none" || bad "smartdns missing speed-check-mode none"
grep -q 'conf-file /etc/smartdns/gmail-smtp.conf' "$CONF" \
    && ok "custom.conf.example includes gmail-smtp.conf" \
    || bad "custom.conf.example missing gmail-smtp include"

# --- T6: nft -c on tproxy files and killswitch heredoc ---
if command -v nft >/dev/null 2>&1 && $NS true >/dev/null 2>&1; then
    for f in "$RULE" "$GLOBAL"; do
        if $NS nft -c -f "$f" 2>"$TMP/dry.err"; then
            ok "nft -c $f"
        else
            bad "nft -c $f: $(head -1 "$TMP/dry.err")"
        fi
    done
    if $NS nft -c -f "$TMP/ks.nft" 2>"$TMP/ks.err"; then
        ok "nft -c killswitch heredoc"
    else
        bad "nft -c killswitch: $(head -1 "$TMP/ks.err")"
    fi
else
    echo "SKIP: nft -c (no nft or unshare)"
fi

# --- T7: injection -- drop tproxy dport so order/port checks fail ---
sed '/ip daddr @gmail_smtp tcp dport/d' "$RULE" > "$TMP/noport.nft"
if out=$(gmail_return_before_tproxy "$TMP/noport.nft"); then
    bad "injection: stripped gmail return still passed ($out)"
else
    ok "injection: stripped gmail return fails order check ($out)"
fi
# injection -- comment mentioning the tokens must not satisfy the order awk
sed 's/iifname "br-lan" ip daddr @gmail_smtp tcp dport { 465, 587 } return/# ip daddr @gmail_smtp tcp dport return/' \
    "$RULE" > "$TMP/comment.nft"
if out=$(gmail_return_before_tproxy "$TMP/comment.nft"); then
    bad "injection: comment-only tokens still passed ($out)"
else
    ok "injection: comment-only tokens fail order check ($out)"
fi
# injection -- widen to 22 must be caught; 425 must not
sed 's/{ 465, 587 }/{ 22, 465, 587 }/' "$RULE" > "$TMP/wide.nft"
if gmail_dport_has_22_or_25 "$TMP/wide.nft"; then
    ok "injection: widened dport 22 is detectable"
else
    bad "injection: widened dport 22 not detectable"
fi
sed 's/{ 465, 587 }/{ 425, 587 }/' "$RULE" > "$TMP/sub.nft"
if gmail_dport_has_22_or_25 "$TMP/sub.nft"; then
    bad "injection: 425 falsely flagged as 22/25"
else
    ok "injection: 425 is not 22/25"
fi

# --- T8: zero-kill adopt must hot-add gmail_smtp into an existing killswitch ---
# Adopt / healthy ticks skip _install_killswitch when the table already
# exists.  Without _ensure_gmail_smtp_ks, SMTP hits the old forward reject.
grep -q '^_ensure_gmail_smtp_ks() {' "$WD" \
    && ok "helper _ensure_gmail_smtp_ks defined" \
    || bad "helper _ensure_gmail_smtp_ks missing"
# Call sites are a whole line `_ensure_gmail_smtp_ks` (optional indent).
# The definition `_ensure_gmail_smtp_ks() {` does not match `$`.
# GNU grep treats `\t` as a stray escape, so use [[:space:]] not \t.
_calls=$(grep -c '^[[:space:]]*_ensure_gmail_smtp_ks$' "$WD" 2>/dev/null || true)
: "${_calls:=0}"
[ "$_calls" -ge 3 ] && ok "helper called at >=3 sites ($_calls)" \
    || bad "helper call sites=$_calls want >=3 (adopt/startup/connect)"

# T8b: load a pre-gmail killswitch, run the helper, accept must appear
# before reject.  Second run must not duplicate the accept rule.
if command -v nft >/dev/null 2>&1 && $NS true >/dev/null 2>&1; then
    grep -v 'gmail_smtp' "$TMP/ks.nft" > "$TMP/ks-old.nft"
    # Extract only _ensure_gmail_smtp_ks (next function is _ensure_dns_enforce).
    awk '/^_ensure_gmail_smtp_ks\(\) \{/,/^_ensure_dns_enforce\(\) \{/' "$WD" \
        | head -n -1 > "$TMP/ensure.sh"
    cat > "$TMP/run-ensure.sh" << 'EOS'
set -u
PLATFORM=router
log() { :; }
nft -f "$1"
# shellcheck disable=SC1091
. "$2"
_ensure_gmail_smtp_ks
_ensure_gmail_smtp_ks
nft list chain inet killswitch forward
EOS
    # bash: helper uses local.  /bin/sh on this host is bash, but dash
    # (Debian) rejects local outside a function when the driver is sh.
    OUT="$($NS bash "$TMP/run-ensure.sh" "$TMP/ks-old.nft" "$TMP/ensure.sh" 2>/dev/null || true)"
    echo "$OUT" | grep -q 'ip daddr @gmail_smtp tcp dport' \
        && ok "helper inserts gmail accept into old killswitch" \
        || bad "helper did not insert gmail accept"
    acc=$(echo "$OUT" | grep -c 'ip daddr @gmail_smtp tcp dport' || true)
    [ "$acc" -eq 1 ] && ok "helper is idempotent (1 v4 accept)" \
        || bad "helper not idempotent: v4 accept count=$acc"
    # order: accept line number < icmp host-unreachable
    if echo "$OUT" | awk '
        /ip daddr @gmail_smtp tcp dport/ && /accept/ { a=NR }
        /reject with icmp host-unreachable/ { r=NR }
        END { exit !(a && r && a<r) }'; then
        ok "helper accept sits before IPv4 reject"
    else
        bad "helper accept not before IPv4 reject"
    fi
    if echo "$OUT" | awk '
        /ip6 daddr @gmail_smtp6 tcp dport/ && /accept/ { a=NR }
        /reject with icmpv6 addr-unreachable/ { r=NR }
        END { exit !(a && r && a<r) }'; then
        ok "helper v6 accept sits before IPv6 reject"
    else
        bad "helper v6 accept not before IPv6 reject"
    fi
else
    echo "SKIP: helper nft load (no nft or unshare)"
fi

# injection: drop the helper definition -> T8 grep fails
if grep -q '^_ensure_gmail_smtp_ks() {' "$WD"; then
    ok "injection target present (helper definition)"
else
    bad "cannot inject: helper still missing"
fi

bash -n "$WD" && ok "bash -n watchdog" || bad "bash -n watchdog"
bash -n tests/test_gmail_smtp_bypass.sh && ok "bash -n self" || bad "bash -n self"

echo
echo "fail=$fail"
exit "$fail"
