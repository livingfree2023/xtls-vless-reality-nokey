# Xray YAML trial tasks

- [x] Check Xray YAML support and inspect all config readers/writers.
- [x] Create `codex/xray-yaml-trial` branch.
- [x] Render fresh Xray config as YAML and configure service paths.
- [x] Add YAML conversion for jq-based patch paths and preserve legacy JSON behavior.
- [x] Run shell syntax, ShellCheck and offline suites.
- [x] Validate generated YAML with Xray 26.10.21 in an isolated temporary directory.
- [x] Review standalone WARP/SOCKS format paths and update documentation.

## Handover 备忘

The branch contains the YAML trial. All offline suites, syntax checks and ShellCheck pass with Mike Farah `yq` v4.54.1. Xray 26.10.21 accepts generated YAML with and without an initial SOCKS inbound. A real Linux/OpenRC service smoke test remains before deployment. YAML comments are lost after a jq-based patch because that path converts through JSON.
