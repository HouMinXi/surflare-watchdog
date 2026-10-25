#!/bin/bash
# The updater calls a release good when the proxy is running, so "running" has
# to mean the service and not any process that happens to mention it.  It used
# to ask `pgrep -f surflare-proxy`, which a log tail, the watchdog's own
# monitor and the log health check all satisfy, so a release that never came up
# kept the check green and was left installed.
#
# Two details came off the router itself: it binds an IPv6 wildcard, so an IPv4
# connect is refused while the proxy is serving, and the kernel truncates a
# process name to fifteen characters, so the wrapper's exact name does not
# match.  The check reads the socket table, and falls back to the binary's own
# name for the moment between exec and the first listen.
set -u
cd "$(dirname "$0")/.." || exit 1
SUT=${SUT:-surflare-update.sh}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/bin_listen" "$TMP/bin_real"
sed -n '/^_proxy_listening() {/,/^}/p;/^proxy_running() {/,/^}/p' "$SUT" > "$TMP/pr.sh"
if ! grep -q '^proxy_running()' "$TMP/pr.sh"; then
	bad "could not extract proxy_running from $SUT"
	echo "RESULT: $pass passed, $fail failed"
	exit 1
fi

# A process whose command line mentions the proxy log is not the proxy.
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/pgrep"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/ss"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/netstat"

# The binary itself answers the fallback, matching only its own name.
printf '#!/bin/bash\nfor a in "$@"; do case "$a" in *surflare-proxy*real*) exit 0;; esac; done\nexit 1\n' \
	> "$TMP/bin_real/pgrep"

# A listening socket, as the router reports one.
printf '#!/bin/bash\nprintf "LISTEN 0 1 127.0.0.1:10800 0.0.0.0:*\\n"\n' > "$TMP/bin_listen/ss"
chmod +x "$TMP/bin/"* "$TMP/bin_listen/"* "$TMP/bin_real/"*

drive() { # $1 = PATH prefix
	PATH="$1:$PATH" READY_TIMEOUT=1 bash -c '. "$1"; proxy_running' _ "$TMP/pr.sh" >/dev/null 2>&1
	echo $?
}

got=$(drive "$TMP/bin")
if [ "$got" -ne 0 ]; then
	ok "no listener and no binary means the proxy is down"
else
	bad "an argv mention was accepted as a running proxy"
fi

got=$(drive "$TMP/bin_listen")
if [ "$got" -eq 0 ]; then
	ok "a listening socket counts as a running proxy"
else
	bad "a listening proxy was reported as down"
fi

got=$(drive "$TMP/bin_real")
if [ "$got" -eq 0 ]; then
	ok "the binary's own name covers the gap before it listens"
else
	bad "the binary's own name was not accepted"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
