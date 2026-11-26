# Tasks

[x] Inspect Xray template, default outbound, serialization and routing contract.
[x] Confirm scope with user: Xray only.
[x] Add separate AI/YouTube rules and commented outbound alternatives.
[x] Verify staged YAML/parsed routing and run required checks.
[x] Update documentation, review diff and write ignored local notes.

## Handover 备忘

User confirmed no sing-box work. Preserve force_ipv4/force_ipv6 outbound
definitions; only the alternative outboundTag entries inside the two rules are
commented. Active outbound is direct, following existing default preference.

Both IPv4- and IPv6-preferred staged YAML configs parse with real yq; new
domain rules bind to the existing default outbound and retain commented
alternatives. Syntax, full ShellCheck and all four required offline suites
passed. No real Xray binary/assets are available here, so runtime validation
was not performed. Existing installed configs are not migrated; JSON conversion
continues to remove comments. Technical notes are in ignored blog/. User
authorized commit and push after verification on 2026-11-25.
