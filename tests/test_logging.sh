#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
audit_dir="$(mktemp -d)"
trap 'rm -rf "$audit_dir"' EXIT
cd "$audit_dir"
GITHUB_CMD="test-command"
# shellcheck source=/dev/null
source "$REPO_ROOT/nokey-common.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

[[ ! -e "$LOG_FILE" && ! -e "$URL_FILE" ]] || fail 'sourcing wrote files'
original_umask="$(umask)"
init_output_files
[[ "$(umask)" == "$original_umask" ]] || fail 'initialization changed the caller umask'
[[ "$(LC_ALL=C ls -l "$LOG_FILE")" == -rw-------* ]] || fail 'log mode is not 0600'
[[ "$(LC_ALL=C ls -l "$URL_FILE")" == -rw-------* ]] || fail 'URL mode is not 0600'
printf 'keep-history\n' >> "$LOG_FILE"
printf 'stale-link\n' > "$URL_FILE"
init_output_files
grep -q keep-history "$LOG_FILE" || fail 'initialization discarded log history'
[[ ! -s "$URL_FILE" ]] || fail 'action initialization did not reset share output'
pass 'secure action output files and preserved log history'
printf 'existing-share\n' > "$URL_FILE"
init_output_files preserve-shares
[[ "$(cat "$URL_FILE")" == existing-share ]] || fail 'non-credential patch discarded existing shares'
pass 'configuration-only changes preserve saved shares' 

cat >> "$LOG_FILE" <<'LEGACY'
old-normal-event retained metadata
"privateKey": "LEGACY_PRIVATE_SENTINEL"
"id": "LEGACY_ID_SENTINEL"
"users": [
  {"user": "LEGACY_USER_SENTINEL", "pass": "LEGACY_PASS_SENTINEL"}
]
vless://LEGACY_URL_SENTINEL@host:443?pbk=LEGACY_QUERY_SENTINEL
Generate Private Key ... LEGACY_GENERATED_PRIVATE_SENTINEL [OK]
Generate Public Key ... LEGACY_GENERATED_PUBLIC_SENTINEL [OK]
UUID → LEGACY_UUID_SENTINEL
LEGACY
printf '%s\n' '"password": "OLD_ROTATED_PASSWORD_SENTINEL"' 'old-rotated-normal-event' > "${LOG_FILE}.1"
init_output_files
! grep -Eq 'LEGACY_.*_SENTINEL' "$LOG_FILE" || fail 'legacy credentials survived initialization'
! grep -q OLD_ROTATED_PASSWORD_SENTINEL "${LOG_FILE}.1" || fail 'retained history contains legacy password'
grep -q 'old-normal-event retained metadata' "$LOG_FILE" || fail 'ordinary legacy diagnostics lost'
grep -q old-rotated-normal-event "${LOG_FILE}.1" || fail 'ordinary previous-run diagnostics lost'
[[ "$(LC_ALL=C ls -l "${LOG_FILE}.1")" == -rw-------* ]] || fail 'retained history mode is not 0600'
pass 'legacy credentials sanitized before append, including retained previous logs'

stdout="$(task_start 'Checking service'; info 'Service running'; task_done)"
[[ "$stdout" == *$'[...] Checking service\nService running\n[OK] Checking service'* ]] || fail 'progress lines are incomplete'
pass 'complete progress lines'

stdout="$(task_start 'Patch configuration'; task_start 'Restart service'; task_done; task_done)"
[[ "$stdout" == *$'[OK] Restart service\n[OK] Patch configuration'* ]] || fail 'nested progress lost its outer label'
[[ "$stdout" != *'[OK] Task'* ]] || fail 'nested progress emitted an anonymous task'
pass 'nested progress restores the enclosing task label'

# A pseudo-TTY verifies the source-time color branch and embedded caller colors.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$REPO_ROOT/nokey-common.sh" "$audit_dir" <<'PYTTY'
import errno
import os
from pathlib import Path
import pty
import subprocess
import sys

tty_dir = Path(sys.argv[2]) / "tty"
tty_dir.mkdir()
master, slave = pty.openpty()
script = 'GITHUB_CMD=test; source "$1"; init_output_files; info "Nested ${cyan}color value${none}"'
process = subprocess.Popen(
    ["bash", "-c", script, "bash", sys.argv[1]],
    stdin=slave, stdout=slave, stderr=slave, cwd=str(tty_dir), close_fds=True,
)
os.close(slave)
output = bytearray()
try:
    while True:
        try:
            chunk = os.read(master, 4096)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        output.extend(chunk)
finally:
    os.close(master)
assert process.wait() == 0, "TTY helper command failed"
assert b"\x1b[96mcolor value\x1b[0m" in output, "nested colors were not ANSI"
assert b"\\e[" not in output and b"\\033[" not in output, "literal color escapes reached TTY"
log = (tty_dir / "nokey.log").read_bytes()
assert b"\x1b" not in log and b"\\e[" not in log and b"\\033[" not in log, "TTY log contains colors"
assert b"Nested color value" in log, "nested-color log lost its text"
PYTTY
  pass 'TTY nested colors render without literal escapes or colored logs'
else
  printf '%s\n' 'SKIP: pseudo-TTY test requires python3'
fi

private_key='KNOWN_PRIVATE_SENTINEL'
uuid='KNOWN_UUID_SENTINEL'
socks_password='KNOWN_SOCKS_SENTINEL'
log_info "keys: $private_key $uuid $socks_password"
printf '%s\n' \
  'PrivateKey: UNKNOWN_PRIVATE_SENTINEL' \
  'Authorization: Bearer UNKNOWN_TOKEN_SENTINEL' \
  '"password":' \
  '"MULTILINE_PASSWORD_SENTINEL"' \
  '}' \
  '"shortIds": [' \
  '"MULTILINE_SID_SENTINEL"' \
  ']' \
  'vless://USERINFO_SENTINEL@server:443?pbk=QUERY_SENTINEL' \
  $'\033[31mplain diagnostic\033[0m' \
  '\e[31mliteral diagnostic\e[0m' | sanitize_log_stream >> "$LOG_FILE"
if grep -Eq 'KNOWN_.*_SENTINEL|UNKNOWN_.*_SENTINEL|MULTILINE_.*_SENTINEL|USERINFO_SENTINEL|QUERY_SENTINEL' "$LOG_FILE"; then
  fail 'diagnostic log leaked sentinel secrets'
fi
[[ "$(LC_ALL=C tr -cd '\033' < "$LOG_FILE" | wc -c)" -eq 0 ]] || fail 'diagnostic log contains ANSI'
! grep -Fq '\e[' "$LOG_FILE" || fail 'diagnostic log contains literal color escapes'
pass 'known and multiline credentials redacted, logs ANSI-free'

stdout="$(display_result "vless://RESULT_SENTINEL@host")"
[[ "$stdout" == 'vless://RESULT_SENTINEL@host' ]] || fail 'result output changed'
! grep -q RESULT_SENTINEL "$LOG_FILE" || fail 'result entered diagnostic log'
pass 'sensitive result output bypasses diagnostic log'

run_status=0
run_logged failing_probe bash -c 'printf "password: COMMAND_SECRET_SENTINEL\nprobe failed\n"; exit 7' || run_status=$?
[[ "$run_status" -eq 7 ]] || fail 'command exit status was lost'
grep -q 'phase=failing_probe.*command_end exit=7 duration_s=' "$LOG_FILE" || fail 'command completion lacks phase/status/duration'
! grep -q COMMAND_SECRET_SENTINEL "$LOG_FILE" || fail 'command diagnostics leaked secret'
grep -q 'probe failed' "$LOG_FILE" || fail 'command diagnostics missing'
pass 'command failure diagnostics preserve status and redact credentials'

mkdir command-captures
signal_status=0
# shellcheck disable=SC2016  # PPID must expand in the child command.
TMPDIR="$audit_dir/command-captures" run_logged interrupted_probe bash -c 'kill -TERM "$PPID"; exit 0' || signal_status=$?
[[ "$signal_status" -eq 143 ]] || fail 'TERM did not preserve signal exit status'
[[ -z "$(ls -A command-captures)" ]] || fail 'interrupted command capture was not removed'
pass 'signal cleanup removes private command captures'

NOKEY_LOG_LEVEL=ERROR
log_info 'FILTERED_INFO_SENTINEL'
log_event ERROR 'visible error'
! grep -q FILTERED_INFO_SENTINEL "$LOG_FILE" || fail 'log threshold ignored'
grep -q 'visible error' "$LOG_FILE" || fail 'error was filtered'
NOKEY_LOG_LEVEL=DEBUG
log_verbose 'visible debug'
grep -q 'visible debug' "$LOG_FILE" || fail 'dynamic debug threshold ignored'
NOKEY_LOG_LEVEL=invalid
if log_info 'invalid level' 2>/dev/null; then fail 'invalid log level accepted'; fi
unset NOKEY_LOG_LEVEL
pass 'dynamic validated logging level'

printf 'do-not-truncate\n' > target
rm -f "$URL_FILE"
ln -s target "$URL_FILE"
if init_output_files 2>/dev/null; then fail 'URL symlink accepted'; fi
grep -q do-not-truncate target || fail 'URL symlink target modified'
rm -f "$URL_FILE"
ln -s target previous-log
mv "$LOG_FILE" legitimate-log
ln -s target "$LOG_FILE"
if init_output_files 2>/dev/null; then fail 'log symlink accepted'; fi
grep -q do-not-truncate target || fail 'log symlink target modified'
rm -f "$LOG_FILE"
mv legitimate-log "$LOG_FILE"
pass 'symlink output paths rejected'

# Rotation keeps one restricted previous log, without discarding new run output.
awk 'BEGIN { for (i = 0; i < 30000; i++) print "ordinary historic diagnostics retained" }' > "$LOG_FILE"
printf '%s\n' '"privateKey": "ROTATING_PRIVATE_SENTINEL"' 'vless://ROTATING_URL_SENTINEL@host' >> "$LOG_FILE"
init_output_files
[[ -f "${LOG_FILE}.1" ]] || fail 'oversized log was not rotated'
! grep -q ROTATING_ "${LOG_FILE}.1" || fail 'rotated log contains legacy credentials'
[[ "$(wc -c < "${LOG_FILE}.1")" -gt 1048576 ]] || fail 'previous log content was lost'
[[ "$(LC_ALL=C ls -l "${LOG_FILE}.1")" == -rw-------* ]] || fail 'previous log mode is not 0600'
grep -q run_start "$LOG_FILE" || fail 'new run boundary missing'
pass 'bounded previous log retention'

printf '%s\n' 'All logging tests passed.'
