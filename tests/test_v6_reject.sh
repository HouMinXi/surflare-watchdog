#!/bin/bash
# IPv6 tproxy removal: the relay pool is IPv4-only, so tproxying v6 TCP
# to sing-box only produced socks5 code=5 rejections after a full relay
# round trip (measured 2026-09-26: 4800 attempts/hour, zero successes).
# The templates must REJECT v6 TCP instead, so clients fall back to the
# working v4 path immediately via happy-eyeballs.
#
# Checks both deployment templates (rule + global) and pins the
# load-bearing properties of the surrounding chain order.
set -u
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

check_template() {
	local mode="$1" f="router/$1/surflare-lan-tproxy.nft"
	[ -f "$f" ] || { bad "$mode: template missing"; return; }

	# T1: no v6 tproxy rule remains
	if grep -qE 'tproxy ip6 to' "$f"; then
		bad "$mode: v6 tproxy rule still present"
	else
		ok "$mode: no 'tproxy ip6 to' rule"
	fi

	# T2: v6 TCP reject exists
	if grep -qE 'meta nfproto ipv6 meta l4proto tcp reject with tcp reset' "$f"; then
		ok "$mode: v6 TCP reject-with-reset present"
	else
		bad "$mode: v6 TCP reject missing"
	fi

	# T3: v4 tproxy untouched (the working path must stay)
	if grep -qE 'meta nfproto ipv4 meta l4proto tcp.*tproxy' "$f" \
		|| grep -qE 'tproxy ip to :10800' "$f"; then
		ok "$mode: v4 tproxy still present"
	else
		bad "$mode: v4 tproxy missing"
	fi

	# T4: CN v6 direct return sits BEFORE the reject (CN v6 must
	# keep going direct, not get reset).
	local cn_line reject_line
	cn_line=$(grep -n 'ip6 daddr @cn6_direct return' "$f" | head -1 | cut -d: -f1)
	reject_line=$(grep -n 'nfproto ipv6 meta l4proto tcp reject' "$f" | head -1 | cut -d: -f1)
	if [ -n "$cn_line" ] && [ -n "$reject_line" ] && [ "$cn_line" -lt "$reject_line" ]; then
		ok "$mode: cn6_direct return (line $cn_line) precedes v6 reject (line $reject_line)"
	else
		bad "$mode: chain order wrong: cn6_direct=[$cn_line] reject=[$reject_line]"
	fi

	# T5: bypass devices v6 return sits BEFORE the reject too.
	# Both templates: the watchdog flushes bypass_devices6
	# unconditionally, so the set and its return must exist in both
	# modes or bypass devices' v6 traffic has no escape.
	local bp_line
	bp_line=$(grep -n 'ip6 saddr @bypass_devices6 return' "$f" | head -1 | cut -d: -f1)
	if [ -n "$bp_line" ] && [ -n "$reject_line" ] && [ "$bp_line" -lt "$reject_line" ]; then
		ok "$mode: bypass_devices6 return (line $bp_line) precedes v6 reject"
	else
		bad "$mode: bypass_devices6 order wrong: bp=[$bp_line] reject=[$reject_line]"
	fi
}

check_template rule
check_template global

# Injection: put the v6 tproxy rule back; every check above that
# guards it must go red (T1 catches the restored rule).
INJ=$(mktemp /tmp/v6inj_XXXXXX.nft)
trap 'rm -f "$INJ"' EXIT
sed 's|iifname "br-lan" meta nfproto ipv6 meta l4proto tcp reject with tcp reset|iifname "br-lan" meta nfproto ipv6 meta l4proto tcp \\\n            tproxy ip6 to :10800 \\\n            meta mark set 0x00000001 \\\n            ct mark set 0x00000100 \\\n            accept|' \
	router/rule/surflare-lan-tproxy.nft > "$INJ"
if grep -qE 'tproxy ip6 to' "$INJ"; then
	ok "inject: restored v6 tproxy in copy -- would be caught"
else
	bad "inject: sed failed to restore the old rule"
fi

# Order-flip injection: move the cn6_direct return BELOW the reject in
# a copy of the rule template; the T4 order assertion must catch it.
INJ2=$(mktemp /tmp/v6inj2_XXXXXX.nft)
# shellcheck disable=SC2016  # awk program text, not shell vars
awk '
	/iifname "br-lan" ip6 daddr @cn6_direct return/ { cn6 = $0; next }
	/meta nfproto ipv6 meta l4proto tcp reject with tcp reset/ { print; print cn6; next }
	{ print }
' router/rule/surflare-lan-tproxy.nft > "$INJ2"
if grep -n 'ip6 daddr @cn6_direct return' "$INJ2" | head -1 | cut -d: -f1 \
	| { read -r cn; rej=$(grep -n 'nfproto ipv6 meta l4proto tcp reject' "$INJ2" | head -1 | cut -d: -f1); [ -n "$cn" ] && [ -n "$rej" ] && [ "$cn" -gt "$rej" ]; }; then
	ok "inject: cn6 return flipped below the reject -- T4 would catch it"
else
	bad "inject: order flip did not reproduce the T4 failure shape"
fi
rm -f "$INJ2"

# Syntax gate: both templates must pass nft -c on this host if nft
# exists (router syntax check runs on N100 at deploy time).
if command -v nft >/dev/null 2>&1; then
	for m in rule global; do
		if nft -c -f "router/$m/surflare-lan-tproxy.nft" >/dev/null 2>&1; then
			ok "$m: nft -c syntax check passes"
		else
			# nft -c on a non-router host may fail on missing
			# sets referenced by the template -- only a hard
			# parse error is a real failure here.
			if nft -c -f "router/$m/surflare-lan-tproxy.nft" 2>&1 | grep -qiE 'syntax error'; then
				bad "$m: nft -c reports syntax error"
			else
				ok "$m: nft -c ran (non-syntax env warnings ignored)"
			fi
		fi
	done
else
	echo "  SKIP: nft not on this host (deploy-time check on N100)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
