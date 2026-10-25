# NoKey output, logging, Sing-box removal, and default egress

Status: prototype approved; preference mode implemented and verified for local delivery. Prior Chrome fingerprint change stays intact.

## Verified findings

- `nokey.sh` overrides shared output/logging helpers. `task_start` writes a partial line; nested info creates merged lines and a detached OK. An isolated helper probe reproduced it.
- `init_output_files` creates 0644 files with the current ambient umask. Both helpers truncate logs. Logs can contain ANSI, complete config/private keys, share URLs, and SOCKS passwords.
- Logs lack consistent level/time/run/phase, durations, command failures, and bounded service startup evidence.
- Sing-box is embedded in the main installer, a separate entrypoint, menu/help/docs/tests, service assets, and the scheduled binary release workflow.
- The template places `force_ipv4` first and sets global DNS `UseIPv4`. Moving `force_ipv6` first alone cannot resolve AAAA through that global filter.
- Xray 26.10.21 on the authorized VPS accepted isolated temporary configs with `UseIP` and Happy Eyeballs for both IPv4 and IPv6 preference. Test used `xray run -test`; no production config or service was changed. Initial probe validated parsing only; final integration also verified actual public IPv4/IPv6 egress and failover on an authorized Alpine Podman host.

## Proposed behavior

### Output and logs

Use shared printf-based helpers in `nokey-common.sh`, complete status lines, terminal-only color, consistent bilingual prompts, and service commands appropriate to the detected service manager. Keep help/dry-run read-only. Preserve stdout of machine-readable helper functions.

Use 0600 output files, bounded previous-run retention, one run identifier, timestamps, level, phase, elapsed time and exit codes. Keep normal stdout concise and place command diagnostics in the log. Add `NOKEY_LOG_LEVEL=DEBUG|INFO|WARN|ERROR`; INFO default. Never use blanket shell tracing or log raw argument lists/environment. Record a sanitized configuration summary instead of config contents. Connection details remain available in stdout and the restricted share file, excluded from diagnostic logs. Xray runtime logs remain in journald/OpenRC diagnostics; installer logs identify how to retrieve them.

Validate a staged configuration with the installed Xray before replacement, back up with restrictive permissions, replace atomically on the same filesystem, restart and verify service readiness. On failure collect bounded, sanitized diagnostics and restore/restart the prior configuration. Record rollback status. Reject symlink destinations for generated sensitive outputs.

### Remove Sing-box

Remove installer branches, flags, menu/help entries, standalone script, service assets, exclusive helpers, tests and documentation. Old flags exit nonzero with a clear removed-feature message before initializing output files. Remove its scheduled download/checksum/release dependency. Existing VPS services are not uninstalled by a future normal NoKey invocation.

### --default-route

Add an interactive /dev/tty menu and an entry in --menu. In an existing NoKey config, apply a focused backed-up patch preserving credentials, inbounds, routing rules and unrelated outbounds. For fresh installation, select the family before rendering the template. Keep --netstack as inbound/share-address selection; egress preference is independent. Noninteractive calls without a value fail with guidance; a --default-route=4|6 form can support automation. Detect both local routes and bounded successful external IPv4/IPv6 probes; unavailable families are disabled. Cancel leaves existing configuration untouched.

Approved decision: prefer a family with TCP fallback.

Approved preferred mode: place the selected default Freedom outbound first; use `sockopt.domainStrategy=UseIP` and TCP `happyEyeballs` (`tryDelayMs=250`, `interleave=1`, `prioritizeIPv6` selected by menu). Keep explicit `force_ipv4`/`force_ipv6` tagged outbounds for routing rules. Do not change tag semantics. Global DNS `UseIP` on dual-stack preserves A and AAAA; use public DNS endpoints reachable from the selected network, followed by the other reachable family and optional system fallback. DNS transport family and record query type are distinct. DNS preference must not disable the other family's explicit rules. UDP does not gain TCP Happy Eyeballs failover and literal-IP targets retain their supplied address family.

Outbounds are not an automatic fallback chain. Single-stack hosts use matching DNS query restrictions and resolver endpoints.

## Verification contract

- Unit: route selection, family mappings, stdout helpers, log filtering, secret exclusion, file modes, unknown/removed argument behavior and cancellation.
- Module: generated/patch JSONC configs for IPv4-only, IPv6-only and dual stack; preserve existing rule tags; stage/backup/rollback on validation and restart failure; TTY/non-TTY behavior.
- Integration: real Xray 26.10.21 validation and isolated localhost proxy tests against real A-only, AAAA-only and dual-stack targets, including unavailable preferred family. No production service changes without an explicit target action.
- Required syntax/ShellCheck and both repository Bash test suites after changes; compare pre-existing warnings separately.

## Official references

- https://xtls.github.io/config/routing.html — unmatched traffic uses the first outbound.
- https://xtls.github.io/config/transports/sockopt.html — Force/Use, address-family selection, TCP Happy Eyeballs and DNS intersection.
- https://xtls.github.io/config/dns.html — global queryStrategy and resolver transports.

## Prototype

`docs/prototype/default-route.html` is a static terminal mockup, not an executable installer or real runtime output.

## Delivered verification

- All four offline suites passed on macOS and Alpine Podman. Local PTY tests covered cancellation and terminal colors; Alpine skipped only optional Python PTY probes.
- ShellCheck and Bash syntax passed; workflow YAML and embedded command blocks parsed successfully.
- Xray 26.10.21 accepted complete generated REALITY templates for both preferences. Staged JSON is validated via `-format json -c stdin:` because the new loader enforces filename extensions even with an explicit format for regular files.
- Eight real HTTPS cases passed: both preferences with dual-stack/A-only/AAAA-only destinations plus unreachable preferred IPv4 and IPv6 fallback.
- Testing used a temporary core/localhost SOCKS listener. The authorized Podman retained installed Xray 26.3.27 and no temporary validation directories or core processes remained.
- Existing share files are preserved during default-route-only patches; legacy log history is sanitized before appending.
