# AI and YouTube routing presets

Scope confirmed: Xray only; this repository has no sing-box template.
Add two separate domain routing rules to the fresh Xray YAML template in
`build_xray_config`: `geosite:category-ai-!cn` and `geosite:youtube`.
Both select `outboundTag: direct`, the existing default Freedom outbound that
follows the configured family preference. Each rule includes adjacent commented
alternatives `# outboundTag: force_ipv4` and `# outboundTag: force_ipv6` so the
operator can replace the active line manually. Keep those outbound definitions
available. Do not add duplicate active outboundTag keys.

Place presets in the custom-rule section before the existing block rules.
Keep existing block rules and all unrelated configuration unchanged. Existing
installed configs and focused patch flows are not migrated. Fresh YAML retains
the comments; legacy JSON serialization omits comments as before. Existing
JSON-based patch operations may also drop YAML comments; no new comment
preservation mechanism is introduced.

Research: inspected the actual YAML staging and default-route builder.
The [Xray routing contract](https://xtls.github.io/en/config/routing.html)
supports geosite domain lists and outboundTag references. Validate the generated
template with real yq parsing and check that the preset tags reference the
default outbound, including when IPv6 is preferred. If a real Xray binary and
assets are unavailable, do not claim runtime validation.

Verification: extend the existing generated-config checks for both presets,
resolved outbound tags and default-preference behavior; confirm YAML comments
remain in the staged file. Run repository-required syntax, ShellCheck and all
four offline suites. No external service, data model or UI changes are involved.
