# Always-on Shadowsocks sharing

See also `specs/2026-11-05-shadowsocks-aes256/` for the additional AES-256-GCM inbound.

Fresh Reality installs always include authenticated Shadowsocks 2022 TCP/UDP on a random unused port, using Xray's default wildcard listener (same as Reality). No local IPv6 inspection is required. Keep the existing inbound tag for compatibility. Existing keepconfig behavior is unchanged.

Output URL and Clash entries for each detected public IPv4/IPv6, independently of preferred netstack. Bracket IPv6 in URLs only. Print `SS 连接不可过GFW！只能做为中转落地使用` in red once before SS results; saved connection files remain plain text. Never publish wildcard/ULA addresses as endpoints. Public egress discovery does not guarantee inbound NAT mapping.

Research: Xray inbound documentation confirms omitted listen defaults to wildcard and supports both families: https://xtls.github.io/config/inbound.html . Local Xray binary is unavailable; actual runtime config validation remains part of installer staging.

Verification: unit checks for unconditional preparation/key/port, module YAML checks for three inbounds with no local IPv6, IPv4-only/IPv6-only/dual-family sharing and warning color/plain file. Run all repository required syntax, shellcheck and test suites. Real external reachability is not claimed by offline tests.

Node names now follow `specs/2026-11-05-node-names/SPEC.md`.
