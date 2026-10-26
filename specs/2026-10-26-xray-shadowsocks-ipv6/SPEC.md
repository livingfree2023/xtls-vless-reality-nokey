# Xray IPv6 Shadowsocks 2022 inbound

## Scope

Fresh Reality installs, whether run without flags or through menu option 1, automatically add a Shadowsocks 2022 inbound when the host has a local global IPv6 address. Menu option 9 and `xray-shadowsocks.sh` add the same inbound to an existing Xray service. Use `2022-blake3-aes-128-gcm`, a random 16-byte base64 key, and a single local global IPv6 listen address. Do not install a second proxy core.

## Flow and safeguards

For a fresh install, discover a local global IPv6 address and add the Shadowsocks inbound to the generated Reality config. If none is present, generate Reality alone. For an existing config, read Xray JSON, JSONC, or YAML; verify the requested IPv6 address is assigned locally. Add or replace the tagged inbound while preserving all other configuration. Validate through `xray run -test`, back up, atomically apply, restart, and roll back on failure. Output the share URL only after the service is active.

## Verification

Unit: IPv6 selection, port validation, key length, generated inbound, no-IPv6 skip. Module: default and menu 1 generation, menu 9 dispatch, and preservation of other inbounds. Integration: an opt-in real IPv6 host test for TCP and UDP bound address and a client connection.
