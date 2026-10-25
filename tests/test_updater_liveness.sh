#!/bin/bash
# The updater calls a release good when the proxy is running, so "running" has
# to mean the service and not any process that happens to mention it.  It used
# to ask `pgrep -f surflare-proxy`, which a log tail, the watchdog's own
# monitor and the log health check all satisfy -- so a release that never came
# up kept the check green and was left installed.
set -u
cd "$(dirname "$0")/.." || exit 1
SUT=${SUT:-surflare-update.sh}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
sed -n '/^proxy_running() {/,/^}/p' "$SUT" > "$TMP/pr.sh"
if [ ! -s "$TMP/pr.sh" ]; then
	bad "could not extract proxy_running from $SUT"
	echo "RESULT: $pass passed, $fail failed"
	exit 1
fi

# A command line that mentions the proxy, but is not the proxy.
cat > "$TMP/bin/pgrep" <<'EOS'
#!/bin/bash
# `-x` means "this exact process name", which the argv-only process is not.
for a in "$@"; do [ "$a" = "-x" ] && exit 1; done
exit 0
EOS
chmod +x "$TMP/bin/pgrep"

drive() { # $1 = READY_TIMEOUT
	PATH="$TMP/bin:$PATH" READY_TIMEOUT="$1" bash -c '. "$1"; proxy_running' _ "$TMP/pr.sh" >/dev/null 2>&1
	echo $?
}

if [ -n "${LISTEN_HELPER:-}" ] && command -v "$LISTEN_HELPER" >/dev/null 2>&1; then :; fi

# Nothing on :10800 and a process whose argv merely mentions the proxy.
if command -v python3 >/dev/null 2>&1 &&
	python3 -c 'import socket,sys
s=socket.socket()
try:
    s.bind(("127.0.0.1",10800)); s.close(); sys.exit(0)
except OSError:
    sys.exit(1)' 2>/dev/null; then
	got=$(drive 1)
	if [ "$got" -ne 0 ]; then
		ok "a command line that mentions the proxy is not a running proxy"
	else
		bad "an argv match was accepted as a running proxy"
	fi
else
	bad "port 10800 is occupied, cannot test the closed-port case"
fi

# A real listener on the port the proxy uses.
if command -v python3 >/dev/null 2>&1; then
	python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",10800)); s.listen(1)
time.sleep(8)' >/dev/null 2>&1 &
	listener=$!
	sleep 1
	got=$(drive 1)
	kill "$listener" 2>/dev/null
	wait "$listener" 2>/dev/null
	if [ "$got" -eq 0 ]; then
		ok "a listening port counts as a running proxy"
	else
		bad "a listening proxy was reported as down"
	fi
else
	echo "SKIP: no python3, cannot open the port"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
