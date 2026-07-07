# Roadmap: v67 Operational Maturity + Recovery Acceleration

## Overview

Elevate surflare-watchdog from "works" to "operable". Three phases:
observability probes, operational/security hardening, and recovery
speed improvement. Derived from 2x blindspot scans (94 findings).

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

- **v67 Operational Maturity + Recovery Acceleration** - Phases 1-3

## Phases

- [x] **Phase 1: Observability Probes** -- Add health monitoring for DNS, tmpfs, memory, crond, BPF; storm cooldown sub-loop (5757750)
- [x] **Phase 2: Cleanup + Ops Hardening** -- Deploy safety, sysupgrade protection, dead code removal, killswitch constraint, watchdog-of-watchdog (16ba465)
- [ ] **Phase 3: Recovery Acceleration + Alerting** -- DEGRADED_INTERVAL tuning, CONNECT_SETTLE optimization, failback gate, Server Chan alerting

## Phase Details

### Phase 1: Observability Probes
**Goal**: Watchdog monitors its own ecosystem health, not just VPN tunnel
**Requirements**: OBS-01, OBS-02, OBS-03, OBS-04, OBS-05, OBS-06, OBS-07
**Depends on**: Nothing (standalone)
**Plans:** 1 plan
Plans:
- [x] 01-01-PLAN.md -- Add _run_observability_probes() function and storm cooldown sub-loop (5757750)
**Success Criteria**:
  1. SmartDNS/dnsmasq absence detected and auto-restarted within 30s
  2. tmpfs >50% logged as WARN, >70% as CRITICAL in dmesg
  3. crond absence detected and logged
  4. MemAvailable <500MB logged; sing-box oom_score_adj=-1000
  5. Storm cooldown still runs probe sub-loop every 60s
  6. All probes complete within 5s total budget (parallel execution)

### Phase 2: Cleanup + Ops Hardening
**Goal**: Deploy safely, survive firmware upgrades, remove dead code
**Requirements**: OPS-01 through OPS-06, SEC-01 through SEC-05, DOC-01
**Depends on**: Nothing (standalone)
**Plans:** 3 plans
Plans:
- [x] 02-01-PLAN.md -- Config + cleanup: orphan files, sysupgrade, log buffer, cron, urltest doc (7e2d06a)
- [x] 02-02-PLAN.md -- Code cleanup: dead code removal, signal traps, tproxy sentinel, init.d sync, 0xff experiment (7e2d06a)
- [x] 02-03-PLAN.md -- Deploy safety: surflare_deploy.sh wrapper with syntax check, backup, rollback (a6bd495)
**Success Criteria**:
  1. surflare_deploy.sh: bash -n validates, .prev backup created, auto-rollback on crash
  2. Cron watchdog-of-watchdog: pgrep || start every 5min
  3. sysupgrade.conf: surflare files listed, survive test firmware upgrade
  4. IPv6 forwarding=1 in sysctl.d (not overridden to 0)
  5. _connect_vpn_active dead code removed, SIGHUP/SIGPIPE trapped
  6. killswitch output 0xff evaluated via nft trace; constrained to oifname pppoe-wan if experiment confirms safety
  7. 30MB+ orphaned files deleted from N100

### Phase 3: Recovery Acceleration + Alerting
**Goal**: Reduce VPN recovery time and add alerting
**Requirements**: REC-01 through REC-06
**Depends on**: Phase 1 (observability probes provide data for tuning)
**Success Criteria**:
  1. DEGRADED_INTERVAL=10s (was 15s)
  2. check_vpn_local_state fast-path in DEGRADED reduces detection to <1ms for definitive failures
  3. CONNECT_SETTLE measured and reduced if data supports it
  4. Failback gate: 3 consecutive healthy checks before DEGRADED to normal
  5. Killswitch forward chain smoke test passes
  6. Server Chan alert fires on VPN-down; VPN-down fallback path verified

---
*Roadmap created: 2026-07-06*
*Last updated: 2026-07-07 after Phase 2 execution*
