#!/bin/bash
# Real local TLS delay test: validates that a TLS handshake exceeding 3s
# times out on old product code and succeeds on repaired product code.
#
# Fixture constraints:
# - Extracts _check_tunnel_egress() and _float_lte() from WATCHDOG.
# - Rewrites only destination URLs to the local loopback fixture.
# - Exercises the extracted product helper with its real curl argv (no hand-built caps).
# - Generates a local cert with SAN IP:127.0.0.1,DNS:localhost; trusted via CURL_CA_BUNDLE.
#   No --insecure.
# - Server binds port 0, writes bound port to readiness file after listen.
# - Start server directly in current shell (no command substitution), redirect stdout/stderr to log.
# - Read port from readiness file in parent shell.
# - Bypass environment proxy for loopback via test-only no_proxy="*".
# - Handshake delay ~4s (healthy <=5s) and ~6s (degraded <=15s).
# - Multi-threaded client handling.
# - Logs exact rc, HTTP code, time_namelookup (DNS), time_connect (TCP), time_appconnect (TLS), time_total.
# - Prints captured helper output OUT1/OUT2 to retain evidence and avoid SC2034.
# - Supports WATCHDOG env override for scratch mutation.

set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG="${WATCHDOG:-surflare_watchdog.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMPDIR_TEST=$(mktemp -d)
SERVER_PID=""
cleanup() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT INT TERM

# Ensure loopback bypasses any environment proxy
export no_proxy="*"
export NO_PROXY="*"

CERT_DIR="$TMPDIR_TEST/certs"
mkdir -p "$CERT_DIR"
KEY_FILE="$CERT_DIR/server.key"
CERT_FILE="$CERT_DIR/server.crt"

# 1. Generate trusted test cert with SAN localhost/IP
openssl req -x509 -newkey rsa:2048 -keyout "$KEY_FILE" -out "$CERT_FILE" \
	-days 1 -nodes -subj "/CN=127.0.0.1" \
	-addext "subjectAltName = IP:127.0.0.1,DNS:localhost" 2>/dev/null \
	|| { echo "FATAL: cert generation failed"; exit 1; }

# 2. Extract constants and functions from WATCHDOG
CONSTS=$(grep -E '^EGRESS_STREAK_THRESHOLD=|^EGRESS_STREAK_WINDOW=|^EGRESS_DEGRADED_TIMEOUT=|^EGRESS_DEAD_TIMEOUT=' "$WATCHDOG")
FLOAT_SRC=$(sed -n '/^_float_lte() {/,/^}/p' "$WATCHDOG")
[ -n "$FLOAT_SRC" ] || { echo "FATAL: _float_lte extract empty"; exit 1; }

start_tls_server() {
	local delay="$1"
	local ready_file="$2"
	local log_file="$3"
	python3 - "$KEY_FILE" "$CERT_FILE" "$ready_file" "$delay" >"$log_file" 2>&1 << 'PYEOF' &
import sys, ssl, socket, time, threading

keyfile = sys.argv[1]
certfile = sys.argv[2]
readyfile = sys.argv[3]
delay = float(sys.argv[4])

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile, keyfile)

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', 0))
port = srv.getsockname()[1]
srv.listen(20)

with open(readyfile, 'w') as f:
    f.write(str(port) + '\n')
    f.flush()

def handle_client(conn):
    try:
        time.sleep(delay)
        tls_conn = ctx.wrap_socket(conn, server_side=True)
        try:
            req = tls_conn.recv(1024)
        except Exception:
            pass
        tls_conn.sendall(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        tls_conn.close()
    except Exception:
        try:
            conn.close()
        except Exception:
            pass

while True:
    try:
        conn, addr = srv.accept()
        t = threading.Thread(target=handle_client, args=(conn,), daemon=True)
        t.start()
    except Exception:
        break
PYEOF
	SERVER_PID=$!
	for _ in $(seq 1 50); do
		if [ -s "$ready_file" ]; then
			break
		fi
		sleep 0.1
	done
	[ -s "$ready_file" ] || { echo "FATAL: TLS server failed to start"; exit 1; }
}

stop_tls_server() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	SERVER_PID=""
}

build_rewritten_egress() {
	local port="$1"
	python3 - "$WATCHDOG" "$port" << 'PY'
import sys, re
src = open(sys.argv[1]).read()
port = sys.argv[2]
egress = re.search(r'(_check_tunnel_egress\(\) \{[\s\S]*?\n\})', src).group(1)
new_egress = re.sub(
    r'local _targets="[^"]+"',
    f'local _targets="https://127.0.0.1:{port}/generate_204"',
    egress
)
print(new_egress)
PY
}

# -------------------------------------------------------------------------
# Test Case 1: 4.0s Handshake Delay (Healthy Band: <= 5.0s)
# -------------------------------------------------------------------------
READY_FILE1="$TMPDIR_TEST/ready1.txt"
LOG_FILE1="$TMPDIR_TEST/server1.log"
start_tls_server 4.0 "$READY_FILE1" "$LOG_FILE1"
PORT1=$(cat "$READY_FILE1")
echo "TLS server (4.0s delay) running on 127.0.0.1:$PORT1 (PID=$SERVER_PID)"

# Direct curl supporting evidence
raw_old=$(CURL_CA_BUNDLE="$CERT_FILE" curl -s --noproxy '*' \
	--connect-timeout 3 --max-time 15 \
	-o /dev/null \
	-w 'exit=%{exitcode} http_code=%{http_code} time_namelookup=%{time_namelookup} time_connect=%{time_connect} time_appconnect=%{time_appconnect} time_total=%{time_total}' \
	"https://127.0.0.1:${PORT1}/generate_204" 2>/dev/null)
echo "Direct curl (ct=3): $raw_old"

raw_new=$(CURL_CA_BUNDLE="$CERT_FILE" curl -s --noproxy '*' \
	--connect-timeout 15 --max-time 15 \
	-o /dev/null \
	-w 'exit=%{exitcode} http_code=%{http_code} time_namelookup=%{time_namelookup} time_connect=%{time_connect} time_appconnect=%{time_appconnect} time_total=%{time_total}' \
	"https://127.0.0.1:${PORT1}/generate_204" 2>/dev/null)
echo "Direct curl (ct=15): $raw_new"

EGRESS_1=$(build_rewritten_egress "$PORT1")
OUT1=$(CURL_CA_BUNDLE="$CERT_FILE" bash -c "
	export no_proxy='*' NO_PROXY='*'
	$CONSTS
	log() { echo \"LOG: \$*\"; }
	$FLOAT_SRC
	$EGRESS_1
	_check_tunnel_egress
" 2>/dev/null)
RC1=$?
echo "Product helper output (4.0s): ${OUT1:-<none>}"

echo "T1: Extracted product helper with 4.0s TLS handshake -> rc=$RC1 (want 0)"
if [ "$RC1" -eq 0 ]; then
	ok "T1 product egress 4.0s healthy"
else
	bad "T1 product egress rc=$RC1 want 0"
fi

stop_tls_server

# -------------------------------------------------------------------------
# Test Case 2: 6.0s Handshake Delay (Degraded Band: >5.0s and <=15.0s)
# -------------------------------------------------------------------------
READY_FILE2="$TMPDIR_TEST/ready2.txt"
LOG_FILE2="$TMPDIR_TEST/server2.log"
start_tls_server 6.0 "$READY_FILE2" "$LOG_FILE2"
PORT2=$(cat "$READY_FILE2")
echo "TLS server (6.0s delay) running on 127.0.0.1:$PORT2 (PID=$SERVER_PID)"

raw_new6=$(CURL_CA_BUNDLE="$CERT_FILE" curl -s --noproxy '*' \
	--connect-timeout 15 --max-time 15 \
	-o /dev/null \
	-w 'exit=%{exitcode} http_code=%{http_code} time_namelookup=%{time_namelookup} time_connect=%{time_connect} time_appconnect=%{time_appconnect} time_total=%{time_total}' \
	"https://127.0.0.1:${PORT2}/generate_204" 2>/dev/null)
echo "Direct curl 6s (ct=15): $raw_new6"

EGRESS_2=$(build_rewritten_egress "$PORT2")
OUT2=$(CURL_CA_BUNDLE="$CERT_FILE" bash -c "
	export no_proxy='*' NO_PROXY='*'
	$CONSTS
	log() { echo \"LOG: \$*\"; }
	$FLOAT_SRC
	$EGRESS_2
	_check_tunnel_egress
" 2>/dev/null)
RC2=$?
echo "Product helper output (6.0s): ${OUT2:-<none>}"

echo "T2: Extracted product helper with 6.0s TLS handshake -> rc=$RC2 (want 2)"
if [ "$RC2" -eq 2 ]; then
	ok "T2 product egress 6.0s degraded"
else
	bad "T2 product egress rc=$RC2 want 2"
fi

stop_tls_server

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
