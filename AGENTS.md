# AGENTS.md — nokey project conventions

## What this project is

Several one-shot Bash entrypoints sharing `nokey-common.sh`. `nokey.sh` installs
Xray VLESS + Reality + BBR by default and adds an IPv6-bound Shadowsocks 2022
inbound when a local global IPv6 address exists; Realm, SOCKS, WARP,
standalone BBR, ACME certificates, and Hysteria2 are separate
feature entrypoints. All run from `curl | bash` or process substitution and
must work on minimal environments
(Alpine Pods with 64MB RAM, busybox tools, OpenRC), Debian/Ubuntu, CentOS/Rocky,
Fedora, AlmaLinux.

## Context routing

- `docs/ARCHITECTURE.md`: configuration flow, egress/DNS and diagnostic boundaries.
- `docs/TESTING.md`: unit, module, terminal and opt-in real network verification.
- `specs/2026-10-25-output-logs-default-route/`: current feature contract and handover.
- `specs/2026-10-25-xray-yaml-trial/`: experimental YAML config path and verification.
- `specs/2026-10-26-xray-shadowsocks-ipv6/`: default and standalone Xray Shadowsocks inbound contract.

## Non-negotiables

- **Modular entrypoints.** Feature logic belongs in its matching script. Shared
  portable helpers belong in `nokey-common.sh`; do not duplicate them.
- **Sourced by tests.** Every entrypoint's main flow MUST be guarded:
  `if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then main "$@"; fi`.
  Nothing may auto-run on `source`.
- **Shebang and mode.** `#!/bin/bash`, keep file executable.
- **Portability.** Targets Alpine (busybox + OpenRC), systemd distros, and old
  distros (CentOS 7.6). Avoid bash 5-only syntax, GNU-only flags, and
  systemd-only paths. Detect the environment (`resolve_os_family`,
  `resolve_arch_*`) instead of hardcoding.
- **Low memory / low output.** Prefer `curl -fsSL` streaming; never download
  then re-parse huge payloads. Keep stdout minimal — one clean progress line at
  a time. Detailed diagnostics go to the log file (see below).

## Style (match the existing code)

- Constants: `readonly UPPER_SNAKE_CASE="..."` grouped at the top of the file.
- State vars: `lower_snake_case` declared near the top, defaults set before use.
- Functions: `snake_case()` with a blank line between functions, one concern per
  function (see `error`, `task_start`, `resolve_os_family`, `parse_args`,
  `initialize_variables`, `install_xray`).
- Output discipline:
  - `error()/warn()/info()/success()/task_start()/task_done()` for stdout.
  - `log_verbose()/log_info()` append to `$LOG_FILE` (`nokey.log`).
  - Do NOT `echo` raw diagnostics to stdout — route through the helpers.
- Args: `parse_args()` reads `--flag`/`--key=value` into state vars; unknown
  flags show help and exit non-zero.
- Quoting: always `"$var"`; use `[[ ... ]]` for tests; `local` inside functions.
- `set -euo pipefail` discipline inside functions where it is safe; the top of
  the script stays tolerant so sourcing never kills the parent shell.

## Verification (always run before declaring done)

```bash
for script in nokey.sh nokey-common.sh realm.sh xray-socks.sh xray-warp.sh bbr.sh acme-cert.sh hysteria2.sh; do bash -n "$script"; done
shellcheck -x nokey.sh nokey-common.sh realm.sh xray-socks.sh xray-warp.sh bbr.sh acme-cert.sh hysteria2.sh tests/test_nokey.sh tests/test_features.sh tests/test_logging.sh tests/test_default_route.sh tests/integration_default_route.sh
bash tests/test_nokey.sh
bash tests/test_features.sh
bash tests/test_logging.sh
bash tests/test_default_route.sh
```

All tests must pass. Tests mock globals (e.g. `IPv4`, `ID`, `ID_LIKE`) and stub
network functions — never run the real installer in CI.

## Scope guardrails

- Do NOT modify `nokey.sh` behavior for the host you are running on — changes
  must be generic across all supported distros.
- Do NOT touch `.github/workflows/` (binary release pipeline) unless asked.
- Feature specs: `specs/2026-10-25-output-logs-default-route/` covers output, logging, and default egress behavior.
- Version bumps: `readonly SCRIPT_VERSION="YYYY.MM"` follows the existing scheme.

## Model routing (opencode)

All models below are Zen free tier ($0). Routing matches capability to task so
the strong reasoning model is reserved for quality-critical work and the fast
flash model absorbs high-volume/trivial work (rate-limit budgeting).

| Role | Model | Why |
| --- | --- | --- |
| `build` / `plan` / `bash-dev` | `opencode/big-pickle` | Best free — 200K ctx, reasoning, frontier-class coding (community ID: GLM-4.6) |
| `small_model`, `explore`, `general` | `opencode/deepseek-v4-flash-free` | Fast flash tier for reads/search/titles/summaries |

Other free options for manual fallback via `/models`: `nemotron-3-ultra-free`
(128K, strong reasoning), `north-mini-code-free` (code-focused), `mimo-v2.5-free`,
`ling-3.0-flash-free`, `laguna-s-2.1-free`.

Free tiers are limited-time; if `big-pickle` rotates out, change ONE line in
`opencode.json` (`"model"`, `agent.build.model`, `agent.plan.model`, and the
frontmatter of `.opencode/agent/bash-dev.md`) to the best remaining free model.
