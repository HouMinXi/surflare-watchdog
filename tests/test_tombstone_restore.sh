#!/usr/bin/env bash
# Tombstone-restore gap (spec .planning/specs/2026-09-13-tombstone-restore-gap.md).
# The health-success branch must restore the LAN tproxy table when it is
# missing OR present-but-tombstoned (REJECT in place of tproxy rules).
# shellcheck disable=SC2015,SC2016  # ok/bad idiom; $1/$2 are for the inner sh -c
set -u
cd "$(dirname "$0")/.." || exit 1
WD="surflare_watchdog.sh"
fail=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- static: helper defined + wired into the health-success branch ---
grep -q '^_lan_tproxy_needs_restore()' "$WD" \
    && ok "helper defined" || bad "helper _lan_tproxy_needs_restore missing"

# The call must sit inside the health-success branch: after the branch
# comment marker and before _install_cn_dns_direct.
HEALTH_START=$(grep -n 'VPN healthy -- Google 200' "$WD" | head -1 | cut -d: -f1)
CALL_LINE=$(awk '/if _lan_tproxy_needs_restore; then/ {print NR; exit}' "$WD")
CN_DNS_LINE=$(awk -v s="$HEALTH_START" 'NR>s && /_install_cn_dns_direct$/ {print NR; exit}' "$WD")
if [ -n "$HEALTH_START" ] && [ -n "$CALL_LINE" ] && [ -n "$CN_DNS_LINE" ] \
   && [ "$CALL_LINE" -gt "$HEALTH_START" ] && [ "$CALL_LINE" -lt "$CN_DNS_LINE" ]; then
    ok "helper called inside health-success branch"
else
    bad "helper call not in health-success branch (health=$HEALTH_START call=$CALL_LINE cndns=$CN_DNS_LINE)"
fi

# The old presence-only guard must be gone from the health branch.
if sed -n "${HEALTH_START},${CN_DNS_LINE}p" "$WD" | grep -q 'nft list table inet sw_lan_tproxy >/dev/null 2>&1; then'; then
    bad "stale presence-only guard still in health branch"
else
    ok "presence-only guard replaced"
fi

# --- functional: real nft in an isolated namespace, real helper code ---
# Extract the helper verbatim from the watchdog so the test never carries
# a second copy of the logic.
awk '/^_lan_tproxy_needs_restore\(\)/,/^}/' "$WD" > "$TMP/helper.sh"
if [ -s "$TMP/helper.sh" ] && grep -q 'grep -q' "$TMP/helper.sh"; then
    ok "helper extracted ($(wc -l < "$TMP/helper.sh") lines)"
else
    bad "helper extraction failed"
fi
# A truncated extraction (e.g. a future refactor adds a column-0 '}' inside
# the helper) must fail loudly here, not produce a partial function whose
# syntax error makes case B pass for the wrong reason.
sh -n "$TMP/helper.sh" 2>"$TMP/syntax.log" \
    && ok "extracted helper is syntactically complete" \
    || { bad "extracted helper failed sh -n (truncated extraction?)"; cat "$TMP/syntax.log"; }

# rc contract: 0 = predicate true, 1 = predicate false, 99 = setup broke
# inside the namespace (never a predicate answer).  Output goes to a log
# so a CI failure has the nft error text to work with.
run_case() {  # $1 = A|B|C, $2 = helper file, $3 = output log
    $NS sh -c '
        . "$2"
        case "$1" in
        B)
            nft add table inet sw_lan_tproxy &&
            nft add chain inet sw_lan_tproxy prerouting { type filter hook prerouting priority 0\; } &&
            nft add rule inet sw_lan_tproxy prerouting iifname "br-lan" meta l4proto tcp tproxy ip to :10800 meta mark set 0x1 accept ||
                exit 99
            ;;
        C)
            nft add table inet sw_lan_tproxy &&
            nft add chain inet sw_lan_tproxy prerouting { type filter hook prerouting priority 0\; } &&
            nft add rule inet sw_lan_tproxy prerouting iifname "br-lan" meta l4proto tcp reject with tcp reset ||
                exit 99
            ;;
        esac
        [ "$1" = A ] || nft list table inet sw_lan_tproxy >/dev/null 2>&1 || exit 99
        _lan_tproxy_needs_restore
    ' _ "$1" "$2" >"$3" 2>&1
}
NS="unshare -Urn"

rc=0; run_case A "$TMP/helper.sh" "$TMP/A.log" || rc=$?
[ "$rc" = 0 ] && ok "A: no table -> needs restore" \
              || { bad "A: no table not detected (rc=$rc)"; cat "$TMP/A.log"; }
rc=0; run_case B "$TMP/helper.sh" "$TMP/B.log" || rc=$?
[ "$rc" = 1 ] && ok "B: tproxy shape -> no restore" \
              || { bad "B: healthy shape should NOT need restore (rc=$rc)"; cat "$TMP/B.log"; }
rc=0; run_case C "$TMP/helper.sh" "$TMP/C.log" || rc=$?
[ "$rc" = 0 ] && ok "C: tombstoned (REJECT) -> needs restore" \
              || { bad "C: tombstone not detected (rc=$rc)"; cat "$TMP/C.log"; }

# --- teeth 1: drop the leading negation -> case B must flip to "restore" ---
sed 's/! nft list chain inet sw_lan_tproxy prerouting/nft list chain inet sw_lan_tproxy prerouting/' \
    "$TMP/helper.sh" > "$TMP/helper_inv.sh"
if ! cmp -s "$TMP/helper.sh" "$TMP/helper_inv.sh"; then
    rc=0; run_case B "$TMP/helper_inv.sh" "$TMP/inv.log" || rc=$?
    [ "$rc" = 0 ] && ok "injection(invert): B flipped as predicted" \
                  || { bad "injection(invert): B did not flip -- suite toothless (rc=$rc)"; cat "$TMP/inv.log"; }
else
    bad "injection(invert): sed produced no change"
fi

# --- teeth 2: wrong port in the match pattern -> case B must flip ---
sed "s/tproxy\.\*10800/tproxy.*99999/" "$TMP/helper.sh" > "$TMP/helper_wrongport.sh"
if ! cmp -s "$TMP/helper.sh" "$TMP/helper_wrongport.sh"; then
    rc=0; run_case B "$TMP/helper_wrongport.sh" "$TMP/wp.log" || rc=$?
    [ "$rc" = 0 ] && ok "injection(wrong-port): B flipped as predicted" \
                  || { bad "injection(wrong-port): B did not flip -- suite toothless (rc=$rc)"; cat "$TMP/wp.log"; }
else
    bad "injection(wrong-port): sed produced no change"
fi


# --- teeth 3: template md5 drift (hot-replaced nft file) ----------------
# Case D: live tproxy shape is healthy but the on-disk template hash
# differs from the stamp -> must restore.  Case E: hashes match -> must
# not.  The stamp and template live under TMP so the real /etc and /run
# are never touched; the helper's literal paths are retargeted with sed
# (a user namespace cannot bind-mount system directories).
mkdir -p "$TMP/etc" "$TMP/run"
cp router/rule/surflare-lan-tproxy.nft "$TMP/etc/surflare-lan-tproxy.nft"
md5sum "$TMP/etc/surflare-lan-tproxy.nft" > "$TMP/run/stamp.match"
echo "deadbeefdeadbeefdeadbeefdeadbeef  /etc/surflare-lan-tproxy.nft" > "$TMP/run/stamp.drift"

run_drift() {  # $1 = stamp file, $2 = helper, $3 = log
    # unshare -Urn cannot bind-mount system dirs, so retarget the
    # helper's literal paths at the TMP fixtures instead.
    local _h="$TMP/helper.retarget.sh"
    sed -e "s|/etc/surflare-lan-tproxy.nft|$TMP/etc/surflare-lan-tproxy.nft|"         -e "s|\"\$TPROXY_NFT_STAMP\"|$1|" "$2" > "$_h"
    $NS sh -c '
        . "$1"
        nft add table inet sw_lan_tproxy &&
        nft add chain inet sw_lan_tproxy prerouting { type filter hook prerouting priority 0\; } &&
        nft add rule inet sw_lan_tproxy prerouting iifname "br-lan" meta l4proto tcp tproxy ip to :10800 meta mark set 0x1 accept ||
            exit 99
        _lan_tproxy_needs_restore
    ' _ "$_h" >"$3" 2>&1
}

rc=0; run_drift "$TMP/run/stamp.drift" "$TMP/helper.sh" "$TMP/D.log" || rc=$?
[ "$rc" = 0 ] && ok "D: template md5 drift -> needs restore" \
              || { bad "D: drifted template not detected (rc=$rc)"; cat "$TMP/D.log"; }
rc=0; run_drift "$TMP/run/stamp.match" "$TMP/helper.sh" "$TMP/E.log" || rc=$?
[ "$rc" = 1 ] && ok "E: template md5 match -> no restore" \
              || { bad "E: matching template should NOT restore (rc=$rc)"; cat "$TMP/E.log"; }

# Injection: strip the md5 comparison out of the extracted helper.  Case D
# must then say "no restore" -- if it still restores, the new assertion is
# passing for some other reason and has no teeth.
awk '/^_lan_tproxy_needs_restore\(\)/,/^}/' "$WD" \
    | sed '/md5sum \/etc\/surflare-lan-tproxy.nft/,/fi$/d' > "$TMP/helper_nomd5.sh"
if ! cmp -s "$TMP/helper.sh" "$TMP/helper_nomd5.sh" && sh -n "$TMP/helper_nomd5.sh"; then
    rc=0; run_drift "$TMP/run/stamp.drift" "$TMP/helper_nomd5.sh" "$TMP/Dinj.log" || rc=$?
    [ "$rc" = 1 ] && ok "injection(no-md5): D flipped as predicted" \
                  || { bad "injection(no-md5): D did not flip -- suite toothless (rc=$rc)"; cat "$TMP/Dinj.log"; }
else
    bad "injection(no-md5): sed produced no valid change"
fi

# Empty stamp path must not read stdin.  awk of a quoted empty filename
# blocks while stdin is held open; the health tick would stall.  Feed a
# held-open stdin and require a return inside a few seconds.
awk '/^_lan_tproxy_needs_restore\(\)/,/^}/' "$WD" \
    | sed "s|/etc/surflare-lan-tproxy.nft|$TMP/etc/surflare-lan-tproxy.nft|" \
    > "$TMP/helper_hold.sh"
rc=0
timeout 8 $NS sh -c '
    . "$1"
    TPROXY_NFT_STAMP=
    nft add table inet sw_lan_tproxy &&
    nft add chain inet sw_lan_tproxy prerouting { type filter hook prerouting priority 0\; } &&
    nft add rule inet sw_lan_tproxy prerouting iifname "br-lan" meta l4proto tcp tproxy ip to :10800 meta mark set 0x1 accept ||
        exit 99
    _lan_tproxy_needs_restore
' _ "$TMP/helper_hold.sh" >"$TMP/hold.log" 2>&1 < <(sleep 30) || rc=$?
case "$rc" in
    0|1) ok "F: empty stamp path returns with stdin held open (rc=$rc)" ;;
    124) bad "F: empty stamp path blocked on stdin" ;;
    *) bad "F: empty stamp path unexpected rc=$rc"; cat "$TMP/hold.log" ;;
esac

[ "$fail" -eq 0 ]
