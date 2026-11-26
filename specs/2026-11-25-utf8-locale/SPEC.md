# UTF-8 locale preparation

Before Xray installation or configuration patches, nokey.sh must provide an
installed, verified UTF-8 locale for node-name input/output. Dry runs, help,
uninstall and Realm-only flows do not change locale settings. Sourcing is inert.
Keep an existing usable UTF-8 locale; otherwise try C.UTF-8, C.utf8 and
en_US.UTF-8 aliases, then available UTF-8 locales. Verify using the real
`locale charmap` result including diagnostics, rather than trusting LANG or
locale -a alone. Invalid LC_ALL must not prevent recovery.

Install missing support through the detected package manager: Debian locales,
Alpine musl-locales, RPM glibc-langpack-en (CentOS/RHEL 7 glibc-common). Existing
additional package-manager branches use their native glibc locale packages.
If needed, localedef builds only en_US.UTF-8 without a shared archive. Recheck
after installation/generation and stop with an explicit error on failure.

Set LANG, LC_CTYPE and LC_ALL in the installer process. Persist LANG/LC_CTYPE
in /etc/default/locale on Debian-family systems or /etc/locale.conf elsewhere,
and a managed /etc/profile.d/nokey-locale.sh for future login shells. Remove
conflicting LC_ALL from the defaults and unset it in the managed profile.
New Debian's standard /etc/default/locale link to /etc/locale.conf is preserved,
writing the canonical file even when the link initially has no target. Reject
other symlink destinations. Reuse locale.conf when already present on Debian.
Preserve unrelated settings; use staged replacements, reject unsafe file paths,
and report write failures. No service restart or systemd dependency is needed.
An installer subprocess cannot change the calling shell's environment. Client
terminal font/glyph support is outside this server-side encoding change.

Dependency check: jq is required by fresh configs and node-name encoding, so
include it in the base dependencies. Keep the existing pinned, SHA-256-verified
yq preparation for YAML unchanged.

## Research and verification

Real local probe: `locale charmap` returned US-ASCII for C and UTF-8 for
en_US.UTF-8; Bash counted the same flag as 8 bytes versus 2 code points.
No Linux container runtime is available here; no real VPS installation claimed.

Primary references: [musl locale behavior](https://wiki.musl-libc.org/functional-differences-from-glibc.html),
[Alpine musl-locales package](https://pkgs.alpinelinux.org/package/v3.22/main/x86_64/musl-locales),
[Debian locale generation](https://manpages.debian.org/bookworm/locales/locale-gen.8.en.html).
The [Debian locale.conf migration](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1038798)
establishes the standard compatibility link.

- Unit: selection priority, unsupported locale diagnostics, installed aliases.
- Module: isolated package-manager commands, CentOS 7 fallback, generation,
  failed install/verification/writes, inherited overrides, persistent content,
  idempotence, dependency/main ordering and jq installation.
- Integration: real host locale/flag probe, required offline suites and ShellCheck.
  Live Linux package installation remains unverified in this environment.
