# Additional AES-256-GCM Shadowsocks

Fresh installs generate Reality, existing SS2022, and an additional aes-256-gcm SS TCP/UDP wildcard inbound. Each SS has its own random password and port; exclude Reality, SOCKS and the other SS port. Preserve keepconfig semantics. Naming follows `specs/2026-11-05-node-names/`: .SS2022 and .SS.

Reuse per-family output formatting for public IPv4/IPv6 URLs and Clash; new names use .SS. Keep the red relay warning once above both SS variants. No new UI interaction.

Research: https://xtls.github.io/config/inbounds/shadowsocks.html confirms method aes-256-gcm and string password. Generate a 32-byte random hex password using existing portable random_hex.

Unit: distinct ports and independent valid passwords; decode URL credentials. Module: YAML has all three inbounds, correct ciphers/TCP+UDP, wildcard binding; both ciphers output for single/dual stack. Integration: retain real staged Xray validation/restart/rollback; live VPS test unavailable locally. Run all required repository checks.
