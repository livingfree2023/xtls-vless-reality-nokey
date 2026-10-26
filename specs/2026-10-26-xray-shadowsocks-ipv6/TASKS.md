# Tasks

- [x] Verify Xray's official Shadowsocks 2022 inbound schema and key length.
- [x] Implement the Xray config patch and menu action.
- [x] Run offline verification; live VPS verification requires a host with global IPv6.
- [x] Add automatic Shadowsocks inbound to fresh Reality installs when local global IPv6 exists.
- [x] Verify two-inbound and no-IPv6 generated configs, then run the required shell checks.

## Handover 备忘

Automatic default-install generation and offline checks are complete. A live IPv6 VPS install and client connection remain unverified. Pending local share-output work in `nokey.sh`, `tests/test_nokey.sh`, and `specs/2026-10-25-preserve-share-output/` predates this feature and must be kept separate when committing.
