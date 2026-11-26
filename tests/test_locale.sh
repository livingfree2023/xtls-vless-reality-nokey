#!/bin/bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail

locale_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$locale_test_dir/../nokey.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
trap 'printf "FAIL: locale check at line %s\n" "$LINENO" >&2' ERR
events="$fixture_dir/events"
task_start() { :; }
task_done() { :; }
task_fail() { :; }
log_info() { :; }
error() { :; }
info() { :; }

# Intercept locale probes without exporting unsupported locales on the test host.
locale_supported=""
locale_list=""
locale_warning=""
locale() { :; }
env() {
    local requested=""
    if [[ "${1:-}" == LC_ALL=* ]]; then
        requested="${1#*=}"
        shift
        [[ "${1:-}" != LANG=* ]] || shift
        [[ "${1:-}" == locale ]] || return 1
        shift
        case "${1:-}" in
            -a) printf '%s\n' "$locale_list" ;;
            charmap)
                if [[ "$requested" == "$locale_warning" ]]; then
                    printf 'cannot set locale\n' >&2
                    printf 'UTF-8\n'
                elif [[ "|$locale_supported|" == *"|$requested|"* ]]; then
                    printf 'UTF-8\n'
                else
                    printf 'ANSI_X3.4-1968\n'
                fi
                ;;
            *) return 1 ;;
        esac
    else
        command env "$@"
    fi
}

(
    LANG=zh_CN.UTF-8 LC_ALL=C
    locale_supported='zh_CN.UTF-8|C.UTF-8'
    [[ "$(find_utf8_locale)" == zh_CN.UTF-8 ]]
    LANG=C
    [[ "$(find_utf8_locale)" == C.UTF-8 ]]
    locale_supported=fr_FR.utf8
    locale_list=$'C\nfr_FR.utf8'
    [[ "$(find_utf8_locale)" == fr_FR.utf8 ]]
    locale_supported=""
    locale_list=""
    locale_warning=C.UTF-8
    if find_utf8_locale; then exit 1; fi
)

(
    command() {
        [[ "${1:-}" != -v || "${2:-}" != locale ]] || return 1
        builtin command "$@"
    }
    if find_utf8_locale; then exit 1; fi
)

(
    run_logged() { printf '%s\n' "$*" >> "$events"; }
    for manager in apt apk yum dnf pacman zypper xbps-install; do
        VERSION_ID=9
        install_locale_support
    done
    manager=yum VERSION_ID=7.6
    install_locale_support
    grep -Fxq 'locale_install env DEBIAN_FRONTEND=noninteractive apt install -y locales' "$events"
    grep -Fxq 'locale_install apk add --no-cache musl-locales' "$events"
    grep -Fxq 'locale_install yum install -y glibc-langpack-en' "$events"
    grep -Fxq 'locale_install dnf install -y glibc-langpack-en' "$events"
    grep -Fxq 'locale_install yum install -y glibc-common' "$events"
    grep -Fxq 'locale_install pacman -S --noconfirm glibc' "$events"
    grep -Fxq 'locale_install zypper install -y glibc-locale-base' "$events"
    grep -Fxq 'locale_install xbps-install -Sy glibc-locales' "$events"
    manager=unknown
    if install_locale_support; then exit 1; fi
)

(
    LANG=C LC_ALL=C
    locale_supported=en_US.UTF-8
    install_locale_support() { return 1; }
    persist_utf8_locale() { printf '%s\n' "$1" > "$fixture_dir/selected"; }
    ensure_utf8_locale
    [[ "$LANG" == en_US.UTF-8 && "$LC_ALL" == "$LANG" && "$LC_CTYPE" == "$LANG" ]]
    [[ "$(cat "$fixture_dir/selected")" == "$LANG" ]]
)

(
    LANG=C LC_ALL=C
    install_locale_support() { locale_supported=C.UTF-8; }
    persist_utf8_locale() { [[ "$1" == C.UTF-8 ]]; }
    ensure_utf8_locale
    [[ "$LANG" == C.UTF-8 ]]
)

(
    LANG=C LC_ALL=C
    install_locale_support() { :; }
    localedef() { :; }
    run_logged() {
        [[ "$*" == 'locale_generate localedef --no-archive -i en_US -f UTF-8 en_US.UTF-8' ]] || return 1
        locale_supported=en_US.UTF-8
    }
    persist_utf8_locale() { [[ "$1" == en_US.UTF-8 ]]; }
    ensure_utf8_locale
)

for failure in install generate verify persist; do
    (
        LANG=C LC_ALL=C
        install_locale_support() { [[ "$failure" != install ]]; }
        localedef() { :; }
        run_logged() { [[ "$failure" != generate ]]; }
        persist_utf8_locale() { return 1; }
        [[ "$failure" != persist ]] || locale_supported=en_US.UTF-8
        if ensure_utf8_locale; then exit 1; fi
        [[ "$LANG" == C && "$LC_ALL" == C ]]
    )
done

(
    ID=debian ID_LIKE=""
    root="$fixture_dir/debian"
    mkdir -p "$root/default"
    printf '# keep comment\nLANG=C\nLC_CTYPE=C\nexport LC_ALL=C\nLC_TIME=de_DE.UTF-8\n' > "$root/default/locale"
    persist_utf8_locale en_US.UTF-8 "$root"
    cp "$root/default/locale" "$fixture_dir/first-defaults"
    cp "$root/profile.d/nokey-locale.sh" "$fixture_dir/first-profile"
    persist_utf8_locale en_US.UTF-8 "$root"
    cmp -s "$fixture_dir/first-defaults" "$root/default/locale"
    cmp -s "$fixture_dir/first-profile" "$root/profile.d/nokey-locale.sh"
    grep -Fxq '# keep comment' "$root/default/locale"
    grep -Fxq 'LC_TIME=de_DE.UTF-8' "$root/default/locale"
    grep -Fxq 'LANG=en_US.UTF-8' "$root/default/locale"
    if grep -q LC_ALL "$root/default/locale"; then exit 1; fi
    LANG=C LC_ALL=C
    # shellcheck source=/dev/null
    source "$root/profile.d/nokey-locale.sh"
    [[ "$LANG" == en_US.UTF-8 && "$LC_CTYPE" == "$LANG" && -z "${LC_ALL:-}" ]]
    root="$fixture_dir/debian-new"
    mkdir -p "$root/default"
    ln -s ../locale.conf "$root/default/locale"
    persist_utf8_locale en_US.UTF-8 "$root"
    [[ -L "$root/default/locale" ]]
    grep -Fxq 'LANG=en_US.UTF-8' "$root/locale.conf"
    rm "$root/default/locale"
    ln -s "$fixture_dir/first-defaults" "$root/default/locale"
    if persist_utf8_locale en_US.UTF-8 "$root"; then exit 1; fi
    for ID in alpine rocky; do
        root="$fixture_dir/$ID"
        persist_utf8_locale C.UTF-8 "$root"
        grep -Fxq 'LANG=C.UTF-8' "$root/locale.conf"
        bash -n "$root/profile.d/nokey-locale.sh"
    done
    ID=alpine
    mkdir -p "$fixture_dir/unsafe"
    ln -s "$fixture_dir/first-defaults" "$fixture_dir/unsafe/locale.conf"
    if persist_utf8_locale C.UTF-8 "$fixture_dir/unsafe"; then exit 1; fi
    if persist_utf8_locale 'bad;command' "$fixture_dir/unsafe-name"; then exit 1; fi
    : > "$fixture_dir/not-directory"
    if persist_utf8_locale C.UTF-8 "$fixture_dir/not-directory" 2>/dev/null; then exit 1; fi
    [[ -z "$(find "$fixture_dir" -name '*.stage.*' -print)" ]]
)

(
    manager=apt
    installed_jq=0
    netstat() { :; }
    command() {
        if [[ "${1:-}" == -v && "${2:-}" == jq ]]; then
            [[ "$installed_jq" -eq 1 ]]; return $?
        fi
        builtin command "$@"
    }
    run_logged() {
        [[ "$*" == 'dependency_install eval apt install -y jq' ]] || return 1
        installed_jq=1
    }
    ensure_utf8_locale() { [[ "$installed_jq" -eq 1 ]]; }
    install_dependencies
    [[ "$installed_jq" -eq 1 ]]
    realm_only=1
    ensure_utf8_locale() { return 1; }
    install_dependencies
    realm_only=0
    if install_dependencies; then exit 1; fi
)

printf 'PASS: UTF-8 locale selection, installation, persistence and dependency checks\n'
