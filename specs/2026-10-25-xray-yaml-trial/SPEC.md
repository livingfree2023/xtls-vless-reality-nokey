# Xray YAML trial

## Scope

- New NoKey installations write `/usr/local/etc/nokey/nokey.yaml` and point their systemd/OpenRC service at it.
- Xray reads the YAML file directly. There is no generated JSON runtime file.
- Existing `nokey.json` and conventional `/usr/local/etc/xray/config.json` installations remain selectable and keep their existing format.
- A rerun targeting an existing `nokey.json` stages JSON from the YAML template before Xray validation. Pulling or merging the code alone does not migrate a running service or config. `--keepconfig` retains the existing configuration; a normal reinstall keeps the JSON path but regenerates credentials as before.
- `--keepconfig`, route, limiter, SNI, SOCKS and WARP patch paths must accept YAML. The existing jq expressions may operate on a temporary JSON view, then serialize the staged result back to YAML before replacement.
- Validate the final YAML with `xray run -test -format yaml`; retain private backup and rollback behavior.

## Dependency and limits

- YAML read/patch conversion uses Mike Farah `yq` v4.54.1. The installer automatically downloads a pinned, SHA-256 verified binary to `/usr/local/libexec/nokey/yq` when a matching version is unavailable. After verifying the private binary, it adds that directory to the current process PATH and writes an idempotent PATH export to existing `~/.bashrc` and `~/.zshrc` files. It does not create missing rc files or modify a system `yq` binary. The launching shell must source its rc file or start a new session to see the new PATH.
- Conversion through JSON drops YAML comments and formatting on patched files. This is a trial limitation.
- The standalone WARP script retains its existing direct service restart behavior; the format conversion does not redesign that workflow.

## Verification

- Unit: YAML template parses to the expected inbounds/outbounds; YAML to JSON and back preserves settings; a legacy JSON target stages valid JSON without changing the active file.
- Module: YAML patch is converted, validated as YAML, and committed in YAML form; existing JSON tests continue to pass.
- Integration: disposable Xray binary runs `-test -format yaml` against a generated REALITY configuration with disposable keys and assets. No service or production config is changed.
