---
phase: 02-cleanup-ops-hardening
plan: 02
status: complete
commit: 7e2d06a (combined with 02-01 urltest comment)
---

## Summary

Code cleanup and hardening completed: dead _connect_vpn_active variable removed,
SIGHUP/SIGPIPE signal traps added, _restore_tproxy sentinel verification added,
init.d _full_teardown synced with STORM_503_STATE cleanup, and SEC-04 nft trace
experiment completed.

## Tasks Completed

1. **SEC-02 (partial)**: Removed _connect_vpn_active guard (L1599-1602) and init
   (L3788).  Variable was initialized to 0 and never set to 1; guard was dead code.
   Killswitch self-lock (6d24d17) manages lifecycle.

2. **SEC-02 (partial)**: Added `trap 'log ...' HUP` and `trap ':' PIPE` after
   EXIT trap.  PIPE uses ':' handler (not SIG_IGN '') so children retain default
   SIGPIPE behavior -- critical for tail|while proxy log monitor cleanup.

3. **SEC-05**: Added sentinel in _restore_tproxy after nft -f load and rm -f of
   temp file: `nft list table inet sw_lan_tproxy` verification with CRITICAL log
   and return 1.  Placed before bypass set restoration for fast-fail.  return 1 is
   defensive -- callers do not currently check.

4. **OPS-06**: Added `rm -f /run/surflare_503_state /run/surflare_503_state.tmp`
   to init.d _full_teardown on N100 via SSH sed.  Uses hardcoded path (init.d does
   not source watchdog constants).

5. **SEC-04**: nft trace experiment on N100 (180s, 9829 trace lines).  Results:
   100% of 0xff-marked traffic goes to oif "pppoe-wan".  Zero lo/br-lan traffic.
   Decision: safe to add `oifname "pppoe-wan"` constraint to 0xff accept rule.
   Code change deferred to follow-up task.  Results at /tmp/nft_trace_0xff_results.txt.

## Review

Three-cycle static review (qodo/expert/adversarial) completed in 1 cycle -- all
3 passes CLEAN on first cycle.  Changes were also pre-reviewed in plan stage by
4 external models (DS/Kimi/MiMo-pro/GM) across 3 rounds to 0/0/0/0 convergence.

## Verification

- Task 1: `! grep -q '_connect_vpn_active' surflare_watchdog.sh` PASS
- Task 2: `grep -q "trap.*HUP"` + `grep -q "trap ':' PIPE"` PASS
- Task 3: `grep -q 'tproxy restore failed'` PASS
- Task 4: `ssh N100 "grep -q surflare_503_state /etc/init.d/surflare-watchdog"` PASS
- Task 5: `test -f /tmp/nft_trace_0xff_results.txt` PASS
- All: `bash -n surflare_watchdog.sh` PASS
