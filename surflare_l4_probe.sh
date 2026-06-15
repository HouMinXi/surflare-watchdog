#!/bin/bash
# surflare_l4_probe.sh
# Non-intrusive L4 reachability probe using SO_MARK=0xff (WAN bypass).
# Reads /var/lib/surflare/node_ips.json (populated by 4am surflare_node_probe.sh).
# Does NOT disconnect VPN. Writes /run/surflare_l4_scores.json.
# Schedule: every 30 min via cron.

set -o nounset

readonly IP_CACHE="/var/lib/surflare/node_ips.json"
readonly RESULTS="/run/surflare_l4_scores.json"
readonly LOCK="/run/surflare_l4_probe.lock"
readonly TIMEOUT_S=3
readonly STALE_WARN_H=48

[ "$(id -u)" -ne 0 ] && { echo "Must run as root"; exit 1; }

exec 9>"$LOCK"
flock -n 9 || { echo "Another l4_probe already running; skipping."; exit 0; }

[ -f "$IP_CACHE" ] || { echo "No node IP cache at $IP_CACHE; run node_probe first."; exit 0; }

# Warn if cache is stale (default 4am probe may not have run yet)
cache_age=$(( $(date +%s) - $(stat -c %Y "$IP_CACHE" 2>/dev/null || echo 0) ))
[ "$cache_age" -gt $(( STALE_WARN_H * 3600 )) ] && \
    echo "WARN: node IP cache is older than ${STALE_WARN_H}h; scores may be outdated."

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Probe all nodes and write JSON results via one Python process (no subprocess nesting)
python3 - "$IP_CACHE" "$RESULTS" "$TS" "$TIMEOUT_S" << 'PYEOF'
import json, os, socket, sys, time

cache_path, results_path, ts, timeout_s = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
SO_MARK = 36  # socket.SO_MARK

try:
    with open(cache_path) as f:
        cache = json.load(f)
    if not isinstance(cache, dict):
        raise ValueError(f"expected dict, got {type(cache).__name__}")
except Exception as e:
    print(f"ERROR: cannot read {cache_path}: {e}")
    sys.exit(1)

def l4_probe(ip, port=443):
    """TCP handshake via SO_MARK=0xff (bypasses tproxy, goes direct to WAN)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, SO_MARK, 0xff)
        s.settimeout(timeout_s)
        t0 = time.monotonic()
        s.connect((ip, port))
        return int((time.monotonic() - t0) * 1000)
    except Exception:
        return -1
    finally:
        s.close()

def score_rtt(rtt):
    if rtt < 0:   return 0
    if rtt < 100: return 100
    if rtt < 200: return 80
    if rtt < 400: return 60
    return 40

scores = []
print(f"{'Node':<22} {'Best IP':<18} {'RTT':>6}  Status")
print("-" * 56)

for node, ips in sorted(cache.items()):
    best_rtt, best_ip = -1, ""
    for ip in ips:
        rtt = l4_probe(ip)
        if rtt >= 0 and (best_rtt < 0 or rtt < best_rtt):
            best_rtt, best_ip = rtt, ip

    reachable = best_rtt >= 0
    node_score = score_rtt(best_rtt)
    status = f"OK {best_rtt}ms" if reachable else "UNREACHABLE"
    print(f"  {node:<20} {best_ip:<18} {best_rtt:>5}ms  {status}")
    scores.append({
        "node": node, "ips": ips, "best_ip": best_ip,
        "l4_rtt_ms": best_rtt, "reachable": reachable, "score": node_score,
    })

scores.sort(key=lambda x: x["score"], reverse=True)
out = {"timestamp": ts, "nodes": scores}
tmp = results_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(out, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, results_path)
print(f"\nResults written -> {results_path}")
PYEOF
