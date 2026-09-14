#!/bin/sh
# Continuous hop ledger for surflare transit.
# CLI Transit: is a label (Auto / Washington). Auto never names the
# public_N first hop. Columns 1-8 keep the old contract. Columns
# 9-11 are hop_tag hop_ip hop_n. DURATION=0: no 24h kill.
#
# Runs on N100 (busybox ash) via cron */5.

LOG="${LOG:-/var/log/surflare-hk-24h.log}"
START_FILE="${START_FILE:-/run/surflare-hk-24h.start}"
DURATION="${DURATION:-0}"
HK24H_CFG="${HK24H_CFG:-/tmp/singbox-config-patched.json}"

_hk24h_jq_file() {
	if [ -n "${HK24H_JQ:-}" ]; then
		printf "%s\n" "$HK24H_JQ"
		return 0
	fi
	_d=$(dirname "$0")
	if [ -f "$_d/hk24h-public-map.jq" ]; then
		printf "%s\n" "$_d/hk24h-public-map.jq"
		return 0
	fi
	printf "%s\n" "/usr/local/sbin/hk24h-public-map.jq"
}

# public_* tag/server pairs; jq file skips loopback 127.0.0.1.
_hk24h_public_map() {
	_cfg="$1"
	_jq=$(_hk24h_jq_file)
	[ -f "$_cfg" ] || return 0
	[ -f "$_jq" ] || return 0
	jq -r -f "$_jq" "$_cfg" 2>/dev/null || true
}

# Highest-count public_* IP in the peer list. Else "? ? 0".
_hk24h_pick_hop() {
	_map="$1"
	_peers="$2"
	_best_n=0
	_best_tag="?"
	_best_ip="?"
	[ -f "$_map" ] || { echo "? ? 0"; return 0; }
	[ -f "$_peers" ] || { echo "? ? 0"; return 0; }
	while read -r _tag _ip _; do
		[ -n "$_ip" ] || continue
		_n=$(grep -c -F -x -- "$_ip" "$_peers" 2>/dev/null || true)
		[ -n "$_n" ] || _n=0
		if [ "$_n" -gt "$_best_n" ]; then
			_best_n=$_n
			_best_tag=$_tag
			_best_ip=$_ip
		fi
	done < "$_map"
	if [ "$_best_n" -eq 0 ]; then
		echo "? ? 0"
	else
		echo "$_best_tag $_best_ip $_best_n"
	fi
}

# DURATION=0 samples forever. DURATION>0 expires like the old 24h window.
_hk24h_window_ok() {
	_dur="${DURATION:-0}"
	_sf="${START_FILE:-/run/surflare-hk-24h.start}"
	if [ "$_dur" -eq 0 ]; then
		return 0
	fi
	if [ ! -f "$_sf" ]; then
		date +%s > "$_sf" 2>/dev/null || true
	fi
	_start=$(cat "$_sf" 2>/dev/null)
	_now=$(date +%s)
	case "$_start" in
	''|*[!0-9]*) return 1 ;;
	esac
	if [ "$((_now - _start))" -gt "$_dur" ]; then
		return 1
	fi
	return 0
}

# OpenWrt ss -tn state established missed WAN ESTAB :443
# (N100 2026-09-14: 0 rows) while ss -tn and netstat listed them.
# Scan every field for IPv4:443 or IPv4:https.
_hk24h_parse_443() {
	awk '{
		for (i = 1; i <= NF; i++) {
			f = $i
			if (f ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:(443|https)$/) {
				sub(/:(443|https)$/, "", f)
				print f
			}
		}
	}'
}

_hk24h_collect_peers() {
	if [ -n "${HK24H_SS_OUT+x}" ] || [ -n "${HK24H_NETSTAT_OUT+x}" ]; then
		{
			[ -n "${HK24H_SS_OUT+x}" ] && [ -f "$HK24H_SS_OUT" ] && cat "$HK24H_SS_OUT"
			[ -n "${HK24H_NETSTAT_OUT+x}" ] && [ -f "$HK24H_NETSTAT_OUT" ] && cat "$HK24H_NETSTAT_OUT"
		} | _hk24h_parse_443
		return 0
	fi
	{
		ss -tn 2>/dev/null || true
		netstat -tn 2>/dev/null || true
	} | _hk24h_parse_443
}

_hk24h_sample() {
	_log="${LOG:-/var/log/surflare-hk-24h.log}"
	_cfg="${HK24H_CFG:-/tmp/singbox-config-patched.json}"
	mkdir -p "$(dirname "$_log")" 2>/dev/null || true

	if [ -n "${STATUS_TEXT+x}" ]; then
		_status="$STATUS_TEXT"
	else
		_status=$(surflare status 2>/dev/null | tr '\n' '|')
	fi
	_server=$(printf '%s' "$_status" | grep -oE 'Server:[^|]+' | sed 's/.*Server:[[:space:]]*//;s/[[:space:]]*$//')
	_transit=$(printf '%s' "$_status" | grep -oE 'Transit:[^|]+' | sed 's/.*Transit:[[:space:]]*//;s/[[:space:]]*$//')

	if [ -n "${BAIDU_RESULT+x}" ]; then
		_baidu="$BAIDU_RESULT"
	else
		_baidu=$(curl -s -o /dev/null -w '%{http_code},%{time_total}' --max-time 10 -x socks5://127.0.0.1:10800 http://www.baidu.com 2>/dev/null || echo '000,0')
	fi
	if [ -n "${GOOGLE_RESULT+x}" ]; then
		_google="$GOOGLE_RESULT"
	else
		_google=$(curl -s -o /dev/null -w '%{http_code},%{time_total}' --max-time 10 -x socks5://127.0.0.1:10800 https://www.google.com 2>/dev/null || echo '000,0')
	fi
	if [ -n "${IPIFY+x}" ]; then
		_ipify="$IPIFY"
	else
		_ipify=$(curl -s --max-time 10 -x socks5://127.0.0.1:10800 https://api.ipify.org 2>/dev/null | tr '\n' ' ')
	fi
	if [ -n "${ERR_COUNT+x}" ]; then
		_errc="$ERR_COUNT"
	else
		_errc=$(logread | tail -n 200 | grep -c 'outbound/urltest' || true)
	fi
	if [ -n "${LAST_ERR+x}" ]; then
		_lasterr="$LAST_ERR"
	else
		_lasterr=$(logread | grep 'outbound/urltest' | tail -1 | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	fi
	if [ -n "${TS+x}" ]; then
		_ts="$TS"
	else
		_ts=$(date -Iseconds)
	fi

	_mapf=$(mktemp /tmp/hk24h_map.XXXXXX 2>/dev/null)
	[ -f "$_mapf" ] || return 1
	_hk24h_public_map "$_cfg" > "$_mapf"
	if [ -n "${HK24H_PEERS:-}" ]; then
		_peersf="$HK24H_PEERS"
		_own_peers=0
	else
		_peersf=$(mktemp /tmp/hk24h_peers.XXXXXX 2>/dev/null)
		if [ ! -f "$_peersf" ]; then
			rm -f "$_mapf"
			return 1
		fi
		_own_peers=1
		_hk24h_collect_peers > "$_peersf"
	fi
	_pick=$(_hk24h_pick_hop "$_mapf" "$_peersf")
	rm -f "$_mapf"
	if [ "$_own_peers" -eq 1 ]; then
		rm -f "$_peersf"
	fi
	_hop_tag=$(printf '%s\n' "$_pick" | awk '{print $1}')
	_hop_ip=$(printf '%s\n' "$_pick" | awk '{print $2}')
	_hop_n=$(printf '%s\n' "$_pick" | awk '{print $3}')
	[ -n "$_hop_n" ] || _hop_n=0

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n' \
		"$_ts" "$_server" "$_transit" "$_baidu" "$_google" "$_ipify" \
		"${_errc:-0}" "$_lasterr" "$_hop_tag" "$_hop_ip" "$_hop_n" >> "$_log"
}

if ! _hk24h_window_ok; then
	logger -t hk24h "observation window ended"
	rm -f "$START_FILE"
	exit 0
fi

_hk24h_sample
