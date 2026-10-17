# Ded-exit injection test inputs

`ded-exit-inject.sh` runs the TDD defect-injection harness for the
ded-exit layer.  It needs one raw (pre-wrapper) surflare sing-box
config as input:

    ssh root@192.168.100.1 'SURFLARE_DEBUG=1 timeout 30 \
        surflare connect --node Chicago --mode rule --transit Tokyo --daemon'
    scp root@192.168.100.1:/tmp/singbox-config-dump.json ./test-input.json
    # then restore the live session on the router

    sh tests/ded-exit-inject.sh ./test-input.json

The harness asserts, on the pristine filter:

- guard rule `DED_IP/32 (as injected) -> carrier` is rule[0] and not ded-exit
  (without it the :20812 standalone forwarder recurses socks-in-socks)
- canary inbound `ded-canary-in` 127.0.0.1:20814 exists

then re-runs two injected copies of the filter (guard removed; canary
inbound removed) and asserts each injection turns its check red, plus a
pure-shell canary flip simulation.  Baseline green + injection red =
the assertions have teeth.

Note: the committed `filter-new2.jq` must stay byte-identical to the
jq program embedded in `router/surflare-proxy`; the wrapper is the
source of truth, this copy exists so the harness runs without
extracting from the wrapper each time.  If `router/surflare-proxy`
changes, regenerate: see the splice/extract snippet in the PR
description.

## Assertions

- base x2: guard rule is rule[0] and not ded-exit; canary inbound present
- J1: guard-rule prepend removed -> guard absent (red as expected)
- J2: canary inbound removed -> inbound absent (red as expected)
- J3: canary flip rewrites EXIT_VIA_DED in the conf
- J4: wrapper(closed) -> reattach jq output == wrapper(de1) output
  minus inbounds (shadow probes the exact production chain shape)
- A1: EXIT_VIA_DED off -> filter-new2 output byte-identical to
  filter-old (zero behavior change when the layer is disabled)
- J5: tests/filter-new2.jq byte-identical to the jq program embedded
  in router/surflare-proxy (extraction via awk, quote char via -v)
- J3b: unquoted conf values parse like quoted ones
- J6: layer ON + no carrier urltest -> graceful no-injection
- J7: conf parser/validator identical across wrapper/canary/reattach
- base port-80: bypass rule sits at rules[1] (right after the guard)
  and keeps plain HTTP on the carrier -- the dedicated SOCKS refuses
  port 80 with code=5
- J10: port-80 bypass removed -> assertion red as expected
- baseline: filter-old.jq matches its frozen md5
- base canary-port assertion cross-references CANARY_PORT dynamically

## Hermetic fixture

`tests/fixture-input.json` is a minimal synthetic sing-box config (one
urltest carrier, two vless members, tproxy inbound, dns, route with
`rule_set: []`). The harness runs against it by default, so it works
without a live router. For full realism pass a captured raw config:
`sh tests/ded-exit-inject.sh /tmp/singbox-config-dump.json` (capture
instructions above).
