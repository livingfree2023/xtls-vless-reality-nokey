# Mihomo REALITY fingerprint compatibility

## Scope

New `nokey.sh` installations emit VLESS share links and Mihomo proxy entries with `chrome` as the default client fingerprint. Keep the existing `support-x25519mlkem768: true` setting in Mihomo entries. Do not change server credentials, transport, or running services.

## Reason

A verified user connection succeeds with `client-fingerprint: chrome`; the previous `random` value can select a ClientHello profile that the current Xray REALITY server rejects.

## Validation

- Unit/module: source the installer and verify `output_results` emits `fp=chrome` and `client-fingerprint: chrome`.
- Integration: the user has confirmed a successful Mihomo connection with the Chrome fingerprint; this change only alters generated client text.
- Run the repository's syntax, ShellCheck, and Bash test commands.
