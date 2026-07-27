#!/bin/sh
# surflare-proxy wrapper: patches urltest tolerance/interval before
# forwarding stdin JSON to the real binary.
# md5-gate: auto-restores patched binary if surflare auto-update replaces it.

# Raise fd limit before exec'ing the real binary.  procd_set_param
# limits in init.d sets rlimit on the watchdog script, but surflare
# connect --daemon daemonizes (fork+setsid) and reparents the proxy
# to PID 1, breaking rlimit inheritance.  Setting ulimit here
# (inside the wrapper, closest to exec) guarantees the proxy gets
# 65535 regardless of daemonize behavior.
# shellcheck disable=SC3045  # busybox ash supports ulimit -n (verified: proxy runs at 65535)
ulimit -n 65535 2>/dev/null || true

REAL_BIN="/usr/bin/surflare-proxy.real"
FALLBACK_BIN="/usr/local/lib/surflare-proxy-patched"
EXPECTED_MD5="427f12993868c1a40c999bd47f655995"
TOLERANCE=300
INTERVAL="60s"
# Domains missing from surflare's proxy_rule_set that must go through VPN.
# Without this, sing-box catch-all (rule 10: tproxy-in -> direct) routes
# them direct -> CN IP exposed or TLS handshake reset on direct route.
INJECT_DOMAINS="claude.com,grokipedia.com,ipinfo.io"

# md5-gate: detect and rollback surflare auto-update
_md5=$(md5sum "$REAL_BIN" 2>/dev/null | cut -d" " -f1)
if [ "$_md5" != "$EXPECTED_MD5" ] && [ -x "$FALLBACK_BIN" ]; then
	_fb_md5=$(md5sum "$FALLBACK_BIN" 2>/dev/null | cut -d" " -f1)
	if [ "$_fb_md5" = "$EXPECTED_MD5" ]; then
		# Capture new binary before rollback for diff analysis
		_au_bin="/tmp/surflare-proxy-autoupdate-$(date +%Y%m%d_%H%M%S)"
		cp "$REAL_BIN" "$_au_bin" && chmod 600 "$_au_bin"
		logger -t surflare-proxy "auto-update rolled back (new binary saved to /tmp)"
		cp "$FALLBACK_BIN" "$REAL_BIN"
	fi
fi

# Detect --config stdin among arguments
_stdin=0
for a in "$@"; do
	case "$a" in
		stdin) _stdin=1 ;;
	esac
done

if [ "$_stdin" -eq 0 ]; then
	exec "$REAL_BIN" "$@"
fi

# Two-stage: save stdin, patch with jq, feed to real binary
_tmp=$(mktemp) || exit 1
_patched=$(mktemp) || { rm -f "$_tmp"; exit 1; }
chmod 600 "$_tmp" "$_patched"
trap 'rm -f "$_tmp" "$_patched"' EXIT

cat > "$_tmp"
# Dump pre-patch config for debugging (routing rules, DNS, outbounds).
# Overwritten on each proxy restart.  chmod 600: contains server IPs.
cp "$_tmp" /tmp/singbox-config-dump.json
chmod 600 /tmp/singbox-config-dump.json

if jq --argjson T "$TOLERANCE" --arg I "$INTERVAL" --arg D "$INJECT_DOMAINS" '
  .outbounds |= map(if .type == "urltest" then .tolerance = $T | .interval = $I else . end)
  | .route.rule_set |= map(if .tag == "proxy_rule_set" then .rules |= map(
      if .domain_suffix then
        .domain_suffix |= (. + ($D | split(",")) | unique)
      else . end
    ) else . end)
  | if .dns.servers then
      .dns.servers |= map(
        # sing-box 1.12 DNS migration: {"address":"..."} ->
        # {"type":"<scheme>","server":"<host>"}.  default_domain_
        # resolver = dns-direct (CN DNS, direct detour) so dial
        # does not depend on VPN (chicken-and-egg with dns_remote).
        if (.address // "") | test("^[a-zA-Z]+://") then
          .type = (.address
              | capture("^(?<t>[a-zA-Z]+)://").t
              | ascii_downcase)
          | .server = (.address
              | sub("^[a-zA-Z]+://"; "")
              | sub("^.*@"; "")
              | sub("/.*$"; "")
            )
          | if (.server | test(":[0-9]+$")) then
              .server_port = (.server
                  | sub(".*:"; "") | tonumber)
              | .server = (.server
                  | sub(":[0-9]+$"; ""))
            else . end
          | del(.address)
        elif .address then
          .type = "udp"
          | .server = .address
          | if (.server | test(":[0-9]+$")) then
              .server_port = (.server
                  | sub(".*:"; "") | tonumber)
              | .server = (.server
                  | sub(":[0-9]+$"; ""))
            else . end
          | del(.address)
        else . end
      )
      | .route.default_domain_resolver = (
          .route.default_domain_resolver
          // {"server": "dns-direct"}
        )
    else . end
' < "$_tmp" > "$_patched"; then
	exec < "$_patched"
	rm -f "$_tmp" "$_patched"
	exec "$REAL_BIN" "$@"
else
	exec < "$_tmp"
	rm -f "$_tmp" "$_patched"
	exec "$REAL_BIN" "$@"
fi
