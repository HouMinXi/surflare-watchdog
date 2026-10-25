# Tests that are not part of the suite

`scripts/run-tests.sh` runs `tests/test_*.sh`. Anything else here is run by hand,
and this file is the reason it is not an oversight: a harness nobody runs looks
like coverage until someone asks which assertion it protects.

Two files qualify, both because they cannot run unattended on a laptop:

| File | Why it is manual | How to run it |
|---|---|---|
| `ded-exit-inject.sh` | needs `jq` and a captured sing-box config to inject into; the default fixture is committed but a real config is the useful input | `tests/ded-exit-inject.sh [captured-config.json]` on the router |
| `probe_rca_test.sh` | needs root and the live router: it captures routing diagnostics, not assertions on code | `sudo bash tests/probe_rca_test.sh` on the router |

Everything else that used to be here was moved into the suite once it turned
out to be self-contained: `run_smoke_tests.sh` (now
`test_cross_validate_smoke.sh`), `tui-picker-loop.sh` (now
`test_tui_picker_loop.sh`), `inject_tproxy_self_dial_guard.sh` (now
`test_tproxy_self_dial_injections.sh`) and `midnight_wrap_inject.sh` (now
`test_midnight_wrap_inject.sh`, which reports SKIP without root).

`tests/test_suite_isolation.sh` checks that every `tests/*.sh` outside the
`test_*` naming is named in this file, so a new manual harness has to be
declared rather than silently escaping the suite.