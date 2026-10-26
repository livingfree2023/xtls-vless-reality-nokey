# Xray IPv6 Shadowsocks 2022 inbound

## Scope

Fresh Reality installs, whether run without flags or through menu option 1, automatically add a Shadowsocks 2022 inbound when the host has a local global IPv6 address. Use `2022-blake3-aes-128-gcm`, a random 16-byte base64 key, and a single local global IPv6 listen address. Do not install a second proxy core or expose a separate menu action.

## Flow and safeguards

Discover a local global IPv6 address and add the Shadowsocks inbound to the generated Reality config. If none is present, generate Reality alone. Validate the staged config through `xray run -test`, back up, atomically apply, restart, and roll back on failure. Output the share URL only after the service is active.

## Verification

Unit: IPv6 selection, port validation, key length, generated inbound, no-IPv6 skip. Module: default and menu 1 generation and absence of a separate Shadowsocks menu action. Integration: an opt-in real IPv6 host test for TCP and UDP bound address and a client connection.
