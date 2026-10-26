#!/bin/bash
# shellcheck disable=SC2034,SC2154

readonly SERVICE_NAME="nokey.service"
readonly SERVICE_NAME_ALPINE="nokey"

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

if [[ -n "${XRAY_CONFIG:-}" ]]; then
    xray_config_path="$XRAY_CONFIG"
elif [[ -f "/usr/local/etc/nokey/nokey.yaml" ]]; then
    xray_config_path="/usr/local/etc/nokey/nokey.yaml"
elif [[ -f "/usr/local/etc/nokey/nokey.json" ]]; then
    xray_config_path="/usr/local/etc/nokey/nokey.json"
elif [[ -f "/usr/local/etc/xray/config.json" ]]; then
    xray_config_path="/usr/local/etc/xray/config.json"
else
    xray_config_path="/usr/local/etc/nokey/nokey.yaml"
fi
netstack=""
IPv4=""
IPv6=""
ip=""
port=""
socks_port=""
socks_username=""
socks_password=""
socks_inbound_json=""
random_unused_port=""
patch_jq_source=""
patch_cleanup=""
patch_tmp_out=""
remove_mode=0
add_limiter_mode=0
change_sni_mode=0
addsocks_mode=1
manager=""

if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
fi

resolve_jq_config_source() {
    local config_path="$xray_config_path"
    patch_jq_source=""
    patch_cleanup=""
    if ! command -v jq >/dev/null 2>&1; then
        error "配置补丁模式需要jq，请先安装jq / Config patch modes require jq. Please install jq first: apt install -y jq"
        return 1
    fi
    if [[ ! -f "$config_path" ]]; then
        error "缺少配置文件: $config_path，补丁模式需要现有配置文件 / Missing config: $config_path. Patch modes require an existing config file."
        return 1
    fi
    case "$config_path" in
        *.yaml|*.yml)
            patch_cleanup="$(mktemp /tmp/nokey-config-json.XXXXXX)" || return 1
            xray_config_to_json "$config_path" "$patch_cleanup" || return 1
            patch_jq_source="$patch_cleanup"
            return 0
            ;;
    esac
    if jq empty "$config_path" >/dev/null 2>&1; then
        patch_jq_source="$config_path"
        return 0
    fi
    patch_cleanup="$(mktemp /tmp/nokey-config-json.XXXXXX)" || {
        error "无法创建临时文件用于JSONC解析 / Failed to create temporary file for JSONC parsing."
        return 1
    }
    # Config may include // comments; strip them so jq can parse it.
    sed -E 's@[[:space:]]+//.*$@@' "$config_path" > "$patch_cleanup"
    if ! jq empty "$patch_cleanup" >/dev/null 2>&1; then
        rm -f "$patch_cleanup"
        patch_cleanup=""
        error "配置文件格式无效 / Invalid config format in $config_path."
        return 1
    fi
    patch_jq_source="$patch_cleanup"
}

# Same randomization as build_xray_config: ~1 Mbps sustained / 2 Mbps burst,
# Xray docs mandate randomization for one-click installers to avoid a
# fixed-rate fingerprint.
add_limiter_to_existing_config() {
    local fallback_bytes_per_sec=""
    local fallback_burst_bytes_per_sec=""
    local limiter_up=""
    local limiter_down=""

    fallback_bytes_per_sec=$((125000 * (85 + RANDOM % 31) / 100))
    fallback_burst_bytes_per_sec=$((250000 * (85 + RANDOM % 31) / 100))
    limiter_up="{\"afterBytes\": 0, \"bytesPerSec\": ${fallback_bytes_per_sec}, \"burstBytesPerSec\": ${fallback_burst_bytes_per_sec}}"
    limiter_down="{\"afterBytes\": 0, \"bytesPerSec\": ${fallback_bytes_per_sec}, \"burstBytesPerSec\": ${fallback_burst_bytes_per_sec}}"

    if ! jq --argjson up "$limiter_up" --argjson down "$limiter_down" \
            '.inbounds[0].streamSettings.realitySettings.limitFallbackUpload = $up | .inbounds[0].streamSettings.realitySettings.limitFallbackDownload = $down' \
            "$patch_jq_source" > "$patch_tmp_out" 2>>"$LOG_FILE"; then
        error "jq添加回落限速失败，请查看$LOG_FILE / jq failed to add fallback rate limit. Check $LOG_FILE."
        return 1
    fi
}

# Pick a fresh SNI via the standard probe flow, keeping the existing dest port.
change_sni_in_existing_config() {
    local old_dest=""
    local dest_port=""
    local new_dest=""

    # Reset so pick_default_domain probes instead of early-returning on the old value.
    domain=""
    pick_default_domain

    old_dest="$(jq -r '.inbounds[0].streamSettings.realitySettings.dest // empty' "$patch_jq_source")"
    if [[ "$old_dest" =~ :([0-9]+)$ ]]; then
        dest_port="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$dest_port" ]]; then
        dest_port=443
    fi
    new_dest="${domain}:${dest_port}"

    if ! jq --arg server "$domain" --arg dest "$new_dest" \
            '.inbounds[0].streamSettings.realitySettings.dest = $dest | .inbounds[0].streamSettings.realitySettings.serverNames = [$server]' \
            "$patch_jq_source" > "$patch_tmp_out" 2>>"$LOG_FILE"; then
        error "jq更换SNI失败，请查看$LOG_FILE / jq failed to change SNI. Check $LOG_FILE."
        return 1
    fi
}

random_hex() {
    local byte_count="$1"
    od -An -N "$byte_count" -tx1 /dev/urandom | tr -d '[:space:]'
}

is_tcp_port_unused() {
    local check_port="$1"

    if command -v ss >/dev/null 2>&1; then
        ! ss -ltn 2>/dev/null | awk -v port=":${check_port}" '$4 ~ port "$" { found=1 } END { exit !found }'
    elif command -v netstat >/dev/null 2>&1; then
        ! netstat -ltn 2>/dev/null | awk -v port=":${check_port}" '$4 ~ port "$" { found=1 } END { exit !found }'
    else
        ! (echo > /dev/tcp/127.0.0.1/"$check_port") >/dev/null 2>&1
    fi
}

select_random_unused_port() {
    local config_source="${1:-}"
    local excluded_port="${2:-}"
    local candidate=""
    local attempt=0

    random_unused_port=""
    while [[ "$attempt" -lt 1000 ]]; do
        candidate=$((10000 + (RANDOM * 32768 + RANDOM) % 50001))
        attempt=$((attempt + 1))
        [[ -n "$excluded_port" && "$candidate" == "$excluded_port" ]] && continue
        if [[ -n "$config_source" ]] && jq -e --argjson port "$candidate" '.inbounds[]? | select(.port == $port)' "$config_source" >/dev/null 2>&1; then
            continue
        fi
        if is_tcp_port_unused "$candidate"; then
            random_unused_port="$candidate"
            return 0
        fi
    done
    return 1
}

prepare_socks_inbound() {
    local config_source="${1:-}"
    local socks_listen="0.0.0.0"

    if [[ "${netstack:-4}" == "6" ]]; then
        socks_listen="::"
    fi

    socks_username="nokey$(random_hex 4)"
    socks_password="$(random_hex 12)"
    if [[ -z "$socks_username" || -z "$socks_password" ]]; then
        error "生成SOCKS凭据失败 / Failed to generate SOCKS credentials."
        return 1
    fi

    # Avoid both existing config ports and currently listening sockets.
    if ! select_random_unused_port "$config_source" "${port:-}"; then
        error "没有找到可用的SOCKS端口 / Could not find an unused SOCKS port."
        return 1
    fi
    socks_port="$random_unused_port"

    # Xray password-auth entries use the users field.
    socks_inbound_json=$(cat <<-EOF
          {
            "tag": "nokey-socks-${socks_port}",
            "listen": "${socks_listen}",
            "port": ${socks_port},
            "protocol": "socks",
            "settings": {
              "auth": "password",
              "users": [
                {
                  "user": "${socks_username}",
                  "pass": "${socks_password}"
                }
              ],
              "udp": true
            },
            "sniffing": {
              "enabled": true,
              "destOverride": ["http", "tls", "quic"]
            }
          }
EOF
    )
}

add_socks_to_existing_config() {
    if ! prepare_socks_inbound "$patch_jq_source"; then
        return 1
    fi
    if ! jq --argjson inbound "$socks_inbound_json" '.inbounds += [$inbound]' \
            "$patch_jq_source" > "$patch_tmp_out" 2>>"$LOG_FILE"; then
        error "jq添加SOCKS入站失败，请查看$LOG_FILE / jq failed to add the SOCKS inbound. Check $LOG_FILE."
        return 1
    fi
}

output_socks_proxy() {
    local proxy_host="$ip"
    local proxy_url=""
    local curl_command=""

    if [[ "$proxy_host" == *:* && "$proxy_host" != \[*\] ]]; then
        proxy_host="[$proxy_host]"
    fi
    proxy_url="socks5h://${socks_username}:${socks_password}@${proxy_host}:${socks_port}"
    curl_command="curl --proxy '${proxy_url}' https://ipinfo.io"

    info "SOCKS5代理 / SOCKS5 Proxy:"
    info "${magenta}${proxy_url}${none}"
    info "SOCKS5测试命令 / SOCKS5 test command:"
    info "${cyan}${curl_command}${none}"
    echo "$proxy_url" >> "$URL_FILE"
    echo "$curl_command" >> "$URL_FILE"
}

patch_existing_xray_config() {
    if [[ "$addsocks_mode" -eq 1 ]]; then
        initialize_ip_from_netstack
    fi

    task_start "修补现有配置 / Patch existing config"

    if ! resolve_jq_config_source; then
        task_fail
        exit 1
    fi

    if [[ "$addsocks_mode" -ne 1 ]] && ! jq -e '.inbounds[0].streamSettings.realitySettings' "$patch_jq_source" >/dev/null 2>&1; then
        task_fail
        error "配置中没有REALITY设置，无法修补 / No REALITY settings found in config; cannot patch."
        rm -f "$patch_cleanup"
        exit 1
    fi

    patch_tmp_out="$(mktemp /tmp/nokey-config-patch.XXXXXX)" || {
        task_fail
        error "创建临时文件失败 / Failed to create temporary file."
        exit 1
    }

    if [[ "$add_limiter_mode" -eq 1 ]]; then
        add_limiter_to_existing_config || { task_fail; rm -f "$patch_tmp_out" "$patch_cleanup"; exit 1; }
    elif [[ "$change_sni_mode" -eq 1 ]]; then
        change_sni_in_existing_config || { task_fail; rm -f "$patch_tmp_out" "$patch_cleanup"; exit 1; }
    elif [[ "$addsocks_mode" -eq 1 ]]; then
        add_socks_to_existing_config || { task_fail; rm -f "$patch_tmp_out" "$patch_cleanup"; exit 1; }
    fi

    local config_stage="$patch_tmp_out"
    case "$xray_config_path" in
        *.yaml|*.yml)
            config_stage="$(mktemp "${xray_config_path}.stage.XXXXXX")" || return 1
            xray_json_to_config "$patch_tmp_out" "$config_stage" "$xray_config_path" || return 1
            rm -f "$patch_tmp_out"
            ;;
    esac
    if ! mv "$config_stage" "$xray_config_path"; then
        task_fail
        error "写入配置文件失败: $xray_config_path / Failed to write config to $xray_config_path."
        rm -f "$patch_cleanup"
        exit 1
    fi
    chmod 644 "$xray_config_path"
    [[ -n "$patch_cleanup" ]] && rm -f "$patch_cleanup"
    task_done

    restart_xray_service

    if [[ "$addsocks_mode" -eq 1 ]]; then
        output_socks_proxy
        return 0
    fi

    # Regenerate links from the patched config so SNI/limiter changes are reflected.
    initialize_ip_from_netstack
    load_runtime_vars_from_existing_config
    output_results
}



restart_xray_service() {
    task_start "Starting Xray service"
    if [[ "${ID:-}" == "alpine" || "${ID_LIKE:-}" == "alpine" ]]; then
        rc-service "$SERVICE_NAME_ALPINE" restart >> "$LOG_FILE" 2>&1
    else
        systemctl restart "$SERVICE_NAME" >> "$LOG_FILE" 2>&1
    fi
    task_done
}

apply_socks_change() {
    if ! resolve_jq_config_source; then
        return 1
    fi
    patch_tmp_out="$(mktemp /tmp/nokey-socks-patch.XXXXXX)" || return 1
    if [[ "$remove_mode" -eq 1 ]]; then
        jq 'del(.inbounds[]? | select((.tag // "") | startswith("nokey-socks-")))'             "$patch_jq_source" > "$patch_tmp_out" || return 1
    else
        initialize_ip_from_netstack
        add_socks_to_existing_config || return 1
    fi
    jq empty "$patch_tmp_out" >/dev/null 2>&1 || return 1
    local config_stage="$patch_tmp_out"
    case "$xray_config_path" in
        *.yaml|*.yml)
            config_stage="$(mktemp "${xray_config_path}.stage.XXXXXX")" || return 1
            xray_json_to_config "$patch_tmp_out" "$config_stage" "$xray_config_path" || return 1
            rm -f "$patch_tmp_out"
            ;;
    esac
    mv "$config_stage" "$xray_config_path" || return 1
    [[ -n "$patch_cleanup" ]] && rm -f "$patch_cleanup"
    restart_xray_service
    [[ "$remove_mode" -eq 1 ]] || output_socks_proxy
}

parse_args() {
    local arg=""
    for arg in "$@"; do
        case "$arg" in
            --config=*) xray_config_path="${arg#*=}" ;;
            --netstack=4) netstack=4 ;;
            --netstack=6) netstack=6 ;;
            --remove) remove_mode=1 ;;
            --help)
                echo "Usage: xray-socks.sh [--config=PATH] [--netstack=4|6] [--remove]"
                return 0
                ;;
            *) error "Unknown option: $arg"; return 1 ;;
        esac
    done
}

main() {
    parse_args "$@" || exit 1
    if [[ "${1:-}" == "--help" ]]; then
        exit 0
    fi
    check_root
    init_output_files
    install_dependencies jq
    if [[ ! -f "$xray_config_path" ]]; then
        error "Missing Xray config: $xray_config_path"
        exit 1
    fi
    apply_socks_change
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
    main "$@"
fi
