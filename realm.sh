#!/bin/bash
# shellcheck disable=SC2034,SC2154

readonly GITHUB_RELEASE_BASE_URL="https://github.com/livingfree2023/nokey/releases/latest/download"
readonly GITHUB_REALM_RC_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/realm.rc"
readonly GITHUB_REALM_SERVICE_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/realm.service"
readonly REALM_SERVICE_NAME="realm.service"
readonly REALM_SERVICE_NAME_ALPINE="realm"
readonly REALM_CONFIG_DIR="/usr/local/etc/realm"

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

force_reinstall=0
dry_run=0
remove_mode=0
netstack=""
realm_remote=""
realm_listen=""
IPv4=""
IPv6=""
ip=""
manager=""

if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
fi

show_help() {
    echo "Usage: realm.sh [--remote=HOST:PORT] [--listen=ADDRESS] [--force] [--remove] [--dry-run]"
}

parse_realm_args() {
    local arg=""
    for arg in "$@"; do
        case "$arg" in
            --remote=*) realm_remote="${arg#*=}" ;;
            --listen=*) realm_listen="${arg#*=}" ;;
            --netstack=4) netstack=4 ;;
            --netstack=6) netstack=6 ;;
            --force) force_reinstall=1 ;;
            --remove) remove_mode=1 ;;
            --dry-run) dry_run=1 ;;
            --help) show_help; return 0 ;;
            *) error "Unknown option: $arg"; show_help; return 1 ;;
        esac
    done
    if [[ "$remove_mode" -eq 0 && -z "$realm_remote" ]]; then
        error "--remote is required"
        return 1
    fi
    if [[ -n "$realm_remote" && ! "$realm_remote" =~ ^\[?[^\]]*\]?:[0-9]+$ ]]; then
        error "Invalid --remote format: $realm_remote"
        return 1
    fi
}

dry_run_realm() {
    info "Realm dry-run: no system changes will be made"
    info "Binary: ${GITHUB_RELEASE_BASE_URL}/$(resolve_realm_arch_name)"
    info "Config: ${REALM_CONFIG_DIR}/config.json"
    info "Remote: ${realm_remote}"
    info "Listen: ${realm_listen:-auto}"
}

uninstall_realm() {
    task_start "卸载 Realm / Uninstall Realm"
    {
        if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            rc-service "$REALM_SERVICE_NAME_ALPINE" stop 2>/dev/null || true
            rc-update del "$REALM_SERVICE_NAME_ALPINE" 2>/dev/null || true
            rm -f "/etc/init.d/$REALM_SERVICE_NAME_ALPINE"
        else
            systemctl stop "$REALM_SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$REALM_SERVICE_NAME" 2>/dev/null || true
            rm -f "/etc/systemd/system/$REALM_SERVICE_NAME" 2>/dev/null || true
            systemctl daemon-reload 2>/dev/null || true
        fi
        rm -f /usr/local/bin/realm
        rm -rf "$REALM_CONFIG_DIR"
    } >> "$LOG_FILE" 2>&1
    task_done
}

install_realm() {
    if [[ $force_reinstall == 1 ]]; then
        uninstall_realm
    fi

    task_start "安装 Realm / Install Realm"

    # 如果realm已在运行，先停掉，否则二进制文件被锁无法覆写
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        rc-service "$REALM_SERVICE_NAME_ALPINE" stop 2>/dev/null || true
    else
        systemctl stop "$REALM_SERVICE_NAME" 2>/dev/null || true
    fi

    local arch_binary_name=""
    local arch_name=""
    arch_binary_name="$(resolve_realm_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }
    arch_name="$(resolve_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }

    log_info "架构 / Architecture: ${arch_name}"

    mkdir -p /usr/local/bin "$REALM_CONFIG_DIR" || { task_fail; error "创建Realm目录失败 / Failed to create realm directories"; exit 1; }

    log_verbose "Downloading: ${GITHUB_RELEASE_BASE_URL}/${arch_binary_name} -> /usr/local/bin/realm"
    curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/${arch_binary_name}" -o /usr/local/bin/realm >> "$LOG_FILE" 2>&1 || { task_fail; error "下载${arch_binary_name}失败 / Failed to download ${arch_binary_name}"; exit 1; }
    chmod 755 /usr/local/bin/realm

    local realm_rc_tmp
    local realm_service_tmp
    realm_rc_tmp="$(mktemp /tmp/nokey.realm.rc.XXXXXX)" || { task_fail; error "创建realm.rc临时文件失败 / Failed to create temporary file for realm.rc"; exit 1; }
    realm_service_tmp="$(mktemp /tmp/nokey.realm.service.XXXXXX)" || { task_fail; error "创建realm.service临时文件失败 / Failed to create temporary file for realm.service"; exit 1; }

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        log_info "安装OpenRC服务 / Installing OpenRC service: /etc/init.d/${REALM_SERVICE_NAME_ALPINE}"
        log_verbose "Downloading service file: ${GITHUB_REALM_RC_URL} -> ${realm_rc_tmp}"
        curl -fSL "${GITHUB_REALM_RC_URL}" -o "${realm_rc_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "下载realm.rc失败 / Failed to download realm.rc"; exit 1; }
        configure_openrc_crash_restart "${realm_rc_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "配置realm崩溃自动重启失败 / Failed to configure realm crash restart"; exit 1; }
        install -m 755 "${realm_rc_tmp}" /etc/init.d/"$REALM_SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "安装/etc/init.d/$REALM_SERVICE_NAME_ALPINE失败 / Failed to install /etc/init.d/$REALM_SERVICE_NAME_ALPINE"; exit 1; }
        rm -f "${realm_rc_tmp}" >> "$LOG_FILE" 2>&1
        log_verbose "Installed OpenRC service file from realm.rc"
        rc-update add "$REALM_SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用OpenRC服务$REALM_SERVICE_NAME_ALPINE失败 / Failed to enable OpenRC service $REALM_SERVICE_NAME_ALPINE"; exit 1; }
    else
        log_info "安装systemd服务 / Installing systemd service: /etc/systemd/system/${REALM_SERVICE_NAME}"
        log_verbose "Downloading service file: ${GITHUB_REALM_SERVICE_URL} -> ${realm_service_tmp}"
        curl -fSL "${GITHUB_REALM_SERVICE_URL}" -o "${realm_service_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "下载realm.service失败 / Failed to download realm.service"; exit 1; }
        configure_systemd_crash_restart "${realm_service_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "配置realm崩溃自动重启失败 / Failed to configure realm crash restart"; exit 1; }
        cp "${realm_service_tmp}" /etc/systemd/system/"$REALM_SERVICE_NAME" || { task_fail; error "写入/etc/systemd/system/$REALM_SERVICE_NAME失败 / Failed to write /etc/systemd/system/$REALM_SERVICE_NAME"; exit 1; }
        rm -f "${realm_service_tmp}" >> "$LOG_FILE" 2>&1
        log_verbose "Installed systemd service file from realm.service"
        systemctl daemon-reload >> "$LOG_FILE" 2>&1
        systemctl enable "$REALM_SERVICE_NAME" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用systemd服务$REALM_SERVICE_NAME失败 / Failed to enable systemd service $REALM_SERVICE_NAME"; exit 1; }
    fi

    rm -f "${realm_rc_tmp}" "${realm_service_tmp}" >> "$LOG_FILE" 2>&1
    task_done
}

configure_realm() {
    task_start "配置 Realm / Configure Realm"

    if [[ -z "$realm_remote" ]]; then
        task_fail
        error "缺少 --remote 参数，请指定远程地址 / --remote is required. Please specify a remote address (e.g., --remote 1.2.3.4:443)."
        exit 1
    fi

    local remote_port=""
    if [[ "$realm_remote" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
        remote_port="${BASH_REMATCH[2]}"
    elif [[ "$realm_remote" =~ ^([^:]+):([0-9]+)$ ]]; then
        remote_port="${BASH_REMATCH[2]}"
    else
        task_fail
        error "无效的 --remote 格式，应为 <host>:<port> (例如 1.2.3.4:443) / Invalid --remote format. Expected <host>:<port> (e.g., 1.2.3.4:443)."
        exit 1
    fi

    if [[ -z "$remote_port" || "$remote_port" -lt 1 || "$remote_port" -gt 65535 ]]; then
        task_fail
        error "无效的端口号: $remote_port / Invalid port number: $remote_port"
        exit 1
    fi

    if [[ -z "$realm_listen" ]]; then
        if [[ $netstack == "6" ]]; then
            realm_listen="[::]:${remote_port}"
            log_info "自动监听IPv6任意地址 / Auto-listen on IPv6 any: ${cyan}${realm_listen}${none}"
        else
            realm_listen="0.0.0.0:${remote_port}"
            log_info "自动监听IPv4任意地址 / Auto-listen on IPv4 any: ${cyan}${realm_listen}${none}"
        fi
    fi

    local realm_config="${REALM_CONFIG_DIR}/config.json"
    if ! cat > "$realm_config" <<-REALMCFG
{
  "dns": {
    "mode": "ipv4_and_ipv6"
  },
  "endpoints": [
    {
      "listen": "${realm_listen}",
      "remote": "${realm_remote}"
    }
  ]
}
REALMCFG
    then
        task_fail
        error "写入Realm配置文件失败: $realm_config / Failed to write realm config to $realm_config."
        exit 1
    fi

    task_done_with_info "listen=${realm_listen}, remote=${realm_remote}"

log_info "--- ${realm_config} ---"
    cat "$realm_config" >> "$LOG_FILE"
}

restart_realm_service() {
    task_start "启动 Realm 服务 / Starting Realm Service"
    local max_retries=3
    local retry=0
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        while [ $retry -lt $max_retries ]; do
            if rc-service "$REALM_SERVICE_NAME_ALPINE" stop >> "$LOG_FILE" 2>&1; then
                sleep 1
            fi
            if rc-service "$REALM_SERVICE_NAME_ALPINE" start >> "$LOG_FILE" 2>&1; then
                sleep 1
                if rc-service "$REALM_SERVICE_NAME_ALPINE" status >> "$LOG_FILE" 2>&1; then
                    task_done
                    return 0
                fi
            fi
            retry=$((retry + 1))
            if [ $retry -lt $max_retries ]; then
                warn "重启Realm服务失败，正在重试 ($retry/$max_retries) ... / Failed to restart realm service, retrying ($retry/$max_retries) ..."
                sleep 2
                rm -f /run/openrc/starting/"$REALM_SERVICE_NAME_ALPINE" /run/openrc/exclusive/"$REALM_SERVICE_NAME_ALPINE" 2>/dev/null
            fi
        done
        task_fail
        error "重启Realm服务失败，请查看$LOG_FILE获取详情 / Failed to restart realm service. Check $LOG_FILE for details."
        exit 1
    else
        local retry=0
        while [ $retry -lt $max_retries ]; do
            if systemctl restart "$REALM_SERVICE_NAME" >> "$LOG_FILE" 2>&1; then
                task_done
                return 0
            fi
            retry=$((retry + 1))
            if [ $retry -lt $max_retries ]; then
                warn "重启Realm服务失败，正在重试 ($retry/$max_retries) ... / Failed to restart realm service, retrying ($retry/$max_retries) ..."
                sleep 2
            fi
        done
        task_fail
        error "重启Realm服务失败，请查看$LOG_FILE获取详情 / Failed to restart realm service. Check $LOG_FILE for details."
        exit 1
    fi
}


# Function to display help message; exits with $1 (default 0) so error paths can fail non-zero


main() {
    parse_realm_args "$@" || exit 1
    if [[ "$dry_run" -eq 1 ]]; then
        dry_run_realm
        exit 0
    fi
    check_root
    install_dependencies
    if [[ "$remove_mode" -eq 1 ]]; then
        uninstall_realm
        exit 0
    fi
    detect_network_interfaces
    initialize_ip_from_netstack
    install_realm
    configure_realm
    restart_realm_service
    print_service_commands "$REALM_SERVICE_NAME" "$REALM_SERVICE_NAME_ALPINE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
    main "$@"
fi
