# Tasks

- [x] Trace early truncation and share generation call paths.
- [x] Stage new share output and commit it after successful output.
- [x] Preserve existing shares for configuration-only and removal paths.
- [x] Add regression coverage and run required offline checks.

## 【Handover 备忘】

Required syntax, ShellCheck, and four offline Bash suites pass. The user verified client connectivity for the current installer. The interrupted-run share-file behavior was verified offline; no live interruption was induced.
