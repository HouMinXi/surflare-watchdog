#!/usr/bin/env bash
# The surflare control plane (www.surflare.com) must be reachable from
# LAN clients even when the tunnel is dead.  2026-10-02 outage: tunnel
# auth-rejected, sing-box dead, and every LAN browser hitting the control
# panel got ERR_CONNECTION_REFUSED because the tproxy prerouting chain
# has no server-endpoint return -- LAN 443 goes into the dead tproxy and
# sing-box RSTs it.  The N100's own watchdog probes are fine (OUTPUT
# chain killswitch server_ips bypass + --interface pppoe-wan); LAN
# clients were blind.
#
# The fix mirrors the gmail-smtp pattern: SmartDNS fills a
# surflare_control nftset (via the domestic group so resolution survives
# a dead tunnel), the tproxy prerouting chain returns that traffic to
# the WAN, and the killswitch forward chain accepts it -- both natively
# in the _install_killswitch heredoc and hot-added idempotently.
#
# Region discipline (four rounds of review): every region is
# comment-stripped (including column-0 headers) and command-anchored.
# Set-family assertions are brace-bounded: the matcher takes the
# 'set surflare_control {' line PLUS up to the closing brace, and the
# family must appear on the match line or inside those braces -- a
# neighboring set can never satisfy it.  The dead-helper guard scans
# the WHOLE body for unconditional exits.  Anchors tolerate nft/shell
# legal reformats: multiline or one-liner sets, 'tproxy to' with or
# without 'ip', trailing comments on call lines, densified if-chains.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

NFT_RULE="router/rule/surflare-lan-tproxy.nft"
NFT_GLB="router/global/surflare-lan-tproxy.nft"
FRAG="router/smartdns/surflare-control.conf.example"
CUSTOM="router/smartdns/custom.conf.example"
WD="surflare_watchdog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# strip_comments <in >out -- drop full-line comments (indented or
# column-0), inline trailing comments, and blank lines.  '#' never
# appears inside a live string in the regions we parse.
strip_comments() {
    sed -e 's/[[:space:]]#.*$//' -e 's/^#.*$//' \
        -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d'
}

# set_family_ok <file> -- exit 0 iff a surflare_control block in
# <file> declares type ipv4_addr within its own braces (same line or up
# to the block's closing brace).  Brace-bounded: a neighbor set cannot
# satisfy the match, and one-liner vs multiline both parse.
# set_family_ok <file> -- exit 0 iff the surflare_control set block in
# <file> declares type ipv4_addr.  Delegates to the quote/comment-aware
# extractor (tests/lib_set_block.py): same-line decoy sets, glued
# comments, braces or '#' inside quoted strings cannot borrow a
# neighbor family, and unbalanced blocks fail closed.
set_family_ok() {
    python3 "$(dirname "$0")/lib_set_block.py" "$1" surflare_control --family         | grep -qx 'ipv4_addr'
}

# helper_add_set_ok <file> -- the hot-add "nft add set ... surflare_control"
# writes its block as a quoted string on a continuation line; the family
# must appear within the following two lines.
# helper_add_set_ok <file> -- the hot-add writes its set block as a
# quoted string.  Find the surflare_control add-set call, take the
# first quoted block after it, and require type ipv4_addr INSIDE that
# block -- a decoy add-set (gmail or otherwise) on the same line or a
# later line cannot satisfy it.
helper_add_set_ok() {
    awk '
        /nft add set/ {
            if (inadd) exit 1          # block ended before its family
            if (!seen && $0 ~ /(^|[^A-Za-z0-9_./-])surflare_control([^A-Za-z0-9_./-]|$)/) { seen=1; inadd=1 }
            next
        }
        # Drop nft comments before judging the family: a comment may
        # quote the other family and must not satisfy the pin.
        { gsub(/comment "[^"]*"/, "") }
        inadd && /(^|[[:space:];])type ipv4_addr/ { found=1; exit }
        inadd && /(^|[[:space:];])type ipv6_addr/ { exit 1 }
        inadd && /2>\/dev\/null|\|\| true/ { exit 1 }
        END { exit !found }
    ' "$1"
}

# --- Region extraction ---
# Killswitch heredoc (same extraction as the gmail test), comment-stripped.
awk '/^destroy table inet killswitch$/,/^NFTEOF$/' "$WD" | sed '/^NFTEOF$/d' | strip_comments > "$TMP/ks.nft"
if [ -s "$TMP/ks.nft" ]; then
    ok "killswitch heredoc extracted"
else
    bad "killswitch heredoc empty"
fi
# Hot-add helper only, comment-stripped.
awk '/^_ensure_surflare_control_ks\(\) \{/{f=1} f{print; line=$0; sub(/#.*/, "", line); d+=gsub(/\{/, "{", line); d-=gsub(/}/, "}", line)} f && d==0{exit}' "$WD" | strip_comments > "$TMP/ensure.sh"
if grep -q 'insert rule' "$TMP/ensure.sh"; then
    ok "hot-add helper extracted"
else
    bad "hot-add helper empty"
fi
# SmartDNS fragment: non-comment, non-blank lines only (NOT strip_comments:
# the '#4:' nftset syntax must survive).
grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$FRAG" > "$TMP/frag.conf"
if [ -s "$TMP/frag.conf" ]; then
    ok "smartdns fragment extracted"
else
    bad "smartdns fragment empty"
fi
# Tproxy templates, comment-stripped.
strip_comments < "$NFT_RULE" > "$TMP/tpl-rule.nft"
strip_comments < "$NFT_GLB" > "$TMP/tpl-global.nft"

# --- 1. tproxy templates: set declared + return ordered before tproxy ---
for r in rule global; do
    f="$TMP/tpl-$r.nft"
    tname="router/$r/surflare-lan-tproxy.nft"
    if set_family_ok "$f"; then
        ok "$tname: surflare_control set declared (ipv4)"
    else
        bad "$tname: no surflare_control set (or wrong family)"
    fi
    if grep -Eq '^[[:space:]]*iifname "br-lan" ip daddr @surflare_control return' "$f" && \
       grep -Eq 'tproxy (ip )?to :10800' "$f"; then
        ret_ln=$(grep -nE '^[[:space:]]*iifname "br-lan" ip daddr @surflare_control return' "$f" | head -1 | cut -d: -f1)
        tpx_ln=$(grep -nE 'tproxy (ip )?to :10800' "$f" | head -1 | cut -d: -f1)
        if [ "$ret_ln" -lt "$tpx_ln" ]; then
            ok "$tname: return ordered before tproxy divert"
        else
            bad "$tname: return sits after tproxy rule"
        fi
    else
        bad "$tname: missing return or tproxy rule (cannot verify order)"
    fi
    if grep -Eq '@surflare_control.*(drop|reject|queue|goto|jump|redirect|accept|dnat|snat|masquerade)' "$f"; then
        bad "$tname: a drop on the control set precedes the return"
    else
        ok "$tname: no drop on the control set"
    fi
    if grep -Eq '@surflare_control.*(meta[[:space:]]+)?mark[[:space:]]+set' "$f"; then
        bad "$tname: a mark set on the control set precedes the return"
    else
        ok "$tname: no mark set on the control set"
    fi
    if grep -Eq '(meta[[:space:]]+)?mark[[:space:]]+set[[:space:]].*return' "$f"; then
        bad "$tname: a marked return precedes the control return"
    else
        ok "$tname: no marked return"
    fi
    if grep -Eq 'daddr[[:space:]]+[^[:space:]]+[[:space:]].*\b(drop|reject|queue|goto|jump)\b' "$f"; then
        bad "$tname: an address match drops before the control return"
    else
        ok "$tname: no address drop"
    fi
    if grep -Eq '^[[:space:]]*include[[:space:]]' "$f"; then
        bad "$tname: an include hides rules the guard does not read"
    else
        ok "$tname: no include in the template"
    fi
    # Only an explicit HIT passes.  MISS means a rule stopped the packet;
    # anything else (LOAD_FAIL when nft refuses the template, an empty
    # string when the namespace cannot be created) is a broken probe, not
    # a pass.
    _probe=$(unshare --user --map-root-user --net python3 "$(dirname "$0")/cp_behavior.py" "$f")
    case "$_probe" in
        HIT)  ok "$tname: a packet reaches the control return" ;;
        MISS) bad "$tname: a rule before the control return stops the packet" ;;
        SETUP_FAIL|LOAD_FAIL)
            bad "$tname: the probe could not run ($_probe), so the template is unverified" ;;
        *)    bad "$tname: packet probe inconclusive ($_probe)" ;;
    esac
done

# --- 2. Heredoc region: native set + forward accept, ordered before reject ---
if set_family_ok "$TMP/ks.nft"; then
    ok "killswitch heredoc: set declared natively (ipv4)"
else
    bad "killswitch heredoc: missing surflare_control set (or wrong family)"
fi
if grep -Eq '^[[:space:]]*iifname "br-lan" ip daddr @surflare_control accept' "$TMP/ks.nft"; then
    ok "killswitch heredoc: forward accept natively"
else
    bad "killswitch heredoc: missing forward accept (crash path rejects control plane)"
fi
# The accept must precede the first reject inside the forward chain.
ks_fwd_start=$(grep -n 'chain forward' "$TMP/ks.nft" | head -1 | cut -d: -f1)
if [ -n "$ks_fwd_start" ]; then
    acc_ln=$(awk -v s="$ks_fwd_start" 'NR>s && /iifname "br-lan" ip daddr @surflare_control accept/ {print NR; exit}' "$TMP/ks.nft")
    rej_ln=$(awk -v s="$ks_fwd_start" 'NR>s && /reject/ {print NR; exit}' "$TMP/ks.nft")
    if [ -n "$acc_ln" ] && [ -n "$rej_ln" ] && [ "$acc_ln" -lt "$rej_ln" ]; then
        ok "killswitch heredoc: accept ordered before reject"
    else
        bad "killswitch heredoc: accept missing or after reject ($acc_ln vs $rej_ln)"
    fi
else
    bad "killswitch heredoc: forward chain not found"
fi

# --- 2b. BEHAVIORAL: run the real helper against a stubbed nft ---
# Textual pins cannot see guard polarity, dead shapes, or decoy
# families; executing the helper can.  The stub records every nft
# invocation; the helper must (a) arm the accept exactly once when the
# killswitch is absent and twice when already armed it must no-op, and
# (b) never call nft on a non-router platform or without a killswitch.
BH="$(mktemp -d)"
export BH
cat > "$BH/nft" <<'BHSTUB'
#!/bin/bash
echo "nft $*" >> "$NFT_LOG"
# 'nft list chain inet killswitch forward' -> empty first call, then
# a chain that already contains the accept (idempotent second run).
if [ "$1 $2 $3" = "list chain inet" ] && [ "$5" = "forward" ]; then
    if [ -f "$NFT_ARMED" ]; then
        echo 'iifname "br-lan" ip daddr @surflare_control accept'
    fi
    exit 0
fi
# 'nft -a list chain inet killswitch forward' -> the real chain has a
# reject line with a handle.  Only that exact listing; any other -a
# invocation falls through.
# 'nft -a ... list chain inet killswitch forward' in any flag grouping.
# Collect the non-flag words; flags may be combined or separate.
# Only a plain '-a list chain inet killswitch forward' (optionally with
# --handle) prints the reject line.  Any other flag changes nft's
# output or makes it fail, so the helper awk finds no handle.  Mirror
# that instead of guessing each flag's semantics.
_flags=""
_rest=""
for _a in "$@"; do
    case "$_a" in
        -*) _flags="$_flags $_a" ;;
        *)  _rest="$_rest $_a" ;;
    esac
done
if [ "$_rest" = " list chain inet killswitch forward" ]; then
    case "$_flags" in
        " -a"|" -a --handle"|" --handle -a"|" --handle") ;;
        *) exit 0 ;;
    esac
    echo 'iifname "br-lan" reject with icmp host-unreachable # handle 42'
    exit 0
fi
# Record which branch armed the accept.  Match the subcommand as its
# own words: a rule body that merely contains the text 'insert rule'
# must not count as the insert branch.
case "$*" in
    'insert rule '*'handle '[0-9]*' '*'ip daddr @surflare_control accept'*) _hw=$(echo "$*" | grep -o 'handle [0-9]* ' | grep -o '[0-9]*')
        [ -n "$_hw" ] && echo "$*" | grep -Eq '^insert rule inet killswitch forward handle [0-9]+ iifname br-lan ip daddr @surflare_control accept$' && echo insert >> "$NFT_BRANCH" && touch "$NFT_ARMED" ;;
    'add rule '*'ip daddr @surflare_control accept'*)    echo append >> "$NFT_BRANCH"; touch "$NFT_ARMED" ;;
esac
exit 0
BHSTUB
chmod +x "$BH/nft"
mkdir -p "$BH/bin"; cp "$BH/nft" "$BH/bin/nft"
# log() and the helper come from the watchdog; source only the helper
# region into a bash stub with the guard variables set.
awk '/^_ensure_surflare_control_ks\(\) \{/{f=1} f{print; line=$0; sub(/#.*/, "", line); d+=gsub(/\{/, "{", line); d-=gsub(/}/, "}", line)} f && d==0{exit}' "$WD" > "$BH/helper.sh"
cat > "$BH/run.sh" <<RUNEOF
#!/bin/bash
PLATFORM=router
log() { :; }
PATH="$BH/bin:\$PATH"
source "\$BH/helper.sh"
_ensure_surflare_control_ks
echo "rc=\$?"
RUNEOF
chmod +x "$BH/run.sh"
NFT_LOG="$BH/nft.log" NFT_ARMED="$BH/armed" NFT_BRANCH="$BH/branch" bash "$BH/run.sh" >/dev/null 2>&1
if [ -f "$BH/armed" ]; then
    n_branch=$(wc -l < "$BH/branch" 2>/dev/null); : "${n_branch:=0}"
    branch=$(cat "$BH/branch" 2>/dev/null)
    if [ "$n_branch" -eq 1 ] && [ "$branch" = "insert" ]; then
        ok "behavioral: insert branch armed exactly once (reject handle present)"
    else
        bad "behavioral: expected one insert arm, got [$branch]"
    fi
else
    bad "behavioral: helper never armed the accept"
fi
# Second run: the chain already has the accept -> neither branch fires.
: > "$BH/nft.log"; : > "$BH/branch"
NFT_LOG="$BH/nft.log" NFT_ARMED="$BH/armed" NFT_BRANCH="$BH/branch" bash "$BH/run.sh" >/dev/null 2>&1
n_branch2=$(wc -l < "$BH/branch" 2>/dev/null); : "${n_branch2:=0}"
if [ "$n_branch2" -eq 0 ]; then
    ok "behavioral: already-armed chain -> no re-arm (idempotent)"
else
    bad "behavioral: helper re-armed an already-armed chain ($n_branch2 arms)"
fi
rm -rf "$BH"

# --- 3. Helper region: hot-add logic, payloads, and aliveness ---
# Payload pinning: every hot-add verdict must insert the accept rule for
# the surflare_control set (not gmail's), on both the insert and append
# branches.
# unanchored: a densified one-liner if-chain puts the nft call after 'then'
n_insert=$(grep -cE 'nft insert rule inet killswitch forward' "$TMP/ensure.sh")
n_append=$(grep -cE 'nft add rule inet killswitch forward' "$TMP/ensure.sh")
if [ "$n_insert" -ge 1 ]; then
    ok "helper: insert-before-reject logic"
else
    bad "helper: no insert rule"
fi
if [ "$n_append" -ge 1 ]; then
    ok "helper: append fallback"
else
    bad "helper: no append fallback"
fi
# Each branch's continuation line carries the accept payload.
n_payload=$(grep -cE 'iifname "br-lan" ip daddr @surflare_control accept' "$TMP/ensure.sh")
if [ "$n_payload" -ge 2 ]; then
    ok "helper: accept payload on both branches ($n_payload)"
else
    bad "helper: accept payload missing from a branch ($n_payload/2)"
fi
# The hot-add 'nft add set' must also be ipv4.
if helper_add_set_ok "$TMP/ensure.sh"; then
    ok "helper: hot-add set is ipv4"
else
    bad "helper: hot-add set family wrong or missing"
fi
if grep -q '_added=1' "$TMP/ensure.sh"; then
    ok "helper: _added gates the armed log"
else
    bad "helper: armed log ungated"
fi
# Idempotency check must look for the surflare_control accept (not gmail's),
# and the armed chain must keep the helper a no-op.  Polarity of these
# lines is verified BEHAVIORALLY (the stubbed-nft run above); here we
# pin only the mechanism, not the spelling: the helper must consult the
# live chain before deciding, and the accept payload must be both the
# thing it greps for and the thing it inserts.
if grep -Eq "grep -q (-F )?'ip daddr @surflare_control accept'" "$TMP/ensure.sh"; then
    ok "helper: idempotency grep checks the surflare_control accept"
else
    bad "helper: idempotency grep does not check the accept payload"
fi
# The PLATFORM/table guards skip off-scope runs; spelled any equivalent
# way (||, if-negated, case).  Polarity is behavioral; the mechanism is
# that the guard references the scope and returns.
# shellcheck disable=SC2016  # pattern must match a literal $PLATFORM
if grep -Eq '\[ "\$PLATFORM" ( ?= ?"router" ?\] ?\|\| ?return|!= ?"router" ?\] ?; ?then ?return)' "$TMP/ensure.sh"; then
    ok "helper: PLATFORM guard present (scope check + return)"
else
    bad "helper: PLATFORM guard missing (runs on every host)"
fi
if grep -Eq 'nft list table inet killswitch( >/dev/null 2>&1)? (\|\||&&) return' "$TMP/ensure.sh"; then
    ok "helper: table guard present (killswitch precheck)"
else
    bad "helper: table guard missing or polarity flipped"
fi
# _need must default to armed; the name is free but the semantics are
# not (an init of 0 makes the whole body dead -- behavioral run catches
# a renamed-but-flipped init; this catches the flip in any spelling).
if grep -Eq '^[[:space:]]*local .*[a-z_]+=1( |$)' "$TMP/ensure.sh"; then
    ok "helper: armed flag initializes to 1 on its local line"
else
    bad "helper: armed flag init missing (body dead)"
fi
# Dead-helper guard, whole body: no unconditional exit anywhere before
# the final verification block.  Conditional guards ([ ] || return 0)
# are fine; bare 'return 0' / 'exit 0' are not.
# Unconditional exits in any spelling: bare 'return 0', 'true && return 0',
# '( exit 0 )', 'return 1'.  A return/exit is UNCONDITIONAL when nothing
# conditional precedes it on the line: the statement starts at the token
# (optionally after '(' or 'true &&'/';'), not after 'test ] &&' / 'cmd ||'.
n_uncond=$(grep -cE '^[[:space:]]*(\([[:space:]]*)?((true|false|:)[[:space:]]+(&&|\|\|)[[:space:]]+)?(exit|return)[[:space:]]+[0-9]+' "$TMP/ensure.sh")
if [ "$n_uncond" -eq 0 ]; then
    ok "helper: no unconditional return/exit in body"
else
    bad "helper: unconditional return/exit kills all wiring ($n_uncond)"
fi
# And the body must be live at all (not entirely commented out).
n_live=$(grep -cvE '^[[:space:]]*$' "$TMP/ensure.sh")
if [ "$n_live" -ge 15 ]; then
    ok "helper body is live ($n_live lines)"
else
    bad "helper body mostly disabled ($n_live lines) - dead helper ships green"
fi

# --- 4. Call sites wired (definition alone must not satisfy) ---
n_calls=$(grep -cE '^[[:space:]]*_ensure_surflare_control_ks([[:space:]]+#.*)?$' "$WD")
if [ "$n_calls" -ge 4 ]; then
    ok "watchdog: $n_calls call sites wired (need >=4)"
else
    bad "watchdog: only $n_calls call sites (need >=4)"
fi

# --- 5. Fragment wiring: exact directive lines ---
if grep -q '^nameserver /www.surflare.com/domestic$' "$TMP/frag.conf"; then
    ok "fragment: www resolves via domestic group"
else
    bad "fragment: www not pinned to domestic (dies with tunnel)"
fi
if grep -q '^nameserver /murk.surflare.com/domestic$' "$TMP/frag.conf"; then
    ok "fragment: murk resolves via domestic group"
else
    bad "fragment: murk not pinned to domestic"
fi
for dom in www murk; do
    line=$(grep -E "^domain-rules /${dom}\.surflare\.com/ " "$TMP/frag.conf" | head -1)
    if [ -z "$line" ]; then
        bad "fragment: ${dom} domain-rule missing"
        continue
    fi
    if echo "$line" | grep -q 'speed-check-mode none'; then
        ok "fragment: ${dom} speed-check disabled"
    else
        bad "fragment: ${dom} speed-check not disabled"
    fi
    if echo "$line" | grep -q '#4:inet#sw_lan_tproxy#surflare_control'; then
        ok "fragment: ${dom} writes tproxy nftset (#4: v4 family pinned)"
    else
        bad "fragment: ${dom} tproxy nftset target missing or wrong family"
    fi
    if echo "$line" | grep -q '#4:inet#killswitch#surflare_control'; then
        ok "fragment: ${dom} writes killswitch nftset (#4: v4 family pinned)"
    else
        bad "fragment: ${dom} killswitch nftset target missing or wrong family"
    fi
done

# --- 6. custom.conf.example wires the fragment ---
if grep -q '^conf-file /etc/smartdns/surflare-control.conf$' "$CUSTOM"; then
    ok "custom.conf.example: fragment wired"
else
    bad "custom.conf.example: fragment not wired (inert deploy)"
fi

# --- 7. Syntax ---
if bash -n "$WD"; then
    ok "bash -n watchdog"
else
    bad "bash -n watchdog"
fi

# The set timeout is part of the bypass: 1s drops the control-plane
# element before the next packet, and the forward rule rejects it.
# Every surflare_control set block must keep the timeout at 3600
# seconds; any nft spelling counts (1h, 60m, 3600s, bare 3600).
# The last 'timeout' keyword on a line wins in nft, so 'timeout 1h;
# timeout 1s' is 1s.  A substring match would accept '1h1s'.
for _f in surflare_watchdog.sh router/global/surflare-lan-tproxy.nft router/rule/surflare-lan-tproxy.nft; do
    [ -f "$_f" ] || continue
    _bad=$(awk '{while (/\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, " "); getline n; $0 = $0 n } c=$0; gsub(/"[^"]*"/, "", c); sub(/#.*/, "", c)} f && c ~ /(^|[[:space:]])(set|add set)([[:space:]]|$)/ && c !~ /surflare_control/{f=0} c ~ /(set|add set).*surflare_control/{f=1} f{print}' "$_f" | grep -E "timeout[[:space:]]+[0-9]" | while read -r _l; do
        _n=$(echo "$_l" | grep -oE "timeout[[:space:]]+[0-9][0-9a-z]*" | awk \
            '{ v=$2; n=v; u="";
               if (v ~ /[a-z]$/) { u=substr(v,length(v)); n=substr(v,1,length(v)-1) }
               s = (u=="h") ? n*3600 : (u=="m") ? n*60 : (u=="s"||u=="") ? n : -1;
               if (s != 3600) c++ }
             END { print c+0 }')
        [ "$_n" -gt 0 ] && echo "$_l"
    done)
    if [ -z "$_bad" ]; then
        ok "$_f surflare_control timeout is 1h (3600s, any spelling)"
    else
        bad "$_f surflare_control timeout is not 3600 seconds"
    fi
done

# The two tproxy templates describe the same table and they have drifted
# before: one carried the post-reconnect burst guard and the other did not, so
# the same box behaved differently depending on the mode it was installed in.
strip_c() { grep -v '^[[:space:]]*#' "$1" | sed '/^[[:space:]]*$/d'; }
if strip_c router/rule/surflare-lan-tproxy.nft > "$TMP/rule.flat" 2>/dev/null &&
	strip_c router/global/surflare-lan-tproxy.nft > "$TMP/global.flat" 2>/dev/null; then
	if diff -q "$TMP/rule.flat" "$TMP/global.flat" >/dev/null; then
		ok "the two tproxy templates are identical apart from comments"
	else
		bad "the tproxy templates have drifted apart: $(diff "$TMP/rule.flat" "$TMP/global.flat" | head -4 | tr '\n' ' ')"
	fi
else
	bad "could not read both tproxy templates"
fi

echo "FAIL=$fail"
exit $fail
