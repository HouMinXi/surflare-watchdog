# N100 Overlay

Custom artifacts deployed to the N100 router that don't fit in the main
watchdog script. Everything here is reproducible from source.

The surflare-proxy wrapper is NOT here despite the name of this directory.
It lives at `scripts/surflare-proxy-wrapper.sh` and that is the copy that
gets deployed to `/usr/bin/surflare-proxy`. A second copy used to sit in
this directory calling itself the canonical source; it stopped being
updated on 2026-07-19 and was removed. If you need to confirm which file
is live, compare md5 against the router rather than trusting a path.

## patches/

sing-box URLTest timeout fix (upstream PR#4256). Two versions:

- `sing-box-v1.10.7-urltest-timeout.patch` -- for v1.10.7 (surflare v4.1.1)
- `sing-box-master-urltest-timeout.patch` -- for current master

Fixes triple self-lock: missing SetReadDeadline + batch.Wait() timeout +
stale history cleanup. Without this, relay degradation freezes the gateway
permanently. See surflare-watchdog memory #18 for full root cause.

Remove when upstream merges PR#4256 and surflare upgrades sing-box.

## build-singbox.sh

One-command build: clone sing-box, apply patch, cross-compile static binary.

```bash
./build-singbox.sh          # v1.10.7 (default)
./build-singbox.sh v1.11.0  # other version (uses master patch)
```

Output: `surflare-proxy-patched` (gitignored, ~46MB).

## bpf/ (TODO)

BPF keepalive clamp source. Currently only the compiled .o exists on N100
at `/usr/local/lib/bpf/clamp_keepalive.bpf.o`. Source needs reconstruction
from session history (Design Decision #12).
