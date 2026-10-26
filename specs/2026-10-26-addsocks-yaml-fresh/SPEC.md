# Fresh YAML installation for --addsocks

## Contract

`nokey --addsocks` patches an existing `/usr/local/etc/nokey/nokey.yaml`. When that file is absent, it runs the normal Xray installation and generates Reality plus a randomly credentialed SOCKS5 inbound in one YAML config. An existing `/usr/local/etc/nokey/nokey.json` is archived outside the NoKey config directory as `/usr/local/etc/nokey-legacy.json.*` and is never parsed or migrated. The archive location is displayed to the user. Other patch modes and `--keepconfig` require YAML.

## Flow and failure boundaries

The main function chooses the config path before service checks. After root/output setup, it archives an old NoKey JSON file only when no YAML exists and the run will install Xray. It rejects a non-regular or symlinked old config. If archiving fails, installation stops. Xray configuration continues through existing staged validation and restart logic. A failed install leaves the legacy archive available for manual recovery.

## Verification

- Unit: syntax and ShellCheck; inspect main branching for YAML-only selection.
- Module: run the offline suites, including fresh YAML/SOCKS rendering and existing YAML patch tests.
- Integration: Xray validation is performed by `commit_xray_config` on real installs; no system service is touched in CI.
