#!/bin/bash
# The ring hook is one line that calls another script. Listing the hook and
# forgetting the script, or the other way round, leaves a boot that either
# does nothing or does it from a file an upgrade can drop.
set -u
cd "$(dirname "$0")/.." || exit 1
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

HOOK=router/hotplug/99-nic-rings
LIST=scripts/installed-files.list

if [ -x "$HOOK" ] && sh -n < "$HOOK"; then
	ok "the ring hook parses"
else
	bad "the ring hook is missing or does not parse"
fi

called=$(sed -n 's/.*\(\/usr\/local\/sbin\/[^ ]*\).*/\1/p' "$HOOK" | head -1)
if [ -n "$called" ] && grep -q ":$called:" "$LIST"; then
	ok "the script the hook runs is on the install list ($called)"
else
	bad "the hook runs $called and that path is not on the install list"
fi

if grep -q ":/etc/hotplug.d/iface/99-nic-rings:" "$LIST"; then
	ok "the hook itself is on the install list, so an upgrade keeps it"
else
	bad "the hook is not on the install list; sysupgrade would drop it"
fi

# The script has to set every port, and it has to say so only for the ports
# that took the setting. A log line that names eth0-eth3 after a refusal is
# the failure this exists to catch.
run_rings() { # $1 = ethtool stub, $2 = net dir
	PATH="$1:$PATH" NET="$2" sh router/sbin/set-nic-rings.sh
}

mkdir -p "$TMP/net"
for i in eth0 eth1 eth2 eth3; do mkdir -p "$TMP/net/$i"; done

# ethtool -g prints the current RX. The stub answers from a file so a test
# can say "already 4096" without the -G call succeeding: that is what the
# real tool does when nothing changed.
stub() { # $1 dir, $2 -G exit, $3 readback, $4 log
	mkdir -p "$1"
	# $1 in the generated stub is the stub's own argument, not this
	# function's. The single quotes keep it literal on purpose.
	# shellcheck disable=SC2016
	printf '%s\n' \
		'#!/bin/sh' \
		'case "$1" in' \
		"-G) echo \"ethtool \$*\" >> \"$4\"; exit $2 ;;" \
		"-g) printf 'Current hardware settings:\\nRX:\	%s\\n' '$3' ;;" \
		'esac' > "$1/ethtool"
	printf '#!/bin/sh\necho "logger $*" >> "%s"\n' "$4" > "$1/logger"
	chmod +x "$1/ethtool" "$1/logger"
}
stub "$TMP/bin-ok" 0 4096 "$TMP/log-ok"
stub "$TMP/bin-fail" 1 256 "$TMP/log-fail"
stub "$TMP/bin-same" 80 4096 "$TMP/log-same"

run_rings "$TMP/bin-ok" "$TMP/net"
if grep -q 'rings set to 4096 on eth0 eth1 eth2 eth3' "$TMP/log-ok" \
	&& [ "$(grep -c -- 'ethtool -G ' "$TMP/log-ok")" -eq 4 ]; then
	ok "all four ports set, and the log says so"
else
	bad "a clean apply was not reported honestly: $(cat "$TMP/log-ok")"
fi

run_rings "$TMP/bin-fail" "$TMP/net"
if grep -q 'rings not set' "$TMP/log-fail" \
	&& ! grep -q 'rings set to 4096' "$TMP/log-fail"; then
	ok "a refused apply does not claim the rings were set"
else
	bad "a failed apply still claimed success: $(cat "$TMP/log-fail")"
fi

run_rings "$TMP/bin-same" "$TMP/net"
if grep -q 'rings set to 4096 on eth0 eth1 eth2 eth3' "$TMP/log-same"; then
	ok "a ring already at 4096 is reported set, even though ethtool -G exits 80"
else
	bad "an unchanged ring was reported as a failure: $(cat "$TMP/log-same")"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
