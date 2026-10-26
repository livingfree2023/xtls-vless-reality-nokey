# Verification

Run from the repository root. The offline suites source the installer and isolate configuration operations using temporary fixtures. They never invoke the actual installation flow. Fixture credentials are deliberately synthetic and never used by production code.

```bash
for script in nokey.sh nokey-common.sh realm.sh xray-socks.sh xray-warp.sh bbr.sh acme-cert.sh hysteria2.sh; do bash -n "$script"; done
shellcheck -x nokey.sh nokey-common.sh realm.sh xray-socks.sh xray-warp.sh bbr.sh acme-cert.sh hysteria2.sh tests/test_nokey.sh tests/test_features.sh tests/test_logging.sh tests/test_default_route.sh tests/integration_default_route.sh
bash tests/test_nokey.sh
bash tests/test_features.sh
bash tests/test_logging.sh
bash tests/test_default_route.sh
```

## Coverage

- Unit: argument/family mappings, preferred DNS order, existing configuration preservation and legacy Freedom resolution normalization.
- Module: secure/redacted logs, legacy history migration, nested progress output, command failure and signal cleanup, removed flag handling, validation rejection and failed-restart rollback.
- YAML trial: with Mike Farah `yq` v4 installed, the NoKey suite verifies a fresh YAML template and a YAML patch round trip. It skips those two cases if `yq` is absent.
- Terminal: local Python 3 PTY probes verify nested colors, cancellation and unavailable choices; these probes explicitly skip when Python is absent.
- Integration: real Xray parses full generated REALITY templates with disposable keys, then serves a localhost-only SOCKS proxy that makes real HTTPS requests. Both preferences are tested with dual-stack, A-only and AAAA-only targets. Controlled unreachable addresses test actual TCP failover. Output reports only address family, never the actual public address.

## Opt-in network integration

```bash
bash tests/integration_default_route.sh
```

Requires Bash, jq, curl, ss, Xray 26.10.21+ in PATH, and geoip.dat/geosite.dat in `XRAY_LOCATION_ASSET` (default `/usr/local/share/xray`). Missing network families are explicitly skipped, so a single-stack host cannot establish full dual-stack coverage. The script uses temporary configs/keys and loopback listeners, and removes them on exit. It does not replace installed binaries, write production config or restart existing services. A separately staged binary can be selected through PATH.

`run_logged` isolates command execution in a subshell to preserve caller traps and clean temporary captures on signals. Do not wrap helpers whose variable changes must propagate to the caller.
