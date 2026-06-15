#!/bin/bash
# surflare_node_probe.sh
#
# Pre-assess all VPN nodes while the current session is healthy,
# so the watchdog has a ranked list ready for the next rotation.
#
# Two phases:
#   Phase 1: exit nodes (via current transit; Seoul is a non-US comparison point)
#   Phase 2: Transit/relay nodes (via current exit, physical NIC analysis)
#
# Methodology per node (L3 -> L7):
#   L4  TCP:   SO_MARK=0xff direct TCP connect to server IP:443 (bypass tproxy)
#   L5  VPN:   surflare-proxy running + nftables/routing rules present
#   L6  TLS:   TTFB includes TLS handshake (curl time_starttransfer)
#   L7  HTTP:  Google TTFB + exit country verification
#
# Transit path-quality signals (from physical NIC pcap, same as watchdog diag):
#   SYN ratio:  syn_ack/syn_out -- < 50% = upstream SYN loss
#   RST count:  RST packets injected -- > 0 = RST injection detected
#   SACK %:     SACK blocks on live connections -- > 20% = link degradation
#
# Output:
#   Terminal: colour-coded ranked table
#   File:     /run/surflare_probe_results.json (watchdog reads before rotation)
#
# Must run as root.

set -o nounset
export LC_ALL=C   # prevent locale from corrupting curl numeric output

if [ "$EUID" -ne 0 ]; then
    echo "Must run as root: sudo $0" >&2
    exit 1
fi

# -- Config (copy these from surflare_watchdog.sh) --------------------------
NODE_CANDIDATES=("Los Angeles" "Dallas" "Atlanta" "Seoul" "Chicago" "Miami" "New York")
TRANSIT_CANDIDATES=("Los Angeles" "Taipei" "Seoul" "Hong Kong")
MODE="global"

PROBE_CONNECT_TIMEOUT=8    # surflare connect timeout per candidate
PROBE_ROUTE_TIMEOUT=8      # seconds to poll for routing readiness
PROBE_SETTLE=3             # seconds for tunnel handshake after routing ready
PROBE_CURL_TIMEOUT=5       # curl max-time for L7 probe
PROBE_PCAP_DURATION=4      # seconds of tcpdump capture for path-quality analysis
RESULTS_FILE="/run/surflare_probe_results.json"
LOCK_FILE="/run/surflare_probe.lock"
WATCHDOG_LOCK="/run/surflare_watchdog.lock"     # watchdog connect lock (its fd 9)
PROBE_ACTIVE_FILE="/run/surflare_probe.active"  # raised so watchdog defers its cycle

# -- Colour helpers ----------------------------------------------------------
RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m'; RST_C='\033[0m'
ok()  { echo -e "${GRN}OK${RST_C} $*"; }
bad() { echo -e "${RED}FAIL${RST_C} $*"; }
wrn() { echo -e "${YEL}WARN${RST_C} $*"; }
inf() { echo -e "${CYN}INFO${RST_C} $*"; }

# -- Detect current session state --------------------------------------------
get_current_session() {
    local status_out
    status_out=$(surflare status 2>/dev/null) || true
    CURRENT_NODE=$(echo "$status_out" | awk -F'Server:|Server :' 'NF>1{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}')
    CURRENT_TRANSIT=$(cat /run/surflare_last_transit 2>/dev/null || echo "")
    CURRENT_SERVER_IPS=$(ss -tnp state established 2>/dev/null \
        | awk '/surflare/{split($(NF-1),a,":");ip=a[1];
                if(ip~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
                   ip!~/^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)/) print ip}' \
        | sort -u | tr '\n' ' ' | sed 's/ $//')
    # Respect user's PHYS_IF env override; auto-detect only if unset
    if [ -z "${PHYS_IF:-}" ]; then
        PHYS_IF=$(ip route get "${CURRENT_SERVER_IPS%% *}" 2>/dev/null \
            | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
    fi
    if [ -z "$PHYS_IF" ]; then
        # Try first UP non-loopback NIC, then any non-loopback NIC
        PHYS_IF=$(ip -br link show 2>/dev/null | awk '$1!="lo" && $2=="UP"{print $1; exit}')
        [ -z "$PHYS_IF" ] && \
            PHYS_IF=$(ip -br link show 2>/dev/null | awk '$1!="lo"{print $1; exit}')
        [ -z "$PHYS_IF" ] && PHYS_IF="enp2s0"  # last-resort hardcoded guess
        wrn "PHYS_IF auto-detect used fallback: ${PHYS_IF} (override: PHYS_IF=<nic> $0)"
    fi
}

# -- SO_MARK=0xff direct TCP probe (bypasses tproxy + killswitch) ------------
# Returns RTT in ms, or -1 on failure.
# cache_node_ips: $1=node_name  $2..N=server IPs (space-separated ok via caller unquoted)
cache_node_ips() {
    local node="$1"
    shift
    [ $# -eq 0 ] && return  # no IPs
    local cache="/var/lib/surflare/node_ips.json"
    mkdir -p "$(dirname "$cache")"
    python3 - "$cache" "$node" "$@" << 'IPEOF'
import json, os, sys
cache, node = sys.argv[1], sys.argv[2]
ips = sys.argv[3:]
data = {}
if os.path.exists(cache):
    try:
        with open(cache) as _f:
            data = json.load(_f)
    except Exception:
        data = {}
data[node] = ips
tmp = cache + ".tmp"
with open(tmp, "w") as _f:
    json.dump(data, _f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, cache)
IPEOF
}

l4_direct_probe() {
    local ip="$1" port="${2:-443}" timeout="${3:-3}"
    python3 - "$ip" "$port" "$timeout" << 'PYEOF'
import socket, time, sys
ip, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
s = socket.socket()
try:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, 0xff)
    s.settimeout(timeout)
    t = time.time()
    s.connect((ip, port))
    ms = int((time.time() - t) * 1000)
    print(ms)
except Exception:
    print(-1)
finally:
    s.close()
PYEOF
}

# -- Wait for VPN routing to be ready after connect --------------------------
wait_routing_ready() {
    local sec=0
    while [ "$sec" -lt "$PROBE_ROUTE_TIMEOUT" ]; do
        pgrep -x surflare-proxy >/dev/null 2>&1 \
        && nft list table inet surflare >/dev/null 2>&1 \
        && ip rule show | grep -qE '\bfwmark 0x1 lookup 100\b' && return 0
        sleep 1; sec=$((sec+1))
    done
    return 1
}

# -- Capture server IPs after connect ---------------------------------------
capture_server_ips() {
    ss -tnp state established 2>/dev/null \
        | awk '/surflare/{split($(NF-1),a,":");ip=a[1];
                if(ip~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
                   ip!~/^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)/) print ip}' \
        | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# -- Cleanup: disconnect and flush residual state ----------------------------
probe_cleanup() {
    # timeout prevents hung disconnect from blocking cleanup
    timeout 3 surflare disconnect >/dev/null 2>&1 || true
    sleep 0.5
    timeout 3 killall surflare-proxy 2>/dev/null || true
    sleep 0.3
    nft flush table inet surflare 2>/dev/null || true; nft delete table inet surflare 2>/dev/null || true
    while ip rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null || true
    # Kill orphaned tcpdump from interrupted pcap captures
    pkill -f 'tcpdump.*surflare_transit_probe' 2>/dev/null || true
    rm -f /tmp/surflare_transit_probe_*.pcap 2>/dev/null || true
}

# -- Path-quality analysis from pcap -----------------------------------------
# Returns: SYN_RATIO RST_COUNT SACK_PCT VERDICT
analyze_pcap_path() {
    local pcap="$1" server_ips="$2" local_ip="$3"
    # Guard against empty inputs
    [[ -z "$server_ips" || -z "$local_ip" ]] && { echo "0 0 0 CAPTURE_FAIL"; return; }
    # return CAPTURE_FAIL if pcap is missing or empty
    if [[ ! -s "$pcap" ]]; then
        echo "0 0 0 CAPTURE_FAIL"
        return
    fi
    local filter
    filter=$(echo "$server_ips" | tr ' ' '\n' | grep -v '^$' \
        | awk '{printf "%shost %s",(NR>1?" or ":""),$0}')

    local out_pkts in_pkts syn_out syn_ack rst_in sack_total total_pkts
    out_pkts=$(tcpdump -r "$pcap" -nn "src $local_ip and ($filter)" 2>/dev/null | wc -l)
    in_pkts=$(tcpdump -r "$pcap" -nn "($filter) and dst $local_ip" 2>/dev/null | wc -l)

    if [ "$out_pkts" -eq 0 ]; then
        echo "0 0 0 LOCAL_PROXY_DEAD"
        return
    fi
    if [ "$in_pkts" -eq 0 ]; then
        echo "0 0 0 UPSTREAM_UNREACHABLE"
        return
    fi

    syn_out=$(tcpdump -r "$pcap" -nn \
        "src $local_ip and tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn" \
        2>/dev/null | wc -l)
    syn_ack=$(tcpdump -r "$pcap" -nn \
        "dst $local_ip and tcp[tcpflags] & (tcp-syn|tcp-ack) == (tcp-syn|tcp-ack)" \
        2>/dev/null | wc -l)
    rst_in=$(tcpdump -r "$pcap" -nn \
        "dst $local_ip and (tcp[tcpflags] & tcp-rst) != 0" \
        2>/dev/null | wc -l)
    sack_total=$(tcpdump -r "$pcap" -nn 2>/dev/null | grep -cE 'sack [0-9]' || true)
    total_pkts=$(( out_pkts + in_pkts ))
    local sack_pct=0
    [ "$total_pkts" -gt 0 ] && sack_pct=$(( sack_total * 100 / total_pkts ))
    local syn_ratio=100
    [ "$syn_out" -gt 0 ] && syn_ratio=$(( syn_ack * 100 / syn_out ))

    local verdict="CLEAN"
    if [ "$syn_out" -gt 0 ] && [ $(( syn_ack * 2 )) -lt "$syn_out" ]; then
        if [ "$rst_in" -gt 0 ]; then
            verdict="SERVER_REFUSED_RST"
        elif [ "$sack_pct" -gt 20 ]; then
            verdict="TRANSIT_DEGRADATION"
        else
            verdict="TARGETED_SYN_BLOCK"
        fi
    elif [ "$sack_pct" -gt 20 ]; then
        verdict="TRANSIT_DEGRADATION"
    fi

    echo "$syn_ratio $rst_in $sack_pct $verdict"
}

# -- Score a node from probe results ------------------------------------------
compute_node_score() {
    local connect_ok="$1"  # 0/1
    local curl_ms="$2"     # TTFB in ms, -1 if failed
    local l4_ms="$3"       # direct TCP RTT in ms, -1 if failed
    local exit_country="$4" # country code or ""

    [ "$connect_ok" -eq 0 ] && { echo 0; return; }
    # guard against empty/non-numeric curl_ms
    [[ "$curl_ms" =~ ^-?[0-9]+$ ]] || curl_ms=-1
    [ "$curl_ms" -lt 0 ] && { echo 5; return; }

    local score=100
    # tiered curl_ms (NOT cumulative -- if/elif per N6 contract)
    if   [ "$curl_ms" -gt 2000 ]; then score=$((score - 30))
    elif [ "$curl_ms" -gt 1000 ]; then score=$((score - 20))
    elif [ "$curl_ms" -gt  500 ]; then score=$((score - 10))
    fi
    # Penalise wrong exit country
    [ -n "$exit_country" ] && [ "$exit_country" != "US" ] && score=$((score - 25))
    # guard against empty/non-numeric l4_ms
    [[ "$l4_ms" =~ ^-?[0-9]+$ ]] || l4_ms=-1
    [ "$l4_ms" -gt 300 ] && score=$((score - 10))
    [ "$l4_ms" -lt 0 ]   && score=$((score - 15))
    # Cap
    [ "$score" -lt 0 ]   && score=0
    [ "$score" -gt 100 ] && score=100
    echo "$score"
}

# -- Transit score from path-quality analysis ---------------------------------
compute_transit_score() {
    local connect_ok="$1" curl_ms="$2" syn_ratio="$3" rst_count="$4" verdict="$5"

    [ "$connect_ok" -eq 0 ] && { echo 0; return; }
    # guard against empty/non-numeric curl_ms
    [[ "$curl_ms" =~ ^-?[0-9]+$ ]] || curl_ms=-1
    [ "$curl_ms" -lt 0 ]   && { echo 5; return; }

    local score=100
    case "$verdict" in
        TARGETED_SYN_BLOCK)  score=10 ;;
        SERVER_REFUSED_RST)  score=15 ;;
        TRANSIT_DEGRADATION) score=40 ;;
        UPSTREAM_UNREACHABLE) score=5 ;;
        LOCAL_PROXY_DEAD)    score=5 ;;
        CONNECT_FAIL)        score=0 ;;
        ROUTE_FAIL)          score=0 ;;
        CAPTURE_FAIL)        score=50 ;;
        CLEAN)               score=100 ;;
        *)                   score=50 ;;
    esac
    # guard against empty/non-numeric pcap metrics
    [[ "$rst_count" =~ ^-?[0-9]+$ ]] || rst_count=0
    [[ "$syn_ratio" =~ ^-?[0-9]+$ ]] || syn_ratio=100
    [ "$verdict" != "CAPTURE_FAIL" ] && [ "$rst_count" -gt 3 ]  && score=$((score - 20))
    [ "$verdict" != "CAPTURE_FAIL" ] && [ "$syn_ratio" -lt 50 ] && score=$((score - 15))
    # tiered curl_ms (NOT cumulative -- if/elif per N6 contract)
    if   [ "$curl_ms" -gt 2000 ]; then score=$((score - 20))
    elif [ "$curl_ms" -gt 1000 ]; then score=$((score - 10))
    fi
    [ "$score" -lt 0 ]   && score=0
    [ "$score" -gt 100 ] && score=100
    echo "$score"
}

# -- One exit node probe cycle ------------------------------------------------
probe_exit_node() {
    local node="$1" transit="$2"

    # -- Connect
    local connect_start connect_elapsed connect_ok=0
    connect_start=$(date +%s%3N)
    local _conn_cmd=(timeout "$PROBE_CONNECT_TIMEOUT" surflare connect
        --node "$node" --mode "$MODE")
    [ -n "${transit:-}" ] && _conn_cmd+=(--transit "$transit")
    _conn_cmd+=(--daemon)
    if ! "${_conn_cmd[@]}" >/dev/null 2>&1; then
        probe_cleanup
        echo "connect_ok=0 connect_ms=-1 server_ips= l4_ms=-1 curl_ms=-1 exit_country= score=0"
        return
    fi
    connect_elapsed=$(( $(date +%s%3N) - connect_start ))
    connect_ok=1

    if ! wait_routing_ready; then
        probe_cleanup
        echo "connect_ok=0 connect_ms=-1 server_ips= l4_ms=-1 curl_ms=-1 exit_country= score=0"
        return
    fi
    sleep "$PROBE_SETTLE"

    # -- Server IPs
    local server_ips
    server_ips=$(capture_server_ips)
    local first_ip="${server_ips%% *}"

    # -- L4: direct TCP probe bypassing tproxy (SO_MARK=0xff)
    local l4_ms=-1
    [ -n "$first_ip" ] && l4_ms=$(l4_direct_probe "$first_ip" 443 3)

    # -- L7: curl Google for TTFB + exit country
    local probe_result curl_ms=-1 exit_country="" http_code
    probe_result=$(curl -s --connect-timeout 3 --max-time "$PROBE_CURL_TIMEOUT" \
        -o /dev/null \
        -w '%{http_code}:%{time_starttransfer}' \
        https://www.google.com 2>/dev/null) || true
    http_code="${probe_result%%:*}"
    case "$http_code" in
        200|301|302)
            local raw_ms="${probe_result#*:}"; raw_ms="${raw_ms%%:*}"
            curl_ms=$(awk "BEGIN {printf \"%.0f\", ${raw_ms} * 1000}" 2>/dev/null)
            ;;
    esac

    # -- Exit country
    local country_raw
    country_raw=$(curl -s --connect-timeout 3 --max-time 4 \
        'https://1.0.0.1/cdn-cgi/trace' 2>/dev/null \
        | awk -F= '/^loc=/{print $2}' | tr -d '[:space:]') || true
    [[ "$country_raw" =~ ^[A-Z]{2}$ ]] && exit_country="$country_raw"

    local score
    score=$(compute_node_score "$connect_ok" "$curl_ms" "$l4_ms" "$exit_country")

    probe_cleanup
    echo "connect_ok=${connect_ok} connect_ms=${connect_elapsed} server_ips='${server_ips}' l4_ms=${l4_ms} curl_ms=${curl_ms} exit_country='${exit_country}' score=${score}"
}

# -- One transit node probe cycle --------------------------------------------
probe_transit_node() {
    local transit="$1" exit_node="$2"

    local connect_start connect_elapsed connect_ok=0 curl_ms=-1
    connect_start=$(date +%s%3N)
    if ! timeout "$PROBE_CONNECT_TIMEOUT" surflare connect \
            --node "$exit_node" --mode "$MODE" \
            --transit "$transit" \
            --daemon >/dev/null 2>&1; then
        probe_cleanup
        echo "connect_ok=0 connect_ms=-1 l4_ms=-1 curl_ms=-1 syn_ratio=0 rst_count=0 sack_pct=0 verdict=CONNECT_FAIL score=0"
        return
    fi
    connect_elapsed=$(( $(date +%s%3N) - connect_start ))
    connect_ok=1

    if ! wait_routing_ready; then
        probe_cleanup
        echo "connect_ok=0 connect_ms=-1 l4_ms=-1 curl_ms=-1 syn_ratio=0 rst_count=0 sack_pct=0 verdict=ROUTE_FAIL score=0"
        return
    fi
    sleep "$PROBE_SETTLE"

    local server_ips
    server_ips=$(capture_server_ips)
    local first_ip="${server_ips%% *}"
    local local_ip
    local_ip=$(ip -4 addr show "$PHYS_IF" 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

    # -- L4 direct probe
    local l4_ms=-1
    [ -n "$first_ip" ] && l4_ms=$(l4_direct_probe "$first_ip" 443 3)

    # -- Physical NIC pcap: path-quality analysis
    local pcap="/tmp/surflare_transit_probe_$$.pcap"
    local filter=""
    if [ -n "$server_ips" ]; then
        filter=$(echo "$server_ips" | tr ' ' '\n' | grep -v '^$' \
            | awk '{printf "%shost %s",(NR>1?" or ":""),$0}')
    fi

    local syn_ratio=100 rst_count=0 sack_pct=0 verdict="CLEAN"
    if [ "$PCAP_AVAILABLE" -eq 1 ] && [ -n "$filter" ] && [ -n "$local_ip" ]; then
        tcpdump -i "$PHYS_IF" -nn -w "$pcap" "$filter" >/dev/null 2>&1 &
        local td_pid=$!
        sleep 0.5
        local probe_result http_code
        probe_result=$(curl -s --connect-timeout 3 --max-time "$PROBE_CURL_TIMEOUT" \
            -o /dev/null \
            -w '%{http_code}:%{time_starttransfer}' \
            https://www.google.com 2>/dev/null) || true
        http_code="${probe_result%%:*}"
        case "$http_code" in
            200|301|302)
                local raw_ms="${probe_result#*:}"
                curl_ms=$(awk "BEGIN {printf \"%.0f\", ${raw_ms} * 1000}" 2>/dev/null) ;;
        esac

        sleep "$PROBE_PCAP_DURATION"
        kill -INT "$td_pid" 2>/dev/null || true; wait "$td_pid" 2>/dev/null || true

        read -r syn_ratio rst_count sack_pct verdict \
            <<< "$(analyze_pcap_path "$pcap" "$server_ips" "$local_ip")"
        rm -f "$pcap"
    else
        verdict="CAPTURE_FAIL"
        syn_ratio=-1; rst_count=-1; sack_pct=-1
        # Fallback: just curl
        local probe_result http_code
        probe_result=$(curl -s --connect-timeout 3 --max-time "$PROBE_CURL_TIMEOUT" \
            -o /dev/null -w '%{http_code}:%{time_starttransfer}' \
            https://www.google.com 2>/dev/null) || true
        http_code="${probe_result%%:*}"
        case "$http_code" in
            200|301|302)
                local raw_ms="${probe_result#*:}"
                curl_ms=$(awk "BEGIN {printf \"%.0f\", ${raw_ms} * 1000}" 2>/dev/null) ;;
        esac
    fi

    local score
    score=$(compute_transit_score "$connect_ok" "${curl_ms:--1}" "$syn_ratio" "$rst_count" "$verdict")

    probe_cleanup
    echo "connect_ok=${connect_ok} connect_ms=${connect_elapsed} l4_ms=${l4_ms} curl_ms=${curl_ms} syn_ratio=${syn_ratio} rst_count=${rst_count} sack_pct=${sack_pct} verdict='${verdict}' score=${score}"
}

# ===
# MAIN
# ===

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Another probe already running ($LOCK_FILE); exit 0."; exit 0; }

# Check tcpdump availability; transit path-quality pcap is disabled if absent
PCAP_AVAILABLE=1
command -v tcpdump >/dev/null 2>&1 || { wrn "tcpdump not installed; transit pcap analysis disabled (path quality will be CAPTURE_FAIL)"; PCAP_AVAILABLE=0; }

trap 'probe_cleanup; exit 130' INT TERM

get_current_session

[ -z "$CURRENT_NODE" ] && { bad "VPN not connected; aborting"; exit 2; }
# Seed IP cache with current session (known without probing)
[ -n "$CURRENT_SERVER_IPS" ] && cache_node_ips "$CURRENT_NODE" $CURRENT_SERVER_IPS

# --- Coordinate with surflare_watchdog before disturbing the shared session.
# 1. Wait <=30s for any in-flight connect_vpn (holds WATCHDOG_LOCK on fd 9).
# 2. Raise the marker WHILE holding the lock, so no connect_vpn slips in.
# 3. Release the lock; the marker guards the run.
# 4. EXIT trap removes marker on every exit path; watchdog reclaims stale after 75s.
exec 8>"$WATCHDOG_LOCK"
if ! flock -w 30 8; then
    bad "watchdog connect in progress (>30s); skipping this probe run."
    exit 0
fi
echo "$$" > "$PROBE_ACTIVE_FILE"
trap 'rm -f "$PROBE_ACTIVE_FILE" 2>/dev/null || true' EXIT
flock -u 8
exec 8>&-

echo ""
echo -e "${BLD}=== Surflare Node Pre-Assessment ===${RST_C}"
echo -e "${BLD}Current: ${CURRENT_NODE:-?} via ${CURRENT_TRANSIT:-direct}${RST_C}"
echo -e "${BLD}Server IPs: ${CURRENT_SERVER_IPS:-none}${RST_C}"
echo -e "${BLD}Physical NIC: ${PHYS_IF}${RST_C}"
echo ""

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
declare -a EXIT_RESULTS=()
declare -a TRANSIT_RESULTS=()

# --- Phase 1: Exit Nodes (Seoul included as non-US comparison point) --------
echo -e "${BLD}-- Phase 1: Exit Nodes (via ${CURRENT_TRANSIT:-direct}) --${RST_C}"
printf "%-20s %8s %8s %8s %6s %8s\n" "Node" "L4ms" "L7ms" "Country" "Score" "Status"
printf "%-20s %8s %8s %8s %6s %8s\n" "--------------------" "--------" "--------" "-------" "-----" "--------"

for node in "${NODE_CANDIDATES[@]}"; do
    touch "$PROBE_ACTIVE_FILE" 2>/dev/null || true
    if [ "${node}" = "${CURRENT_NODE:-}" ]; then
        local_l4=-1
        for sip in $CURRENT_SERVER_IPS; do
            r=$(l4_direct_probe "$sip" 443 3)
            [ "$r" -ge 0 ] 2>/dev/null && { local_l4=$r; break; }
        done
        _cur_res="" _cur_http="" _cur_raw="" _cur_curl_ms=-1
        _cur_res=$(curl -s --connect-timeout 3 --max-time "$PROBE_CURL_TIMEOUT" \
            -o /dev/null -w '%{http_code}:%{time_starttransfer}' https://www.google.com 2>/dev/null) || true
        _cur_http="${_cur_res%%:*}"
        case "$_cur_http" in
            200|301|302)
                _cur_raw="${_cur_res#*:}"
                _cur_curl_ms=$(awk "BEGIN {printf \"%.0f\", ${_cur_raw} * 1000}" 2>/dev/null) ;;
        esac
        [[ "$_cur_curl_ms" =~ ^-?[0-9]+$ ]] || _cur_curl_ms=-1
        # Probe real exit country (H-02: do not fabricate "US" for non-US current nodes)
        _cur_country_raw=$(curl -s --connect-timeout 3 --max-time 4 \
            'https://1.0.0.1/cdn-cgi/trace' 2>/dev/null \
            | awk -F= '/^loc=/{print $2}' | tr -d '[:space:]') || true
        _cur_country=""
        [[ "$_cur_country_raw" =~ ^[A-Z]{2}$ ]] && _cur_country="$_cur_country_raw"
        score=$(compute_node_score 1 "$_cur_curl_ms" "$local_l4" "$_cur_country")
        printf "%-20s %8s %8s %8s %6s %8s\n" \
            "$node" "${local_l4}ms" "${_cur_curl_ms}ms" "${_cur_country:--}" "$score" "CURRENT"
        EXIT_RESULTS+=("{\"name\":\"$node\",\"status\":\"CURRENT\",\"connect_ok\":1,\"connect_ms\":0,\"l4_ms\":$local_l4,\"curl_ms\":${_cur_curl_ms},\"exit_country\":\"${_cur_country}\",\"score\":$score}")
        continue
    fi

    printf "  probing %-16s ... " "$node"
    # Reset all eval-target variables to prevent cross-iteration leakage
    connect_ok=0 connect_ms=-1 server_ips="" l4_ms=-1 curl_ms=-1 exit_country="" score=0
    result=$(probe_exit_node "$node" "${CURRENT_TRANSIT:-}")
    # eval-contract: all fields are regex-validated before echoing;
    # single-quotes protect server_ips/exit_country; never add unvalidated fields.
    eval "$result"
    [ "${connect_ok:-0}" -eq 1 ] && [ -n "${server_ips:-}" ] && cache_node_ips "$node" ${server_ips}

    if [ "${connect_ok:-0}" -eq 1 ] && [ "${curl_ms:--1}" -gt 0 ]; then
        status="${GRN}GOOD${RST_C}"
        [ "${score:-0}" -lt 60 ] && status="${YEL}SLOW${RST_C}"
        [ "${score:-0}" -lt 30 ] && status="${RED}BAD${RST_C}"
    else
        status="${RED}FAIL${RST_C}"
    fi
    printf "\r%-20s %8s %8s %8s %6s %8b\n" \
        "$node" "${l4_ms:-?}ms" "${curl_ms:-?}ms" "${exit_country:--}" "${score:-0}" "$status"
    EXIT_RESULTS+=("{\"name\":\"$node\",\"connect_ok\":${connect_ok:-0},\"connect_ms\":${connect_ms:--1},\"l4_ms\":${l4_ms:--1},\"curl_ms\":${curl_ms:--1},\"exit_country\":\"${exit_country:-}\",\"score\":${score:-0}}")
done

# --- Phase 2: Transit/Relay Nodes ------------------------------------------
echo ""
echo -e "${BLD}-- Phase 2: Transit/Relay Nodes (Path Quality Analysis) --${RST_C}"
printf "%-20s %8s %8s %8s %6s %8s  %s\n" \
    "Transit" "L4ms" "L7ms" "SYN%" "RST" "Score" "Path Signal"
printf "%-20s %8s %8s %8s %6s %8s  %s\n" \
    "--------------------" "--------" "--------" "--------" "----" "--------" "--------------------"

PROBE_EXIT="${CURRENT_NODE:-${NODE_CANDIDATES[0]}}"

for transit in "${TRANSIT_CANDIDATES[@]}"; do
    touch "$PROBE_ACTIVE_FILE" 2>/dev/null || true
    # Skip if transit == exit node: circular routing gives false CONNECT_FAIL score=0
    if [ "${transit}" = "${PROBE_EXIT}" ] && [ "${transit}" != "${CURRENT_TRANSIT:-}" ]; then
        wrn "Skipping transit ${transit}: same as exit node (circular); not a valid transit path"
        TRANSIT_RESULTS+=("{\"name\":\"$transit\",\"status\":\"SKIP_CIRCULAR\",\"connect_ok\":0,\"connect_ms\":-1,\"l4_ms\":-1,\"curl_ms\":-1,\"syn_ratio\":-1,\"rst_count\":-1,\"sack_pct\":-1,\"verdict\":\"SKIP_CIRCULAR\",\"score\":-1}")
        continue
    fi
    if [ "${transit}" = "${CURRENT_TRANSIT:-}" ]; then
        local_l4=-1
        for sip in $CURRENT_SERVER_IPS; do
            r=$(l4_direct_probe "$sip" 443 3)
            [ "$r" -ge 0 ] 2>/dev/null && { local_l4=$r; break; }
        done
        printf "%-20s %8s %8s %8s %6s %8s  %s\n" \
            "$transit" "${local_l4}ms" "live" "-" "-" "50" "CURRENT (L4 only)"
        TRANSIT_RESULTS+=("{\"name\":\"$transit\",\"status\":\"CURRENT\",\"connect_ok\":1,\"connect_ms\":0,\"l4_ms\":$local_l4,\"syn_ratio\":-1,\"rst_count\":-1,\"sack_pct\":-1,\"verdict\":\"UNMEASURED\",\"score\":50}")
        continue
    fi

    printf "  probing %-16s ... " "$transit"
    connect_ok=0 connect_ms=-1 l4_ms=-1 curl_ms=-1 syn_ratio=0 rst_count=0 sack_pct=0 verdict="" score=0
    result=$(probe_transit_node "$transit" "$PROBE_EXIT")
    # eval-contract: see note above
    eval "$result"
    [ "${connect_ok:-0}" -eq 1 ] && [ -n "${server_ips:-}" ] && cache_node_ips "$transit" ${server_ips}

    path_display="$verdict"
    case "${verdict:-CLEAN}" in
        TARGETED_SYN_BLOCK|SERVER_REFUSED_RST) path_display="${RED}${verdict}${RST_C}" ;;
        TRANSIT_DEGRADATION)                   path_display="${YEL}${verdict}${RST_C}" ;;
        UPSTREAM_UNREACHABLE|CONNECT_FAIL|ROUTE_FAIL) path_display="${RED}${verdict}${RST_C}" ;;
        CAPTURE_FAIL)                          path_display="${YEL}${verdict}${RST_C}" ;;
        *)                                     path_display="${GRN}${verdict}${RST_C}" ;;
    esac

    printf "\r%-20s %8s %8s %8s %6s %8s  %b\n" \
        "$transit" "${l4_ms:--1}ms" "${curl_ms:--1}ms" \
        "${syn_ratio:-?}%" "${rst_count:-?}" "${score:-0}" "$path_display"

    TRANSIT_RESULTS+=("{\"name\":\"$transit\",\"connect_ok\":${connect_ok:-0},\"connect_ms\":${connect_ms:--1},\"l4_ms\":${l4_ms:--1},\"curl_ms\":${curl_ms:--1},\"syn_ratio\":${syn_ratio:-0},\"rst_count\":${rst_count:-0},\"sack_pct\":${sack_pct:-0},\"verdict\":\"${verdict:-UNKNOWN}\",\"score\":${score:-0}}")
done

# -- Restore original VPN session
touch "$PROBE_ACTIVE_FILE" 2>/dev/null || true
if [ -n "$CURRENT_NODE" ]; then
    inf "Restoring original session: ${CURRENT_NODE} via ${CURRENT_TRANSIT:-direct}"
    _restore_cmd=(timeout "$PROBE_CONNECT_TIMEOUT" surflare connect
        --node "$CURRENT_NODE" --mode "$MODE")
    [ -n "${CURRENT_TRANSIT:-}" ] && _restore_cmd+=(--transit "$CURRENT_TRANSIT")
    _restore_cmd+=(--daemon)
    if "${_restore_cmd[@]}" >/dev/null 2>&1; then
        if wait_routing_ready; then
            ok "Original session restored and routing verified"
        else
            wrn "Restore connect OK but routing never came up; watchdog will retry"
        fi
    else
        wrn "Failed to restore original session; watchdog will retry at next cycle"
    fi
fi

# -- Write JSON results
EXIT_JSON=$(IFS=,; echo "[${EXIT_RESULTS[*]}]")
TRANSIT_JSON=$(IFS=,; echo "[${TRANSIT_RESULTS[*]}]")

python3 - "$RESULTS_FILE" "$TS" "$CURRENT_NODE" "$CURRENT_TRANSIT" \
    "$EXIT_JSON" "$TRANSIT_JSON" << 'PYEOF' || wrn "JSON write failed; watchdog will see stale results"
import json, os, sys
out_file, ts, cur_node, cur_transit, exit_raw, transit_raw = sys.argv[1:]
data = {
    "timestamp": ts,
    "current_node": cur_node,
    "current_transit": cur_transit,
    "exit_nodes": json.loads(exit_raw),
    "transit_nodes": json.loads(transit_raw),
}

# Enrich with server IPs (from cache built during this probe run)
ip_cache = {}
try:
    with open("/var/lib/surflare/node_ips.json") as _f:
        ip_cache = json.load(_f)
except Exception:
    pass

# Enrich with urltest monitoring status (from surflare-proxy log)
urltest = {}
try:
    with open("/run/surflare_node_health.json") as _f:
        h = json.load(_f)
    urltest = h.get("nodes", {})
except Exception:
    pass

def _enrich(node_list, is_transit=False):
    for n in node_list:
        name = n.get("name", "")
        n["server_ips"] = ip_cache.get(name, [])
        # urltest key: "mh_via_TRANSIT_to_NAME" for transit nodes,
        # or just "NAME" for single-hop exit probes
        if is_transit:
            # Transit was probed as: --transit NAME --node cur_node
            # urltest key for this path is mh_via_NAME_to_cur_node
            ut_key = f"mh_via_{name}_to_{cur_node}" if cur_node else name
        else:
            ut_key = f"mh_via_{cur_transit}_to_{name}" if cur_transit else name
        ut = urltest.get(ut_key, {})
        n["urltest_errors_15min"] = ut.get("error_count", 0)
        n["urltest_healthy"] = ut.get("error_count", 0) <= 10

_enrich(data["exit_nodes"],   is_transit=False)
_enrich(data["transit_nodes"], is_transit=True)

data["exit_nodes"].sort(key=lambda x: x.get("score", 0), reverse=True)
data["transit_nodes"].sort(key=lambda x: x.get("score", 0), reverse=True)

tmp = out_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, out_file)
print(f"Results written to {out_file}")
PYEOF
# python3 failure here is non-fatal; watchdog reads stale results gracefully

# -- Summary
echo ""
echo -e "${BLD}-- Recommendations --${RST_C}"
python3 - "$RESULTS_FILE" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))

print("\nExit nodes ranked:")
for n in data["exit_nodes"]:
    sc = n.get("score", 0)
    mark = "*" if sc >= 80 else ("OK" if sc >= 50 else "FAIL")
    status = n.get("status", "")
    extra = f" [{status}]" if status else ""
    print(f"  {mark} {n['name']:<18} score={sc:3d}  l7={n.get('curl_ms',-1)}ms  l4={n.get('l4_ms',-1)}ms{extra}")

print("\nTransit ranked:")
for t in data["transit_nodes"]:
    sc = t.get("score", 0)
    verdict = t.get("verdict", "?")
    mark = "*" if sc >= 80 else ("WARN" if sc >= 40 else "FAIL")
    status = t.get("status", "")
    extra = f" [{status}]" if status else ""
    print(f"  {mark} {t['name']:<18} score={sc:3d}  signal={verdict}{extra}")

best_exit = next((n for n in data["exit_nodes"] if n.get("status") != "CURRENT"), None)
best_transit = next((t for t in data["transit_nodes"] if t.get("status") != "CURRENT"), None)
if best_exit:
    print(f"\nBest exit for next rotation:  {best_exit['name']}  (score={best_exit.get('score',0)})")
if best_transit:
    print(f"Best transit for next rotation: {best_transit['name']}  (score={best_transit.get('score',0)})")
PYEOF
