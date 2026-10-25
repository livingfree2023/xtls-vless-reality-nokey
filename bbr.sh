#!/bin/bash
# shellcheck disable=SC2034,SC2154

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${script_dir}/nokey-common.sh" ]]; then
    # shellcheck source=/dev/null
    . "${script_dir}/nokey-common.sh"
else
    common_url="${NOKEY_COMMON_URL:-https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/nokey-common.sh}"
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is required to load nokey-common.sh" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . <(curl -fsSL "$common_url")
fi

dry_run=0
if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
fi

show_help() {
    echo "Usage: bbr.sh [--dry-run]"
}

enable_bbr() {
    task_start "最后，打开BBR / Finishing, Enabling BBR"

    # Some VPS/container environments do not expose writable sysctl knobs.
    if [[ ! -w /etc/sysctl.conf ]]; then
        task_done_with_info "跳过BBR：/etc/sysctl.conf不可写 / Skip BBR: /etc/sysctl.conf is not writable"
        log_verbose "Skip BBR: /etc/sysctl.conf is not writable"
        return
    fi

    if [[ ! -e /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        task_done_with_info "跳过BBR：内核未暴露tcp_congestion_control / Skip BBR: kernel does not expose tcp_congestion_control"
        log_verbose "Skip BBR: /proc/sys/net/ipv4/tcp_congestion_control not found"
        return
    fi

    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf

    # net.core.default_qdisc may not exist in some kernels/containers.
    if [[ -e /proc/sys/net/core/default_qdisc ]]; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    else
        log_verbose "Skip net.core.default_qdisc: kernel key not available"
    fi

    # sysctl -p may exit 0 even when keys fail on read-only /proc/sys
    # (busybox on Alpine/containers), so verify the live kernel state
    # instead of trusting the exit code.
    sysctl -p >> "$LOG_FILE" 2>&1 || true
    local current_cc=""
    current_cc="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)"
    if [[ "$current_cc" == *bbr* ]]; then
        task_done
    else
        warn "BBR未生效：当前拥塞算法为 ${current_cc:-unknown} / BBR not active: current congestion control is ${current_cc:-unknown}"
        log_verbose "BBR not active: /proc/sys/net/ipv4/tcp_congestion_control=${current_cc:-unreadable}"
    fi

}



main() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            --help) show_help; exit 0 ;;
            *) error "Unknown option: $arg"; exit 1 ;;
        esac
    done
    if [[ "$dry_run" -eq 1 ]]; then
        info "BBR dry-run: would configure /etc/sysctl.conf"
        exit 0
    fi
    check_root
    enable_bbr
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
    main "$@"
fi
