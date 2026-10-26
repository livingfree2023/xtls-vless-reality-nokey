# Xray YAML trial tasks

- [x] Check Xray YAML support and inspect all config readers/writers.
- [x] Create `codex/xray-yaml-trial` branch.
- [x] Render fresh Xray config as YAML and configure service paths.
- [x] Add YAML conversion for jq-based patch paths and preserve legacy JSON behavior.
- [x] Run shell syntax, ShellCheck and offline suites.
- [x] Validate generated YAML with Xray 26.10.21 in an isolated temporary directory.
- [x] Review standalone WARP/SOCKS format paths and update documentation.
- [x] Auto-install and verify the YAML tool before YAML operations, including fresh installation.
- [x] Expose the verified private yq directory through existing Bash/Zsh rc files, idempotently.
- [x] Stage JSON for an existing `nokey.json` during a normal reinstall and verify the active file remains untouched before commit.

## Handover 备忘

The branch contains the YAML trial. Automatic installation downloads a pinned yq v4.54.1 binary into NoKey's private tool directory, verifies its SHA-256 and version, then atomically publishes it. Existing Bash/Zsh rc files receive an idempotent PATH export; the current parent shell still requires `source` or a new session. Offline tests cover success, checksum rejection, stage cleanup, PATH export behavior, and JSON staging for a legacy NoKey target; a real macOS download to `/tmp` also passed. Xray 26.10.21 accepts generated YAML with and without an initial SOCKS inbound. A real Linux/OpenRC service smoke test remains before deployment. YAML comments are lost after a jq-based patch because that path converts through JSON.
