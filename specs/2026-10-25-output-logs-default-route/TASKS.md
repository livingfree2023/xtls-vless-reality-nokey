# Tasks

- [x] Audit current stdout/log helpers and reproduce formatting/permission defects.
- [x] Map complete Sing-box removal scope including binary publishing.
- [x] Review official Xray routing/Sockopt/DNS documentation.
- [x] Validate proposed preference settings with actual Xray 26.10.21 parser using temporary isolated configs.
- [x] Write specification and terminal prototype.
- [x] Obtain prototype approval: prefer address family with TCP fallback.
- [x] Consolidate output/logging helpers and sanitize diagnostics.
- [x] Remove Sing-box code/assets/docs/tests/publishing dependencies.
- [x] Add egress selection and template/existing-config patch support.
- [x] Add meaningful unit/module tests and run real isolated integration probes.
- [x] Run required checks, review diff, update docs and handover.
- [x] Write a sanitized local-only Obsidian retrospective and ignore blog/.

## 【Handover 备忘】

Implementation complete locally in version 2026.33; nothing committed or pushed. User approved preference-mode prototype. Chrome fingerprint default is retained. Sing-box code, assets, tests, documentation and release dependency were removed; obsolete flags fail explicitly. Logging is centralized, credentials/history redacted, permissions 0600, nested output stable. Default-route menus and =4|6 preserve inbounds, tags, split DNS and share output, validate/backup/atomically apply, and roll back on restart failure. Staged validation must use stdin with explicit JSON (26.10.21 extension restriction).

Verification: all four offline suites pass locally and on authorized Alpine Podman; ShellCheck, shell syntax, workflow YAML/run-block syntax all pass. Actual 26.10.21 full templates + eight public dual-stack HTTPS/failover cases passed in isolation. Installed Podman core remains 26.3.27; temporary directories/processes cleaned. The local-only sanitized retrospective is ignored under blog/. User-facing source archive and patch are in this chat's outputs directory. Publishing remains a separate action requiring user instruction.
