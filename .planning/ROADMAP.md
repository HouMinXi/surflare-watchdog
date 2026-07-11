# Roadmap: v68 Diagnostic Foundation + Stability Hardening

## Overview

Prepare surflare-watchdog for fleet H3 (AI diagnosis agent) by building
diagnostic data collection, expanding observability, and fixing remaining
stability gaps discovered during post-v67 incident-driven work.

Derived from: 2026-07-11 session findings (instance-lock crash, fd leak,
fw4 flush, Issue B routing), memory scan (27 files), and fleet roadmap H3.

## Milestones

<details>
<summary>v64 Resilience and Stability (Phases 0-7) - SHIPPED</summary>

- Phase 0: procd respawn fix
- Phase 0.5: reconnect optimization v3.2
- Phase 1: REJECT protocol feedback
- Phase 2: tombstone storm + server_ips resilience
- Phase 3: proxy-path health probe
- Phase 4: stale proxy detection + port cleanup
- Phase 5: boot-time lockdown
- Boot defects + bugfixes

</details>

<details>
<summary>v65 WARP Storm Fallback - ABORTED</summary>

GFW blocks WARP TCP SYN at IP level. See memory `09-v65-warp-aborted.md`.

</details>

<details>
<summary>v66 Security Hardening + Tunnel Resilience - COMPLETE</summary>

- Phase 1: Killswitch chain-level reinstall (6d24d17)
- Phase 2: Tunnel resilience tuning (wrapper md5-gate, urltest 300ms, sysctl)
- Phase 3: Supply chain + operational (exit country enforcement, hash log, stats)

</details>

<details>
<summary>v67 Operational Maturity + Recovery Acceleration - COMPLETE (2026-07-09)</summary>

- Phase 1: Observability Probes (DNS, tmpfs, crond, memory, BPF; storm cooldown)
- Phase 2: Cleanup + Ops Hardening (deploy safety, sysupgrade, dead code, killswitch)
- Phase 3: Recovery Acceleration + Alerting (DEGRADED_INTERVAL, CONNECT_SETTLE, Server Chan)
- Post-v67 incident fixes (2026-07-11): instance-lock, fd inheritance, fw4 reload, 3 new probes

</details>

- **v68 Diagnostic Foundation + Stability Hardening** - Phases 1-3

## Phases

- [ ] **Phase 1: Stability Fixes** -- fd limit inheritance, remaining fd leaks, api.ipify.org mystery, procd respawn handling
- [ ] **Phase 2: Observability + Diagnostic Data** -- 72h fd telemetry, proxy log real-time, domain whitelist auto-discovery, structured state export, config dump on failure
- [ ] **Phase 3: Fleet H3 Foundation** -- advisory-only diagnosis interface, WeChat diagnosis alert, VPN-independent path design, fault-inject acceptance

## Phase Details

### Phase 1: Stability Fixes
**Goal**: Resolve remaining stability gaps from post-v67 incident work
**Depends on**: Nothing (standalone fixes)
**Plans:** 3 plans
Plans:
- [ ] 01-01-PLAN.md - Fix fd 200 leaks (tcpdump + sleeps + cleanup) + add prlimit fd limit raise
- [ ] 01-02-PLAN.md - Change procd respawn to infinite retries + add cron watchdog-of-watchdog
- [ ] 01-03-PLAN.md - Investigate api.ipify.org routing mystery on N100
**Success Criteria**:
  1. Proxy fd limit is 65535 (not 1024) -- verified via /proc/pid/limits
  2. No remaining 200>&- leaks -- all background spawns close fd 200
  3. api.ipify.org routing mystery resolved or documented as known limitation
  4. Watchdog auto-recovers from procd respawn threshold exhaustion

### Phase 2: Observability + Diagnostic Data
**Goal**: Expand monitoring and build diagnostic data foundation for AI diagnosis
**Depends on**: Phase 1 (stability fixes ensure clean baseline)
**Plans:** TBD
**Success Criteria**:
  1. 72h fd telemetry: sustained >50% for 1h triggers alert (not just point-in-time)
  2. Proxy log error rate integrated into main loop (not cron-based 3-min delay)
  3. Domain whitelist auto-discovery: detect "connection reset" on direct route, suggest INJECT_DOMAINS addition
  4. Structured diagnostic state export: JSON snapshot (fd, conntrack, nftables, VPN exit, node, uptime, reconnects)
  5. Config auto-dump on health check failure (post-mortem data capture)

### Phase 3: Fleet H3 Foundation
**Goal**: Prepare advisory-only diagnosis interface for fleet H3 AI agent
**Depends on**: Phase 2 (diagnostic data collection provides input for diagnosis)
**Plans:** TBD
**Success Criteria**:
  1. Advisory-only diagnosis function: collects diagnostic data, outputs structured diagnosis, NEVER actuates (procd stays enforcement)
  2. WeChat alert sends structured diagnosis on VPN failure (not just "VPN down")
  3. VPN-independent diagnostic path design documented (local qwen or direct US API, never CN cross-Pacific)
  4. Fault-inject acceptance: simulated VPN failure produces correct diagnosis in <30s

---
*Roadmap created: 2026-07-11*
*Previous milestone: v67 (complete 2026-07-09)*
