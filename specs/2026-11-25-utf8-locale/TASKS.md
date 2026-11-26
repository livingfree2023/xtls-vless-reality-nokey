# Tasks

[x] Inspect name output, dependency dispatch and primary locale references.
[x] Probe actual ASCII/UTF-8 behavior; define unit/module/integration checks.
[x] Implement locale preparation/persistence and base jq dependency.
[x] Add isolated regression coverage and update architecture/testing docs.
[x] Run required checks, review changes and remove temporary artifacts.
[x] Write ignored local technical notes.

## Handover 备忘

Implemented verified UTF-8 selection, distro-specific support installation,
single-locale generation, persistent defaults/login profile and current-process
overrides. New Debian's standard locale.conf compatibility link is preserved.
Fresh installation now checks/installs jq; pinned and checksum-verified yq
preparation remains unchanged. Source/dry-run/remove/Realm-only skip locale
changes. The new suite is invoked by test_nokey.sh.

Syntax, full ShellCheck and all four required offline suites passed; after the
Debian link fix, full ShellCheck and the affected NoKey suite passed again.
Real macOS probes verified ASCII/UTF-8 differences and the complete isolated
selection/persistence/profile/flag path. No live Linux package installation or
VPS change was performed; platform commands are covered by isolated tests.
No temporary probe scripts or credentials were added. Technical notes are in
ignored blog/. No pending implementation tasks. User authorized commit and
push on 2026-11-25; deliver this change on the current main branch.
