# Preserve share output across interrupted runs

A normal install or credential-changing patch must leave the existing `nokey.url` intact until the new service is active and all share entries have been generated. The installer writes new entries into a mode 0600 same-directory temporary file and atomically renames it over `nokey.url` only after output succeeds. Failed or interrupted runs remove the temporary file at exit. Configuration-only changes and removal preserve the existing share file.

Verification: source-level test of old-content preservation before commit and replacement after commit; required Bash syntax, ShellCheck, and four offline suites. The real installer is not invoked by tests.
