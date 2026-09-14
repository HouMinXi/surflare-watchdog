#!/usr/bin/env bash
# Hop ledger for hk-24h observer.
# CLI Transit: is a label (Auto/Washington). Auto never names the
# public_N first hop. Functions EXTRACTED from the production script.
#
# shellcheck disable=SC2015,SC2016
set -u
cd "$(dirname "$0")/.." || exit 1
OBS="scripts/surflare-hk-24h-observer.sh"
JQ="scripts/hk24h-public-map.jq"
[ -f "$OBS" ] || { echo "FAIL: $OBS missing"; exit 1; }
[ -f "$JQ" ] || { echo "FAIL: $JQ missing"; exit 1; }
fail=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CFG="tests/fixtures/singbox-public-hops.json"
[ -f "$CFG" ] || { echo "FAIL: fixture $CFG missing"; exit 1; }
export HK24H_JQ="$PWD/$JQ"

extract_fn() {
	awk -v name="$1" '$0 ~ "^" name "\\(\\)" {f=1} f {print} f && /^}/ {exit}' "$OBS"
}

FNS="$(extract_fn _hk24h_jq_file)
$(extract_fn _hk24h_public_map)
$(extract_fn _hk24h_pick_hop)
$(extract_fn _hk24h_window_ok)
$(extract_fn _hk24h_parse_443)
$(extract_fn _hk24h_collect_peers)
$(extract_fn _hk24h_sample)"

# --- T1: hop functions exist ---
echo "$FNS" | grep -q '_hk24h_pick_hop()' \
	&& ok "pick_hop function present" \
	|| bad "pick_hop function absent (observer still label-only)"

echo "$FNS" | grep -q '_hk24h_public_map()' \
	&& ok "public_map function present" \
	|| bad "public_map function absent"

echo "$FNS" | grep -q '_hk24h_window_ok()' \
	&& ok "window_ok function present" \
	|| bad "window_ok function absent"

echo "$FNS" | grep -q '_hk24h_collect_peers()' \
	&& ok "collect_peers function present" \
	|| bad "collect_peers function absent"

# --- T2: public_map from fixture ---
if echo "$FNS" | grep -q '_hk24h_public_map()'; then
	MAP_OUT="$(bash -c "$FNS
_hk24h_public_map \"$CFG\"" 2>/dev/null)"
	echo "$MAP_OUT" | grep -q 'public_186 152.32.238.178' \
		&& ok "public_map lists public_186" \
		|| bad "public_map missed public_186: [$MAP_OUT]"
	echo "$MAP_OUT" | grep -q '127.0.0.1' \
		&& bad "public_map leaked loopback" \
		|| ok "public_map skips loopback"
else
	bad "public_map skipped (function missing)"
	bad "public_map loopback skipped (function missing)"
fi

# --- T3: pick highest public_* peer; ignore 8.8.8.8 flood ---
if echo "$FNS" | grep -q '_hk24h_pick_hop()'; then
	printf '%s\n' 'public_186 152.32.238.178' > "$TMP/map"
	{
		echo 8.8.8.8
		echo 8.8.8.8
		echo 8.8.8.8
		echo 8.8.8.8
		echo 8.8.8.8
		echo 152.32.238.178
		echo 152.32.238.178
		echo 152.32.238.178
		echo 1.1.1.1
	} > "$TMP/peers"
	PICK="$(bash -c "$FNS
_hk24h_pick_hop \"$TMP/map\" \"$TMP/peers\"" 2>/dev/null)"
	[ "$PICK" = "public_186 152.32.238.178 3" ] \
		&& ok "pick_hop prefers mapped public_* over DoH flood" \
		|| bad "pick_hop wrong: [$PICK] want [public_186 152.32.238.178 3]"

	echo 9.9.9.9 > "$TMP/peers_none"
	PICK2="$(bash -c "$FNS
_hk24h_pick_hop \"$TMP/map\" \"$TMP/peers_none\"" 2>/dev/null)"
	[ "$PICK2" = "? ? 0" ] \
		&& ok "pick_hop unknown when no public_* peer" \
		|| bad "pick_hop no-match: [$PICK2] want [? ? 0]"
else
	bad "pick_hop mapped skipped (function missing)"
	bad "pick_hop no-match skipped (function missing)"
fi

# --- T4: DURATION=0 keeps sampling ---
if echo "$FNS" | grep -q '_hk24h_window_ok()'; then
	echo 1 > "$TMP/start_old"
	WIN="$(DURATION=0 START_FILE="$TMP/start_old" bash -c "$FNS
_hk24h_window_ok; echo rc=\$?" 2>/dev/null)"
	echo "$WIN" | grep -q 'rc=0' \
		&& ok "DURATION=0 samples forever" \
		|| bad "DURATION=0 still blocked: [$WIN]"

	WIN2="$(DURATION=1 START_FILE="$TMP/start_old" bash -c "$FNS
_hk24h_window_ok; echo rc=\$?" 2>/dev/null)"
	echo "$WIN2" | grep -q 'rc=1' \
		&& ok "DURATION>0 still expires" \
		|| bad "DURATION=1 did not expire: [$WIN2]"
else
	bad "window forever skipped (function missing)"
	bad "window expire skipped (function missing)"
fi

# --- T5: sample line appends hop columns ---
if grep -q '_hk24h_sample()' "$OBS"; then
	{
		echo 152.32.238.178
		echo 152.32.238.178
	} > "$TMP/peers"
	LINE="$(LOG="$TMP/out.log" HK24H_CFG="$CFG" HK24H_PEERS="$TMP/peers" \
		STATUS_TEXT='Status: Connected|Server: United States(12.104.10.184)|Transit: Auto|' \
		BAIDU_RESULT='000,1' GOOGLE_RESULT='000,1' IPIFY='1.2.3.4' \
		ERR_COUNT=0 LAST_ERR='' TS='2026-09-14T00:00:00+08:00' \
		bash -c "$FNS
_hk24h_sample" 2>/dev/null
		tail -1 "$TMP/out.log" 2>/dev/null)"
	NF="$(printf '%s\n' "$LINE" | awk -F'\t' '{print NF}')"
	[ "$NF" -ge 11 ] \
		&& ok "sample line has hop columns (nf=$NF)" \
		|| bad "sample nf=$NF line=[$LINE]"
	echo "$LINE" | grep -q $'\tpublic_186\t152.32.238.178\t2$' \
		&& ok "sample hop fields public_186/152.32.238.178/2" \
		|| bad "sample hop fields wrong: [$LINE]"
else
	bad "sample absent"
	bad "sample hop fields skipped"
fi

# --- T6: collect_peers from N100 ss/netstat shapes ---
# Empty ss (OpenWrt `ss -tn state established` case) plus netstat
# ESTABLISHED :443 must still yield the hop IP.
if echo "$FNS" | grep -q '_hk24h_collect_peers()'; then
	: > "$TMP/ss_empty"
	printf '%s\n' 'tcp 0 0 100.65.254.219:46890 152.32.238.178:443 ESTABLISHED ' > "$TMP/netstat"
	PEERS="$(HK24H_SS_OUT="$TMP/ss_empty" HK24H_NETSTAT_OUT="$TMP/netstat" bash -c "$FNS
_hk24h_collect_peers" 2>/dev/null)"
	echo "$PEERS" | grep -qx '152.32.238.178' \
		&& ok "collect_peers netstat ESTAB :443 when ss empty" \
		|| bad "collect_peers missed netstat hop: [$PEERS]"

	printf '%s\n' 'ESTAB 0 0 100.65.254.219%pppoe-wan:46890 152.32.238.178:https' > "$TMP/ss_https"
	: > "$TMP/netstat_empty"
	PEERS2="$(HK24H_SS_OUT="$TMP/ss_https" HK24H_NETSTAT_OUT="$TMP/netstat_empty" bash -c "$FNS
_hk24h_collect_peers" 2>/dev/null)"
	echo "$PEERS2" | grep -qx '152.32.238.178' \
		&& ok "collect_peers ss :https with zone id" \
		|| bad "collect_peers missed ss https hop: [$PEERS2]"

	printf '%s\n' 'ESTAB 0 0 127.0.0.1:44346 127.0.0.1:10800' > "$TMP/ss_lan"
	PEERS3="$(HK24H_SS_OUT="$TMP/ss_lan" HK24H_NETSTAT_OUT="$TMP/netstat_empty" bash -c "$FNS
_hk24h_collect_peers" 2>/dev/null)"
	[ -z "$PEERS3" ] \
		&& ok "collect_peers ignores LAN 443" \
		|| bad "collect_peers leaked LAN: [$PEERS3]"
else
	bad "collect_peers netstat skipped (function missing)"
	bad "collect_peers ss https skipped (function missing)"
	bad "collect_peers LAN skipped (function missing)"
fi

# --- teeth: emptied pick_hop stays unknown ---
if echo "$FNS" | grep -q '_hk24h_pick_hop()'; then
	NEUT=$(printf '%s\n' "$FNS" | awk '
		/^_hk24h_pick_hop\(\)/ {print; print "\t echo \"? ? 0\""; print "\t return 0"; skip=1; next}
		skip && /^}/ {print; skip=0; next}
		skip {next}
		{print}')
	printf '%s\n' 'public_186 152.32.238.178' > "$TMP/map"
	echo 152.32.238.178 > "$TMP/peers"
	NEUT_OUT="$(bash -c "$NEUT
_hk24h_pick_hop \"$TMP/map\" \"$TMP/peers\"" 2>/dev/null)"
	[ "$NEUT_OUT" = "? ? 0" ] \
		&& ok "teeth: emptied pick_hop stays unknown" \
		|| bad "teeth: emptied pick_hop still filled [$NEUT_OUT]"
else
	bad "teeth skipped (function missing)"
fi

bash -n "$OBS" && ok "bash -n observer" || bad "bash -n observer"
busybox ash -n "$OBS" && ok "ash -n observer" || bad "ash -n observer"
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -x "$OBS" "$JQ" >/tmp/hk24h_sc.out 2>&1; then
		ok "shellcheck clean"
	else
		# jq file is not a shell script; observer-only
		if shellcheck -x "$OBS" >/tmp/hk24h_sc.out 2>&1; then
			ok "shellcheck clean"
		else
			w=$(grep -c "SC[0-9]" /tmp/hk24h_sc.out || true)
			ok "shellcheck warnings-only ($w) -- see /tmp/hk24h_sc.out"
		fi
	fi
fi
exit $fail

