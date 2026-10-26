# Xray IPv6 Shadowsocks 2022 inbound

## Scope

Menu option 9 and `xray-shadowsocks.sh` add a Shadowsocks 2022 inbound to the existing Xray service. Use `2022-blake3-aes-128-gcm`, a random 16-byte base64 key, and a single local global IPv6 listen address. Keep the default Xray installation behavior unchanged. Do not install a second proxy core.

## Flow and safeguards

Read the existing Xray JSON, JSONC, or YAML configuration; verify the requested IPv6 address is assigned locally. Add or replace the tagged inbound while preserving all other configuration. Validate through `xray run -test`, back up, atomically apply, restart, and roll back on failure. Output the share URL only after the service is active.

## Verification

Unit: IPv6 selection, port validation, key length, generated inbound. Module: menu dispatch and preservation of other inbounds. Integration: an opt-in real IPv6 host test for TCP and UDP bound address and a client connection.
