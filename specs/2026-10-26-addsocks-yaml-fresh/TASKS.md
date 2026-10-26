# Tasks

- [x] Trace `--addsocks` dispatch and legacy JSON fallbacks.
- [x] Route existing YAML to patch mode and missing YAML to fresh installation in `main`.
- [x] Archive old NoKey JSON before fresh YAML installation and show its location.
- [x] Update README and architecture context.
- [x] Run repository syntax, ShellCheck, and offline suites.

## Handover 备忘

The main flow now ignores legacy JSON for dispatch and archives a lone NoKey JSON before installation. A fresh `--addsocks` run uses the existing configuration generator to include SOCKS5 and Reality in YAML. Syntax, ShellCheck, and all four offline suites passed. No real installer was run on the development host.
