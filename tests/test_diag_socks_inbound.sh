#!/bin/bash
# The proxy must expose a loopback diagnostic inbound that speaks SOCKS5.
#
# Port 10800 is a tproxy listener: it only accepts flows the nft rules
# redirected, so a SOCKS client pointed at it hangs until timeout.  A
# working tunnel then looks dead, which is exactly the misreading that
# drove needless node rotations.  The wrapper adds diag-socks-in on
# 127.0.0.1:10808 so `curl --socks5-hostname 127.0.0.1:10808 <url>`
# answers the reachability question directly.
#
# The test drives the real wrapper against a real-shaped config; only the
# final binary is stubbed so the patched stdin can be inspected.
set -u
cd "$(dirname "$0")/.." || exit 1
WRAPPER="${WRAPPER:-router/surflare-proxy}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || { echo "RESULT: 0 passed, 0 failed (jq missing, SKIP)"; exit 0; }

# A config shaped like the provider's: one tproxy inbound, a urltest
# outbound, and a catch-all route.  No real credentials are involved.
cat > "$TMP/in.json" <<'JSON'
{
  "inbounds": [{"tag": "tproxy-in", "type": "tproxy", "listen": "::", "listen_port": 10800}],
  "outbounds": [
    {"tag": "direct", "type": "direct"},
    {"tag": "mh_via_Tokyo_to_Chicago", "type": "urltest", "outbounds": ["a"], "tolerance": 50, "interval": "30s"}
  ],
  "route": {
    "final": "direct",
    "rule_set": [{"tag": "proxy_rule_set", "rules": [{"domain_suffix": ["example.com"]}]}],
    "rules": [{"inbound": "tproxy-in", "outbound": "direct"}]
  }
}
JSON

# Stub the real binary so the wrapper's patched stdin can be read back.
cat > "$TMP/real.sh" <<EOF
#!/bin/sh
cat > "$TMP/out.json"
EOF
chmod +x "$TMP/real.sh"

sed "s|^REAL_BIN=.*|REAL_BIN=\"$TMP/real.sh\"|" "$WRAPPER" > "$TMP/wrapper.sh"
chmod +x "$TMP/wrapper.sh"

if ! "$TMP/wrapper.sh" run --config stdin < "$TMP/in.json" 2>/dev/null; then
	bad "wrapper ran against the sample config"
	echo "RESULT: $PASS passed, $FAIL failed"
	exit 1
fi
ok "wrapper ran against the sample config"

if jq -e '.inbounds[] | select(.tag == "diag-socks-in")' "$TMP/out.json" >/dev/null 2>&1; then
	ok "diag-socks-in is present"
else
	bad "diag-socks-in is present"
fi

if jq -e '.inbounds[] | select(.tag == "diag-socks-in" and .listen == "127.0.0.1")' \
	"$TMP/out.json" >/dev/null 2>&1; then
	ok "diagnostic port is loopback-only"
else
	bad "diagnostic port is loopback-only"
fi

if jq -e '.inbounds[] | select(.tag == "diag-socks-in" and .type == "mixed" and .listen_port == 10808)' \
	"$TMP/out.json" >/dev/null 2>&1; then
	ok "diagnostic inbound accepts SOCKS5 and HTTP CONNECT on 10808"
else
	bad "diagnostic inbound accepts SOCKS5 and HTTP CONNECT on 10808"
fi

if jq -e '.inbounds[] | select(.tag == "tproxy-in" and .listen_port == 10800 and .listen == "::")' \
	"$TMP/out.json" >/dev/null 2>&1; then
	ok "the tproxy inbound keeps its port and bind address"
else
	bad "the tproxy inbound keeps its port and bind address"
fi

if [ "$(jq '.inbounds | length' "$TMP/out.json")" = "2" ]; then
	ok "exactly one inbound was added"
else
	bad "exactly one inbound was added"
fi

if jq -e . "$TMP/out.json" >/dev/null 2>&1; then
	ok "patched config is valid JSON"
else
	bad "patched config is valid JSON"
fi

# Re-processing an already patched config must not duplicate the inbound.
if ! "$TMP/wrapper.sh" run --config stdin < "$TMP/out.json" 2>/dev/null; then
	bad "wrapper re-ran on its own patched output"
	echo "RESULT: $PASS passed, $FAIL failed"
	exit 1
fi
if [ "$(jq '[.inbounds[] | select(.tag == "diag-socks-in")] | length' "$TMP/out.json")" = "1" ]; then
	ok "an existing diagnostic inbound is not duplicated"
else
	bad "an existing diagnostic inbound is not duplicated"
fi

# A provider config that already binds 10808 must not gain a second
# listener on that port: sing-box would refuse to start.
jq '.inbounds += [{"tag": "upstream-mixed", "type": "mixed", "listen": "0.0.0.0", "listen_port": 10808}]' \
	"$TMP/in.json" > "$TMP/collision.json"
if ! "$TMP/wrapper.sh" run --config stdin < "$TMP/collision.json" 2>/dev/null; then
	bad "wrapper ran against the port-collision config"
	echo "RESULT: $PASS passed, $FAIL failed"
	exit 1
fi

if [ "$(jq '[.inbounds[] | select(.listen_port == 10808)] | length' "$TMP/out.json")" = "1" ]; then
	ok "no second listener when the provider already uses 10808"
else
	bad "no second listener when the provider already uses 10808"
fi

if [ "$(jq '[.inbounds[] | select(.tag == "diag-socks-in")] | length' "$TMP/out.json")" = "0" ]; then
	ok "diagnostic tag is not injected into an occupied port"
else
	bad "diagnostic tag is not injected into an occupied port"
fi

if jq -e '.inbounds[] | select(.tag == "upstream-mixed" and .listen == "0.0.0.0")' \
	"$TMP/out.json" >/dev/null 2>&1; then
	ok "the provider's own 10808 listener is preserved"
else
	bad "the provider's own 10808 listener is preserved"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
