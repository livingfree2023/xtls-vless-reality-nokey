#!/bin/bash
# shellcheck disable=SC2034,SC2154

readonly HYSTERIA_BINARY="/usr/local/bin/hysteria"
readonly HYSTERIA_CONFIG_DIR="/etc/hysteria"
readonly HYSTERIA_CONFIG_FILE="/etc/hysteria/config.yaml"
readonly HYSTERIA_CERT_FILE="/etc/hysteria/fullchain.pem"
readonly HYSTERIA_KEY_FILE="/etc/hysteria/private.key"
readonly HYSTERIA_SERVICE_NAME="hysteria2.service"
readonly HYSTERIA_SERVICE_NAME_ALPINE="hysteria2"
readonly HYSTERIA_INSTALLER_URL="https://get.hy2.sh/"

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

domain=""
port=""
password=""
cert_path="${HYSTERIA_CERT_PATH:-}"
key_path="${HYSTERIA_KEY_PATH:-}"
acme_email=""
cf_token="${HYSTERIA_CF_TOKEN:-${CF_Token:-}}"
native_acme=0
masquerade_url="https://www.bing.com"
force_reinstall=0
dry_run=0
remove_mode=0
manager=""

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi

show_help() {
    echo "Usage: hysteria2.sh [--domain=DOMAIN] [--port=PORT] [--password=PASSWORD]"
    echo "       [--cert-path=PATH] [--key-path=PATH] [--email=EMAIL] [--masquerade=URL] [--force] [--remove] [--dry-run]"
    echo "       --cert/--key are accepted as aliases for --cert-path/--key-path."
}

read_tty_value() {
    local prompt="$1"
    local value=""
    if [[ ! -r /dev/tty ]]; then
        return 1
    fi
    read -r -p "$prompt" value < /dev/tty || return 1
    printf '%s' "$value"
}

parse_args() {
    local arg=""
    for arg in "$@"; do
        case "$arg" in
            --domain=*) domain="${arg#*=}" ;;
            --port=*) port="${arg#*=}" ;;
            --password=*) password="${arg#*=}" ;;
            --cert=*|--cert-path=*) cert_path="${arg#*=}" ;;
            --key=*|--key-path=*) key_path="${arg#*=}" ;;
            --email=*) acme_email="${arg#*=}" ;;
            --masquerade=*) masquerade_url="${arg#*=}" ;;
            --force) force_reinstall=1 ;;
            --remove) remove_mode=1 ;;
            --dry-run) dry_run=1 ;;
            --help) show_help; exit 0 ;;
            *) error "Unknown option: $arg"; show_help; return 1 ;;
        esac
    done
}

validate_args() {
    if [[ "$remove_mode" -eq 1 ]]; then
        return 0
    fi
    if [[ -z "$domain" ]]; then
        if [[ -t 0 || -r /dev/tty ]]; then
            domain="$(read_tty_value "Hysteria domain: ")" || return 1
        else
            error "--domain is required in non-interactive mode"
            return 1
        fi
    fi
    if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
        error "Invalid domain: $domain"
        return 1
    fi
    if [[ -n "$acme_email" && ! "$acme_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        error "Invalid email: $acme_email"
        return 1
    fi
    if [[ -n "$port" ]]; then
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            error "Invalid port: $port"
            return 1
        fi
    else
        local attempt=0
        local candidate=""
        while [[ "$attempt" -lt 1000 ]]; do
            candidate=$((10000 + RANDOM % 50001))
            if is_tcp_port_unused "$candidate"; then
                port="$candidate"
                break
            fi
            attempt=$((attempt + 1))
        done
        if [[ -z "$port" ]]; then
            error "Could not find an unused Hysteria2 port"
            return 1
        fi
    fi
    if [[ -z "$password" ]]; then
        password="$(random_hex 16)"
    fi
    if [[ ! "$password" =~ ^[A-Za-z0-9._-]+$ ]]; then
        error "Password may contain only letters, numbers, dot, underscore, and hyphen"
        return 1
    fi
}

read_tty_secret() {
    local prompt="$1"
    local value=""
    if [[ ! -r /dev/tty ]]; then
        return 1
    fi
    read -r -s -p "$prompt" value < /dev/tty || return 1
    echo >&2
    printf '%s' "$value"
}

select_tls_mode() {
    if [[ -n "$cert_path" || -n "$key_path" ]]; then
        find_certificate_pair || prompt_for_certificates || return 1
        return 0
    fi
    if [[ -z "$cf_token" && -r /dev/tty ]]; then
        cf_token="$(read_tty_secret "Cloudflare API token for Hysteria built-in ACME (optional): ")" || true
    fi
    if [[ -n "$cf_token" ]]; then
        native_acme=1
        return 0
    fi
    find_certificate_pair || prompt_for_certificates || return 1
}

find_certificate_pair() {
    local acme_home="${ACME_HOME:-${HOME}/.acme.sh}"
    local base=""
    local candidates=(
        "$HYSTERIA_CERT_FILE|$HYSTERIA_KEY_FILE"
        "${acme_home}/${domain}_ecc/fullchain.cer|${acme_home}/${domain}_ecc/${domain}.key"
        "${acme_home}/${domain}/fullchain.cer|${acme_home}/${domain}/${domain}.key"
        "/root/.acme.sh/${domain}_ecc/fullchain.cer|/root/.acme.sh/${domain}_ecc/${domain}.key"
        "/root/.acme.sh/${domain}/fullchain.cer|/root/.acme.sh/${domain}/${domain}.key"
    )
    if [[ -n "$cert_path" || -n "$key_path" ]]; then
        [[ -f "$cert_path" && -f "$key_path" ]] || return 1
        return 0
    fi
    for base in "${candidates[@]}"; do
        cert_path="${base%%|*}"
        key_path="${base#*|}"
        if [[ -f "$cert_path" && -f "$key_path" ]]; then
            return 0
        fi
    done
    cert_path=""
    key_path=""
    return 1
}

prompt_for_certificates() {
    if [[ -n "$cert_path" || -n "$key_path" ]]; then
        if [[ -f "$cert_path" && -f "$key_path" ]]; then
            return 0
        fi
        error "Certificate or private key file does not exist"
        return 1
    fi
    if [[ ! -r /dev/tty ]]; then
        error "No ACME certificate found. Use --cert=PATH --key=PATH"
        return 1
    fi
    cert_path="$(read_tty_value "Certificate path (fullchain): ")" || return 1
    key_path="$(read_tty_value "Private key path: ")" || return 1
    [[ -f "$cert_path" && -f "$key_path" ]] || {
        error "Certificate or private key file does not exist"
        return 1
    }
}

yaml_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/}"
    value="${value//$'\r'/}"
    printf '"%s"' "$value"
}

install_binary() {
    if [[ -x "$HYSTERIA_BINARY" && "$force_reinstall" -eq 0 ]]; then
        return 0
    fi
    task_start "下载Hysteria2 / Download Hysteria2"
    if ! (
        set -o pipefail
        curl -fsSL "$HYSTERIA_INSTALLER_URL" |
            FORCE_NO_SYSTEMD=2 HYSTERIA_USER=root HYSTERIA_HOME_DIR=/root bash -s --
    ) >> "$LOG_FILE" 2>&1; then
        task_fail
        error "下载Hysteria2失败 / Failed to install Hysteria2 with the official installer"
        return 1
    fi
    if [[ ! -x "$HYSTERIA_BINARY" ]]; then
        task_fail
        error "Hysteria2 binary was not installed by the official installer"
        return 1
    fi
    task_done
}

write_config() {
    mkdir -p "$HYSTERIA_CONFIG_DIR"
    if [[ "$native_acme" -eq 1 ]]; then
        cat > "$HYSTERIA_CONFIG_FILE" <<EOF
listen: :${port}
acme:
  domains:
    - $(yaml_quote "$domain")
  type: dns
  dir: /etc/hysteria/acme
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: $(yaml_quote "$cf_token")
$(if [[ -n "$acme_email" ]]; then printf '  email: %s\n' "$(yaml_quote "$acme_email")"; fi)
auth:
  type: password
  password: $(yaml_quote "$password")
masquerade:
  type: proxy
  proxy:
    url: $(yaml_quote "$masquerade_url")
    rewriteHost: true
EOF
    else
        cat > "$HYSTERIA_CONFIG_FILE" <<EOF
listen: :${port}
tls:
  cert: $(yaml_quote "$cert_path")
  key: $(yaml_quote "$key_path")
auth:
  type: password
  password: $(yaml_quote "$password")
masquerade:
  type: proxy
  proxy:
    url: $(yaml_quote "$masquerade_url")
    rewriteHost: true
EOF
    fi
    chmod 600 "$HYSTERIA_CONFIG_FILE"
}

install_openrc_service() {
    local destination="/etc/init.d/${HYSTERIA_SERVICE_NAME_ALPINE}"
    cat > "$destination" <<'EOF'
#!/sbin/openrc-run
name="hysteria2"
description="Hysteria 2 Server"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/${RC_SVCNAME}.log"
error_log="/var/log/${RC_SVCNAME}.err"
depend() { need net; }
EOF
    chmod 755 "$destination"
    configure_openrc_crash_restart "$destination" || return 1
    chmod 755 "$destination"
    rc-update add "$HYSTERIA_SERVICE_NAME_ALPINE" default >> "$LOG_FILE" 2>&1 || true
    rc-service "$HYSTERIA_SERVICE_NAME_ALPINE" restart >> "$LOG_FILE" 2>&1
}

install_systemd_service() {
    local destination="/etc/systemd/system/${HYSTERIA_SERVICE_NAME}"
    cat > "$destination" <<'EOF'
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    configure_systemd_crash_restart "$destination" || return 1
    {
        systemctl daemon-reload
        systemctl enable "$HYSTERIA_SERVICE_NAME"
        systemctl restart "$HYSTERIA_SERVICE_NAME"
    } >> "$LOG_FILE" 2>&1
}

service_is_active() {
    if [[ "${ID:-}" == "alpine" || "${ID_LIKE:-}" == "alpine" ]]; then
        rc-service "$HYSTERIA_SERVICE_NAME_ALPINE" status >/dev/null 2>&1
    else
        systemctl is-active --quiet "$HYSTERIA_SERVICE_NAME"
    fi
}

write_share_urls() {
    local share_url="hysteria2://${password}@${domain}:${port}/?sni=${domain}"
    local proxy_name="${domain}-hysteria2"
    {
        echo "$share_url"
        echo ""
        echo "proxies:"
        echo "  - name: ${proxy_name}"
        echo "    type: hysteria2"
        echo "    server: ${domain}"
        echo "    port: ${port}"
        echo "    password: ${password}"
        echo "    sni: ${domain}"
        echo "    alpn:"
        echo "      - h3"
        echo "    skip-cert-verify: false"
    } > "$URL_FILE"
    chmod 600 "$URL_FILE"
    success "Hysteria2 is running"
    printf 'Share URL: %s\n' "$share_url"
    info "Mihomo/Clash YAML saved to: $URL_FILE"
    cat "$URL_FILE"
    print_service_commands "$HYSTERIA_SERVICE_NAME" "$HYSTERIA_SERVICE_NAME_ALPINE"
}

uninstall_hysteria() {
    task_start "卸载Hysteria2 / Uninstall Hysteria2"
    if [[ "${ID:-}" == "alpine" || "${ID_LIKE:-}" == "alpine" ]]; then
        rc-service "$HYSTERIA_SERVICE_NAME_ALPINE" stop >> "$LOG_FILE" 2>&1 || true
        rc-update del "$HYSTERIA_SERVICE_NAME_ALPINE" default >> "$LOG_FILE" 2>&1 || true
        rm -f "/etc/init.d/${HYSTERIA_SERVICE_NAME_ALPINE}"
    else
        systemctl disable --now "$HYSTERIA_SERVICE_NAME" >> "$LOG_FILE" 2>&1 || true
        rm -f "/etc/systemd/system/${HYSTERIA_SERVICE_NAME}"
        systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
    fi
    rm -f "$HYSTERIA_BINARY"
    rm -rf "$HYSTERIA_CONFIG_DIR"
    task_done
}

main() {
    parse_args "$@" || exit 1
    validate_args || exit 1
    if [[ "$dry_run" -eq 1 ]]; then
        info "Hysteria2 dry-run: no system changes will be made"
        info "Binary: $HYSTERIA_BINARY"
        info "Config: $HYSTERIA_CONFIG_FILE"
        info "Port: $port"
        if [[ -n "$cert_path" || -n "$key_path" ]]; then
            info "TLS: provided certificate and private key"
            info "Certificate: $cert_path"
            info "Private key: $key_path"
        elif [[ -n "$cf_token" ]]; then
            info "TLS: Hysteria built-in ACME DNS-01 (Cloudflare)"
        else
            info "TLS: detect acme.sh certificate or prompt for certificate paths"
        fi
        exit 0
    fi
    check_root
    umask 077
    init_output_files
    if [[ "$remove_mode" -eq 1 ]]; then
        uninstall_hysteria
        exit 0
    fi
    select_tls_mode || exit 1
    install_dependencies curl
    install_binary || exit 1
    write_config
    if [[ "${ID:-}" == "alpine" || "${ID_LIKE:-}" == "alpine" ]]; then
        install_openrc_service || {
            error "Failed to start Hysteria2 OpenRC service"
            exit 1
        }
    else
        install_systemd_service || {
            error "Failed to start Hysteria2 systemd service"
            exit 1
        }
    fi
    if ! service_is_active; then
        error "Hysteria2 service is not active; check $LOG_FILE"
        exit 1
    fi
    write_share_urls
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
    main "$@"
fi
