---
gsd_state_version: 1.0
milestone: v68
milestone_name: Diagnostic Foundation + Stability Hardening
status: planning
stopped_at: milestone initialized
last_updated: "2026-07-11T09:00:00.000Z"
last_activity: 2026-07-11 -- v68 milestone created (post-v67 incident-driven hardening)
progress:
  total_phases: 3
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
  percent: 0
---

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-05)

**Core value:** Transparent, always-on VPN with zero-leak killswitch and automatic failure recovery
**Current focus:** v68 -- diagnostic foundation + stability hardening

## Current Position

Phase: Not started (milestone in planning)
Status: v68 milestone designed, awaiting /gsd:plan-phase 1
Last activity: 2026-07-11 -- v68 milestone created

## Previous Milestone

v67 "Operational Maturity + Recovery Acceleration" -- COMPLETE (2026-07-09)
3 phases, 7 plans, 100%. Post-v67 incident-driven work (2026-07-11):
instance-lock crash-loop fix, fd inheritance fix, fw4 reload fix,
3 new observability probes (fd/nft/conntrack), Issue B (proxy_rule_set
whitelist routing) root cause + fix, architecture diagram update,
wrapper backport to repo. All committed and deployed to N100.

## Accumulated Context

### Decisions (carried from v67 + this session)

- Zero-kill restart: proxy preserved across init.d restart (v67, validated)
- fw4 reload not restart: reload preserves surflare nftables table (v68 finding)
- Instance lock: _instance_lock_acquired flag gates cleanup (v68 fix)
- fd inheritance: 200>&- on surflare connect prevents proxy holding lock (v68 fix)
- sing-box rule mode: whitelist routing, catch-all (rule 10) goes direct (v68 finding)
- INJECT_DOMAINS: wrapper injects domains into proxy_rule_set (v68: grokipedia.com, ipinfo.io)
- Config dump: wrapper saves pre-patch config to /tmp/singbox-config-dump.json (v68 addition)

### Open Items (v68 scope)

- fd limit 1024: wrapper ulimit -n 65535 not inherited by surflare connect --daemon
- api.ipify.org mystery: not in proxy_rule_set but exits VPN (contradicts routing rules)
- 72h fd telemetry: connectionCopy fix deployed but no long-term monitoring
- Remaining 200>&- leaks: tcpdump, diag-proxy-broken.sh fire-and-forget
- Domain whitelist: manual INJECT_DOMAINS, no auto-discovery

## Session Continuity

Last session: 2026-07-11
Stopped at: v68 milestone initialized
Resume: /gsd:plan-phase 1
