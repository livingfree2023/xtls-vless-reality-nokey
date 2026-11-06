# Tasks

[x] Verify real ipinfo country response and existing output flow.
[x] Implement prompt, bounded country lookup and common name formatter.
[x] Update naming regression tests and current docs.
[x] Run all required checks and review diff.

## Handover 备忘

Node names use flag+country.base.VR/SS2022/SS[.V6], following the user's corrected SS suffix requirement. Real HTTPS country probe and real TTY prompt tests passed. Syntax, ShellCheck and all four required suites passed. Network failure falls back to no prefix; terminal absence/Enter uses hostname. Delivered together with the additional AES inbound on main. No live VPS install.
