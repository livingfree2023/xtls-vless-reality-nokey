#!/bin/bash
# shellcheck disable=SC2034,SC2154

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${script_dir}/nokey.sh" ]]; then
    # shellcheck source=nokey.sh
    . "${script_dir}/nokey.sh"
else
    nokey_url="${NOKEY_SCRIPT_URL:-https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/nokey.sh}"
    # shellcheck source=/dev/null
    . <(curl -fsSL "$nokey_url")
fi

ss_listen=""
ss_port=""
ss_password=""
ss_dry_run=0

show_shadowsocks_help() {
    display_result "Usage: xray-shadowsocks.sh [--listen=GLOBAL_IPV6] [--port=PORT] [--config=PATH] [--dry-run]"
}

parse_shadowsocks_args() {
    local arg=""
    for arg in "$@"; do
        case "$arg" in
            --listen=*) ss_listen="${arg#*=}" ;;
            --port=*) ss_port="${arg#*=}" ;;
            --config=*) xray_config_path="${arg#*=}" ;;
            --dry-run) ss_dry_run=1 ;;
            --help) show_shadowsocks_help; return 2 ;;
            *) error "Unknown option: $arg"; return 1 ;;
        esac
    done
}

select_shadowsocks_port() {
    local existing=""
    if [[ -n "$ss_port" ]]; then
        if [[ ! "$ss_port" =~ ^[0-9]+$ ]] || (( 10#$ss_port < 1 || 10#$ss_port > 65535 )); then
            error "Invalid port: $ss_port"
            return 1
        fi
        existing="$(jq -r --argjson port "$ss_port" --arg tag "$SHADOWSOCKS_TAG" '.inbounds[]? | select(.port == $port and .tag != $tag) | .tag // "occupied"' "$patch_jq_source")"
        if [[ -n "$existing" ]]; then
            error "Port is already used by another Xray inbound: $ss_port"
            return 1
        fi
    else
        select_random_unused_port "$patch_jq_source" || return 1
        ss_port="$random_unused_port"
    fi
}

build_shadowsocks_config() {
    local inbound=""
    inbound="$(jq -n --arg tag "$SHADOWSOCKS_TAG" --arg listen "$ss_listen" --argjson port "$ss_port" --arg method "$SHADOWSOCKS_METHOD" --arg password "$ss_password" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"shadowsocks",settings:{network:"tcp,udp",method:$method,password:$password}}')" || return 1
    patch_tmp_out="$(mktemp "${xray_config_path}.stage.XXXXXX")" || return 1
    jq --arg tag "$SHADOWSOCKS_TAG" --argjson inbound "$inbound" \
        '.inbounds = ((.inbounds // [] | map(select(.tag != $tag))) + [$inbound])' \
        "$patch_jq_source" > "$patch_tmp_out" || { rm -f "$patch_tmp_out"; return 1; }
}

output_shadowsocks_share() {
    local userinfo="" share_url=""
    userinfo="$(printf '%s:%s' "$SHADOWSOCKS_METHOD" "$ss_password" | base64 | tr -d '\n')"
    share_url="ss://${userinfo}@[${ss_listen}]:${ss_port}#nokey-shadowsocks-ipv6"
    display_result "$share_url"
    printf '%s\n' "$share_url" >> "$URL_FILE"
    info "Connection details / 连接信息: $URL_FILE"
    print_service_commands "$runtime_xray_service" "$runtime_xray_service_alpine"
}

shadowsocks_main() {
    local status=0
    parse_shadowsocks_args "$@" || { status=$?; [[ "$status" -eq 2 ]] && return 0; return "$status"; }
    if [[ "$xray_config_path" == "$NOKEY_CONFIG_FILE" && ! -f "$xray_config_path" && -f "${NOKEY_CONFIG_DIR}/nokey.json" ]]; then
        xray_config_path="${NOKEY_CONFIG_DIR}/nokey.json"
    fi
    select_shadowsocks_ipv6 || return 1
    if [[ "$ss_dry_run" -eq 1 ]]; then
        info "Xray Shadowsocks dry-run: ${SHADOWSOCKS_METHOD} on [${ss_listen}]:${ss_port:-random}"
        return 0
    fi
    check_root || return 1
    umask 077
    init_output_files preserve-shares || return 1
    install_dependencies jq || return 1
    resolve_jq_config_source || return 1
    select_shadowsocks_port || return 1
    generate_shadowsocks_password || return 1
    build_shadowsocks_config || return 1
    if ! commit_xray_config "$patch_tmp_out"; then
        [[ -n "$patch_cleanup" ]] && rm -f "$patch_cleanup"
        return 1
    fi
    [[ -n "$patch_cleanup" ]] && rm -f "$patch_cleanup"
    output_shadowsocks_share
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
    shadowsocks_main "$@"
fi
