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
  # DIRECT_DOMAINS: pin domains to the direct outbound.  The rule is
  # inserted before the FIRST tproxy-in rule, not near the catch-all:
  # the surflare tproxy rules reference rule_sets whose ip_cidr entries
  # (Cloudflare ranges included) would otherwise claim these domains
  # for the VPN before a later rule ever sees them.  Sniffing runs in
  # rule 0, so the sniffed domain is available at this position.
  # Entries are stripped of whitespace; empty entries are dropped and
  # an empty list inserts no rule at all.  Insertion is skipped when
  # no tproxy-in rule exists, so a surflare config layout change fails
  # safe (traffic stays on the VPN path).
  | ($DD | split(",") | map(gsub("[ \t]"; ""))
      | map(select(length > 0))) as $dd
  | ([.route.rules | to_entries[]
      | select(((.value.inbound // [])
          | if type == "array" then . else [.] end
          | any(. == "tproxy-in"))) | .key][0]
     // -1) as $pos
  | if ($dd | length) > 0 and $pos >= 0 then
      .route.rules |= (.[0:$pos]
        + [{domain_suffix: $dd, inbound: "tproxy-in", outbound: "direct"}]
        + .[$pos:])
    else . end
  # Find the active VPN urltest by type, not by a historical tag prefix.
  # Transit-pinned sessions use tags such as mh_via_Washington_to_Atlanta;
  # prefix-matching mh_via_auto_to silently fell back to direct and reopened
  # the catch-all leak whenever TRANSIT was pinned.  udp_ exclusion skips
  # the UDP-over-socks helper groups.  If no urltest survives the filter,
  # log loudly and keep the direct fallback (traffic must not blackhole).
  | ([.outbounds[] | select(.type == "urltest" and ((.tag | startswith("udp_")) | not))][0].tag // "direct") as $vpn
  | . as $cfg
  | if $vpn == "direct" then
      "surflare-proxy wrapper: WARN no urltest outbound found, catch-all stays direct (config layout changed?)" | stderr | $cfg
    else $cfg end
  | .route.rules[-1].outbound = $vpn
  | .route.final = $vpn
  # Dedicated-IP egress layer (EXIT_VIA_DED=1): append a socks outbound
  # to the dedicated exit, detoured through the carrier group.  Relay
  # arrival binds the dedicated egress IP; detour must never be direct
  # (a direct-dialed socks egresses a generic NAT instead).  Repoint
  # every rule that used the carrier group at ded-exit, then prepend a
  # guard rule that keeps connections TO the socks server itself on the
  # plain carrier -- without it any local forwarder pointing at the
  # proxy recurses socks-in-socks through ded-exit.
  | if $DE == "1" and $vpn != "direct" then
      .outbounds += [{
        "type": "socks",
        "tag": "ded-exit",
        "server": $ENV.DED_SERVER,
        "server_port": ($ENV.DED_PORT | tonumber),
        "username": $ENV.DED_USER,
        "password": $ENV.DED_PASS,
        "detour": $vpn
      }]
      | .route.rules |= map(if .outbound == $vpn then .outbound = "ded-exit" else . end)
      | .route.rules = [{"ip_cidr": [$ENV.DED_SERVER + "/32"], "outbound": $vpn}] + .route.rules
      | .route.final = "ded-exit"
      # Canary inbound: loopback-only port whose traffic follows
      # route.final (ded-exit).  surflare-ded-canary probes it every
      # minute; a failure triages the layer and can flip EXIT_VIA_DED
      # to 0.  Loopback-only: not reachable from the LAN.
      | .inbounds += [{
        "type": "mixed",
        "tag": "ded-canary-in",
        "listen": "127.0.0.1",
        "listen_port": 20814
      }]
    else . end
