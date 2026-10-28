#!/usr/bin/env bash
# z66 and W1 keep the tailnet when the proxy dies.
#
# On 2026-10-28 the proxy lost every relay, the watchdog armed its killswitch
# (policy drop), and both hosts fell off the tailnet at the same moment.  Two
# things were missing from the exemption sets:
#
#   relays    our own DERP (region 900, 101.132.101.215).  The tailnet policy
#             sets omitDefaultRegions, so no Tailscale region is ever selected
#   control   the 192.200.0.0/24 control plane behind
#             controlplane/api/login.tailscale.com -- tailscaled holds a
#             long-lived connection there, and losing it costs the netmap
#
# Every rule assertion runs against the ruleset as nft renders it after loading
# it in a private network namespace, not against the source text.  Judging the
# text cost two review rounds: a rule wrapped with a trailing backslash, a
# one-host-per-line source set, or a bare `ip daddr 100.64.0.0/10 return`
# instead of the brace list all read as broken while behaving identically --
# and a commented-out element or a rule parked in the wrong chain read as fine.
# The kernel's rendering has neither problem.  What stays text-based is what
# nft cannot tell us: the set attributes and the install list.
#
# The three copies must agree: two nft templates a deploy installs, plus the
# heredoc the watchdog builds the killswitch from -- only that last one is
# consulted while the proxy is down.
# shellcheck disable=SC2015
set -u
cd "$(dirname "$0")/.." || exit 1

WD="surflare_watchdog.sh"
RULE="router/rule/surflare-lan-tproxy.nft"
GLOBAL="router/global/surflare-lan-tproxy.nft"
BOOTLOCK="router/services/procd/surflare-bootlock"

# Our own DERP is the only relay left: the tailnet policy omits the default
# regions, so no Tailscale node can be selected.
EXPECTED_RELAYS='101.132.101.215'
EXPECTED_CONTROL='192.200.0.0/24'
# The two hosts the exemption is for, and every destination it may name.
EXPECTED_DESTS='101.132.101.215
192.200.0.0/24'

fail=0
pass=0
skip=0
ok()   { echo "PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }
note() { echo "SKIP: $1"; skip=$((skip + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The body of one set, comments stripped and whitespace collapsed -- used only
# for attributes nft does not render (a timeout would show up in the kernel,
# but not as a rule; keeping this text-based is deliberate).
set_body() {
	sed 's/#.*//' "$1" |
		awk -v name="$2" '
			$0 ~ "set " name "[[:space:]]*\\{" { inside = 1 }
			inside && /^[[:space:]]*\}[[:space:]]*$/ { inside = 0 }
			inside
		' | tr '\n' ' ' | tr -s '[:space:]' ' '
}

# --- extraction -------------------------------------------------------------
awk '/^destroy table inet killswitch$/,/^NFTEOF$/' "$WD" |
	sed '/^NFTEOF$/d' > "$TMP/ks.nft"
[ -s "$TMP/ks.nft" ] && ok "killswitch template extracted" || bad "killswitch template empty"
# Counted by the table each installer names, not by how it is spelled: a
# second one written as `add table` or indented under `<<-` would hide an edit
# to the effective one.
n=$(grep -cE '(add|destroy) table inet killswitch( |$)' "$WD")
if [ "$n" -eq 1 ]; then
	ok "the watchdog carries exactly one killswitch template"
else
	bad "the watchdog names the killswitch table in $n places"
fi

awk "/nft -f - <<'NFTEOF'/,/^NFTEOF\$/" "$BOOTLOCK" |
	sed "1d;/^NFTEOF\$/d" > "$TMP/bootlock.nft"
[ -s "$TMP/bootlock.nft" ] && ok "boot lock ruleset extracted" || bad "boot lock ruleset empty"

# --- load, or stop here -----------------------------------------------------
# An artifact that does not parse is one the watchdog cannot install at the
# moment the proxy dies, which is the only moment it matters.
if ! command -v unshare >/dev/null 2>&1 || ! unshare -rn true 2>/dev/null; then
	note "no user namespaces, nothing was loaded and no rule was judged"
	echo "RESULT: $pass passed, $fail failed, $skip skipped"
	exit "$fail"
fi

# load_and_dump <file> -> canonical `nft list ruleset`; non-zero on parse error.
load_and_dump() {
	unshare -rn sh -c 'nft -f "$1" >/dev/null 2>&1 && nft list ruleset' _ "$1"
}

# The rules of one chain from a rendered ruleset.
chain_lines() {
	printf '%s\n' "$1" | awk -v c="$2" '
		$0 ~ "^[[:space:]]*chain " c " \\{" { inside = 1; next }
		inside && /^[[:space:]]*\}[[:space:]]*$/ { inside = 0 }
		inside
	'
}

# Element tokens of one rendered set.
set_tokens() {
	printf '%s\n' "$1" | awk -v n="$2" '
		$0 ~ "^[[:space:]]*set " n " \\{" { inside = 1 }
		inside && /^[[:space:]]*\}[[:space:]]*$/ { inside = 0 }
		inside
	' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?' | sort -u
}

# Destinations an exemption rule carries, from a rendered chain.  The rule must
# name both hosts; the kernel keeps them in one brace group however the file
# was written, so wrap style and ordering do not matter here.
exempt_dests() {
	printf '%s\n' "$1" |
		grep -E "ip saddr \{ 192\.168\.100\.(10|12), 192\.168\.100\.(10|12) \}" |
		grep -E "$2\$" |
		grep -oE '(@[a-z_]+|([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?)' |
		grep -v '^192\.168\.100\.' | sort -u
}

# --- the three copies agree, as the kernel renders them ---------------------
for pair in "rule:$RULE" "global:$GLOBAL" "watchdog-killswitch:$TMP/ks.nft"; do
	name="${pair%%:*}"
	file="${pair#*:}"
	if ! dump="$(load_and_dump "$file" 2>"$TMP/err")"; then
		bad "$name: the ruleset does not load: $(head -2 "$TMP/err" | tr '\n' ' ')"
		continue
	fi
	ok "$name: the ruleset loads"

	for spec in "derp_asia:$EXPECTED_RELAYS" "ts_control:$EXPECTED_CONTROL"; do
		set="${spec%%:*}"
		want="$(printf '%s\n' "${spec#*:}" | sort -u)"
		got="$(set_tokens "$dump" "$set")"
		if [ -n "$got" ] && [ "$got" = "$want" ]; then
			ok "$name: $set holds exactly [$(printf '%s' "$want" | tr '\n' ' ')]"
		else
			bad "$name: $set holds [$(printf '%s' "$got" | tr '\n' ' ')], expected [$(printf '%s' "$want" | tr '\n' ' ')]"
		fi
		# Static sets: a timeout would let entries expire on their own, which
		# is how gmail_smtp works and not what either of these is for.
		if printf '%s' "$(set_body "$file" "$set")" | grep -q 'timeout'; then
			bad "$name: $set carries a timeout"
		else
			ok "$name: $set is static (no timeout)"
		fi
	done
done

# --- the exemption is in the deciding chain, and nothing swallows it --------
for pair in "rule:$RULE" "global:$GLOBAL"; do
	name="${pair%%:*}"
	file="${pair#*:}"
	dump="$(load_and_dump "$file")" || continue
	chain="$(chain_lines "$dump" prerouting)"
	for set in derp_asia ts_control; do
		if printf '%s\n' "$chain" | grep -qE "ip daddr @${set} return$"; then
			ok "$name: prerouting returns to @$set"
		else
			bad "$name: prerouting has no return to @$set"
		fi
	done
	ret_at=$(printf '%s\n' "$chain" | grep -n 'ip daddr @derp_asia return$' | head -1 | cut -d: -f1)
	tp_at=$(printf '%s\n' "$chain" | grep -n 'tproxy ip to :10800' | head -1 | cut -d: -f1)
	if [ -n "$ret_at" ] && [ -n "$tp_at" ] && [ "$ret_at" -lt "$tp_at" ]; then
		ok "$name: the exemption precedes the tproxy rule"
	else
		bad "$name: exemption at ${ret_at:-absent}, tproxy at ${tp_at:-absent}"
	fi
	# An unconditional br-lan verdict before it would make the exemption dead.
	if printf '%s\n' "$chain" | head -n "$(( ${ret_at:-1} - 1 ))" |
		grep -qE '^[[:space:]]*iifname "br-lan" (return|accept)$'; then
		bad "$name: an unconditional br-lan verdict precedes the exemption"
	else
		ok "$name: the exemption is reachable"
	fi
	# 100.95.78.8 rides the CGNAT range; any return covering it will do, in
	# either the brace-list form or a rule of its own.
	if printf '%s\n' "$chain" | grep -E 'return$' | grep -q '100\.64\.0\.0/10'; then
		ok "$name: prerouting returns the CGNAT range"
	else
		bad "$name: prerouting no longer returns 100.64.0.0/10"
	fi
done

dump="$(load_and_dump "$TMP/ks.nft")" || dump=""
kchain="$(chain_lines "$dump" forward)"
if [ -n "$kchain" ]; then
	ksrej=$(printf '%s\n' "$kchain" | grep -n 'reject with icmp host-unreachable' | head -1 | cut -d: -f1)
	# Whole set, the same way the boot lock is checked: a rule that names only
	# one of the two hosts still ends in `ip daddr @set accept` and would pass a
	# check that only looks at the destination.
	want=$(printf '%s\n' "@derp_asia" "@ts_control" | sort -u)
	got=$(exempt_dests "$kchain" accept)
	if [ -n "$got" ] && [ "$got" = "$want" ]; then
		ok "killswitch: forward exempts exactly [$want] for .10/.12"
	else
		bad "killswitch: forward exempts [$(printf '%s' "$got" | tr '\n' ' ')], expected [$want]"
	fi
	for set in derp_asia ts_control; do
		acc=$(printf '%s\n' "$kchain" |
			grep -nE "ip saddr \{ 192\.168\.100\.(10|12), 192\.168\.100\.(10|12) \} ip daddr @${set} accept$" |
			head -1 | cut -d: -f1)
		if [ -n "$ksrej" ] && [ -n "$acc" ] && [ "$acc" -lt "$ksrej" ]; then
			ok "killswitch: @$set accepted before the reject"
		else
			bad "killswitch: @$set accept at ${acc:-absent}, reject at ${ksrej:-absent}"
		fi
	done
	if set_tokens "$dump" lan_ranges | grep -qx '100.64.0.0/10'; then
		ok "killswitch: lan_ranges still carries the CGNAT range"
	else
		bad "killswitch: lan_ranges lost 100.64.0.0/10"
	fi
else
	bad "killswitch: no forward chain in the rendered ruleset"
fi

# --- the boot lock carries the same exemption, and only it ------------------
if ! dump="$(load_and_dump "$TMP/bootlock.nft" 2>"$TMP/err")"; then
	bad "boot lock does not load: $(head -2 "$TMP/err" | tr '\n' ' ')"
else
	ok "boot lock ruleset loads"
	bchain="$(chain_lines "$dump" forward)"
	want="$(printf '%s\n' "$EXPECTED_DESTS" | sort -u)"
	got="$(exempt_dests "$bchain" accept)"
	# Whole set, not two literals: an extra destination here is an extra hole.
	if [ -n "$got" ] && [ "$got" = "$want" ]; then
		ok "boot lock exempts exactly [$(printf '%s' "$want" | tr '\n' ' ')] for .10/.12"
	else
		bad "boot lock exempts [$(printf '%s' "$got" | tr '\n' ' ')], expected [$(printf '%s' "$want" | tr '\n' ' ')]"
	fi
	brej=$(printf '%s\n' "$bchain" | grep -n 'reject with icmp host-unreachable' | head -1 | cut -d: -f1)
	blast=$(printf '%s\n' "$bchain" | grep -nE 'ip daddr (@[a-z_]+|101\.132\.101\.215|192\.200\.0\.0/24) accept$' | tail -1 | cut -d: -f1)
	if [ -n "$blast" ] && [ -n "$brej" ] && [ "$blast" -lt "$brej" ]; then
		ok "boot lock exempts before the reject"
	else
		bad "boot lock exemption at ${blast:-absent}, reject at ${brej:-absent}"
	fi
fi

# --- bookkeeping ------------------------------------------------------------
# Drift, the upgrade audit and the reinstall tool all read this list; a file
# that is installed but unlisted is invisible to all three.
for entry in \
	"router/services/procd/surflare-bootlock:/etc/init.d/surflare-bootlock:" \
	"router/rule/hotplug-nftables-20-surflare-lan-tproxy:/etc/hotplug.d/nftables/20-surflare-lan-tproxy:"; do
	if grep -q "^${entry}" scripts/installed-files.list; then
		ok "${entry%%:*} is on the install list"
	else
		bad "${entry%%:*} is installed but missing from installed-files.list"
	fi
done

echo "RESULT: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ] || exit 1
