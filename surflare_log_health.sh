#!/bin/bash
# surflare_log_health.sh
# Parse /var/log/surflare/surflare-proxy.log to extract real-time node health
# from surflare-proxy's internal urltest results (CN-IP perspective, zero VPN disruption).
#
# surflare-proxy runs sing-box urltest outbounds for ALL node/transit combos.
# Errors are logged; successes are silent (DEBUG level, not written to log).
# So: errors in last N minutes -> unhealthy; no errors -> likely healthy.
#
# Output: /run/surflare_node_health.json
# Usage: surflare_log_health.sh [--window-minutes N] [--out FILE]
# Compatible: laptop (Fedora) + N100 (iStoreOS) - same log path on both.

set -o nounset

readonly LOG_FILE="/var/log/surflare/surflare-proxy.log"
readonly DEFAULT_OUT="/run/surflare_node_health.json"
readonly DEFAULT_WINDOW=10   # minutes of log to scan

WINDOW_MINUTES=$DEFAULT_WINDOW
OUT_FILE=$DEFAULT_OUT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-minutes)
            [[ -n "${2:-}" ]] || { echo "Missing value for --window-minutes"; exit 1; }
            WINDOW_MINUTES="$2"; shift 2 ;;
        --out)
            [[ -n "${2:-}" ]] || { echo "Missing value for --out"; exit 1; }
            OUT_FILE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

[ -f "$LOG_FILE" ] || { echo "Log not found: $LOG_FILE"; exit 1; }

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Parse: extract urltest errors from last WINDOW_MINUTES minutes
# Log format: +0800 2026-06-15 23:07:10 ERROR [...] outbound/urltest[NODE]: message
python3 - "$LOG_FILE" "$TS" "$WINDOW_MINUTES" "$OUT_FILE" << 'PYEOF'
import json, os, re, sys
from datetime import datetime, timezone, timedelta

log_path, ts_now, window_min, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

# Build cutoff time (local +0800 timezone for log comparison)
now_utc = datetime.now(timezone.utc)
cutoff_utc = now_utc - timedelta(minutes=window_min)

# Parse log lines efficiently: tail last ~10k lines (avoids reading full 169K log)
pat_line = re.compile(
    r'^\+0800 (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) ERROR .* outbound/urltest\[([^\]]+)\]: (.+)$'
)
TZ_CST = timezone(timedelta(hours=8))

node_errors = {}   # node_name -> {"count": N, "last": "msg", "last_ts": datetime}
lines_scanned = 0

with open(log_path, 'rb') as f:
    # Seek to ~last 2MB to avoid scanning full file (avg line ~120 bytes, 2MB ~ 17k lines)
    f.seek(0, 2)
    size = f.tell()
    f.seek(max(0, size - 2_000_000))
    f.readline()  # skip partial line
    for raw in f:
        lines_scanned += 1
        try:
            line = raw.decode('utf-8', errors='ignore').rstrip()
        except Exception:
            continue
        m = pat_line.match(line)
        if not m:
            continue
        ts_str, node, msg = m.group(1), m.group(2), m.group(3)
        try:
            log_dt = datetime.strptime(ts_str, '%Y-%m-%d %H:%M:%S').replace(tzinfo=TZ_CST)
        except ValueError:
            continue
        if log_dt.astimezone(timezone.utc) < cutoff_utc:
            continue   # outside window
        if node not in node_errors:
            node_errors[node] = {"count": 0, "last_msg": "", "last_ts": None}
        node_errors[node]["count"] += 1
        node_errors[node]["last_msg"] = msg[:120]
        node_errors[node]["last_ts"] = ts_str

# Build result: include both observed nodes and infer healthy/unhealthy
nodes_out = {}
for node, info in sorted(node_errors.items()):
    nodes_out[node] = {
        "healthy": False,
        "error_count": info["count"],
        "last_error": info["last_msg"],
        "last_error_ts": info["last_ts"],
    }

out = {
    "timestamp": ts_now,
    "window_minutes": window_min,
    "lines_scanned": lines_scanned,
    "nodes": nodes_out,
}

tmp = out_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(out, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, out_path)

# Print summary to stdout
healthy_count = sum(1 for n in nodes_out.values() if n["healthy"])
unhealthy = [(k, v["error_count"]) for k, v in nodes_out.items()]
unhealthy.sort(key=lambda x: -x[1])
print(f"Window: {window_min}min | Lines scanned: {lines_scanned}")
print(f"Unhealthy nodes ({len(unhealthy)}):")
for name, cnt in unhealthy:
    print(f"  {'DEAD':6s} {name} ({cnt} errors)")
print(f"Results -> {out_path}")
PYEOF
