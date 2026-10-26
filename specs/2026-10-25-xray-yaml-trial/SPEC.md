# Xray YAML trial

## Scope

- New NoKey installations write `/usr/local/etc/nokey/nokey.yaml` and point their systemd/OpenRC service at it.
- Xray reads the YAML file directly. There is no generated JSON runtime file.
- Existing `nokey.json` and conventional `/usr/local/etc/xray/config.json` installations remain selectable and keep their existing format.
- `--keepconfig`, route, limiter, SNI, SOCKS and WARP patch paths must accept YAML. The existing jq expressions may operate on a temporary JSON view, then serialize the staged result back to YAML before replacement.
- Validate the final YAML with `xray run -test -format yaml`; retain private backup and rollback behavior.

## Dependency and limits

- YAML read/patch conversion requires Mike Farah `yq` v4. New default installation can render YAML without it, except when adding a SOCKS inbound during initial generation.
- Conversion through JSON drops YAML comments and formatting on patched files. This is a trial limitation.
- The standalone WARP script retains its existing direct service restart behavior; the format conversion does not redesign that workflow.

## Verification

- Unit: YAML template parses to the expected inbounds/outbounds; YAML to JSON and back preserves settings.
- Module: YAML patch is converted, validated as YAML, and committed in YAML form; existing JSON tests continue to pass.
- Integration: disposable Xray binary runs `-test -format yaml` against a generated REALITY configuration with disposable keys and assets. No service or production config is changed.
