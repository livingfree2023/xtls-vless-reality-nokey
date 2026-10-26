#!/bin/bash
# shellcheck disable=SC2154

# Constants and Configuration

readonly SCRIPT_VERSION="2026.36"
readonly LOG_FILE="nokey.log"
readonly URL_FILE="nokey.url"
readonly DEFAULT_DOMAIN="www.amd.com"
# REALITY target candidate pool for the automated SNI scan, mirroring 3x-ui's
# REALITY Target Scanner defaults (https://github.com/MHSanaei/3x-ui,
# internal/web/service/reality_scan.go). Probing order is shuffled per run
# (see pick_default_domain); the first feasible candidate wins.
readonly REALITY_TARGET_CANDIDATES=(
    "www.amazon.com"
    "aws.amazon.com"
    "www.samsung.com"
    "www.nvidia.com"
    "www.amd.com"
    "www.intel.com"
    "www.sony.com"
)
# Per-candidate probe timeout (seconds) for the SNI scan.
readonly REALITY_SCAN_TIMEOUT=5
readonly GITHUB_URL="https://github.com/livingfree2023/nokey"
readonly GITHUB_CMD="bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/nokey.sh)"
readonly SERVICE_NAME="nokey.service"
readonly SERVICE_NAME_ALPINE="nokey"
readonly XRAY_SERVICE_USER="nobody"
readonly XRAY_ASSET_DIR="/usr/local/share/xray"
readonly NOKEY_CONFIG_DIR="/usr/local/etc/nokey"
readonly NOKEY_CONFIG_FILE="${NOKEY_CONFIG_DIR}/nokey.yaml"
readonly GITHUB_RELEASE_BASE_URL="https://github.com/livingfree2023/nokey/releases/latest/download"
readonly GITHUB_RELEASE_API_URL="https://api.github.com/repos/livingfree2023/nokey/releases/latest"
readonly GITHUB_NOKEY_RC_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/nokey.rc"
readonly GITHUB_NOKEY_SERVICE_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/nokey.service"
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

mldsa_enabled=0
current_hostname=$(hostname)
caddy_mode=0
reality_dest_port=443  # default port for REALITY destination (not the inbound port)
dry_run=0
keepconfig=0
remove_mode=0
add_limiter_mode=0
change_sni_mode=0
addsocks_mode=0
arg_count=0
xray_config_path="$NOKEY_CONFIG_FILE"
patch_jq_source=""
patch_cleanup=""
share_output_file=""

begin_share_output() {
    share_output_file="$(mktemp "${URL_FILE}.stage.XXXXXX")" || return 1
    chmod 600 "$share_output_file" || return 1
    trap 'rm -f "$share_output_file"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

commit_share_output() {
    [[ -n "$share_output_file" && -s "$share_output_file" ]] || return 1
    mv -f "$share_output_file" "$URL_FILE" || return 1
    share_output_file=""
    trap - EXIT HUP INT TERM
}
patch_tmp_out=""
socks_port=""
socks_username=""
socks_password=""
socks_inbound_json=""
random_unused_port=""
arg_port_set=0
arg_domain_set=0
arg_uuid_set=0
arg_shortid_set=0
arg_mldsa_set=0
arg_mldsa65seed_set=0
arg_mldsa65verify_set=0

realm_mode=0
realm_only=0
realm_remote=""
realm_listen=""

menu_mode=0
default_route_mode=0
default_route_choice=""
egress_ipv4_available=""
egress_ipv6_available=""
default_outbound_json=""
dns_servers_json=""
dns_query_strategy=""
pending_xray_config=""
last_config_backup=""
runtime_xray_service="$SERVICE_NAME"
runtime_xray_service_alpine="$SERVICE_NAME_ALPINE"

# Last REALITY probe latency in ms (set by probe_reality_target; read by pick_default_domain)
probe_latency_ms=""

# Shared output and logging helpers are loaded from nokey-common.sh.

# shellcheck disable=SC2119,SC2120  # $1 is an optional arch override (used by tests)
resolve_arch_binary_name() {
    case "${1:-$(uname -m)}" in
        x86_64|amd64)
            echo "xray_amd64"
            ;;
        aarch64|arm64)
            echo "xray_arm64"
            ;;
        *)
            return 1
            ;;
    esac
}

# shellcheck disable=SC2119,SC2120  # $1 is an optional arch override (used by tests)
resolve_arch_name() {
    case "${1:-$(uname -m)}" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_os_family() {
    if [ "${ID:-}" = "alpine" ] || [ "${ID_LIKE:-}" = "alpine" ]; then
        echo "alpine"
    else
        echo "debian/systemd-compatible"
    fi
}

configure_openrc_crash_restart() {
    local service_file="$1"
    local service_tmp="${service_file}.nokey"

    sed -e '/^[[:space:]]*command_background=/d' \
        -e '/^[[:space:]]*supervisor=/d' \
        -e '/^[[:space:]]*respawn_delay=/d' \
        -e '/^[[:space:]]*respawn_max=/d' \
        "$service_file" > "$service_tmp" || return 1
    {
        echo ""
        echo "supervisor=supervise-daemon"
        echo "respawn_delay=5"
        echo "respawn_max=0"
    } >> "$service_tmp" || return 1
    mv "$service_tmp" "$service_file"
}

configure_systemd_crash_restart() {
    local service_file="$1"
    local service_tmp="${service_file}.nokey"

    sed -e '/^[[:space:]]*Restart=/d' \
        -e '/^[[:space:]]*RestartSec=/d' \
        -e '/^\[Install\]$/i\
Restart=on-failure\
RestartSec=5s' \
        "$service_file" > "$service_tmp" || return 1
    mv "$service_tmp" "$service_file"
}

# shellcheck disable=SC2119,SC2120  # $1 is an optional arch override (used by tests)
resolve_realm_arch_name() {
    local use_musl=0
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        use_musl=1
    fi
    case "${1:-$(uname -m)}" in
        x86_64|amd64)
            if [[ $use_musl -eq 1 ]]; then
                echo "realm_musl_amd64"
            else
                echo "realm_amd64"
            fi
            ;;
        aarch64|arm64)
            if [[ $use_musl -eq 1 ]]; then
                echo "realm_musl_arm64"
            else
                echo "realm_arm64"
            fi
            ;;
        *)
            return 1
            ;;
    esac
}


check_root() {
    if [[ $dry_run -eq 1 ]]; then
        return
    fi
    if [ "$EUID" -ne 0 ]; then
        error "请以root身份运行此脚本 / Please run as root: ${red}sudo -i${none}"
        exit 1
    fi
}


# Define the alias line
#alias_line="alias nokey='bash -c \"\$(curl -sL https://raw.githubusercontent.com/livingfree2023/xray-vless-reality-nokey/refs/heads/main/nokey.sh)\" @'"
alias_line="alias nokey=\"$GITHUB_CMD\""
# Array of potential shell config files (bash-compatible only; fish uses different alias syntax)
config_files=(
    "$HOME/.bashrc"
    "$HOME/.bash_profile"
    "$HOME/.zshrc"
    "$HOME/.profile"
)

# Function to add alias to a file if not already present
add_alias_if_missing() {
    task_start "添加nokey别名 / Add nokey alias to env"
    local modified_files=()
    for file in "${config_files[@]}"; do
      if [ -f "$file" ]; then
          if ! grep -Fxq "$alias_line" "$file"; then
              echo "$alias_line" >> "$file"
              modified_files+=("$file")
          fi
      fi
    done
    task_done

    if [[ ${#modified_files[@]} -gt 0 ]]; then
        info "别名已写入 ${modified_files[*]} / Alias written to: ${modified_files[*]}"
        info "当前会话执行 ${cyan}source ${modified_files[0]}${none} 生效，或新开终端 / Run 'source ${modified_files[0]}' in this session, or open a new terminal"
    fi
}

# Function to remove alias from files
remove_alias() {
    task_start "删除nokey别名 / Remove nokey alias from env"
    for file in "${config_files[@]}"; do
        if [ -f "$file" ]; then
            if grep -Fxq "$alias_line" "$file"; then
                cp -p "$file" "$file.bak"
                grep -vF "$alias_line" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
                info "已从 $file 移除别名 (备份: $file.bak) / Removed alias from $file (backup created as $file.bak)"
            else
                info "$file 中未找到别名 / Alias not found in $file"
            fi
        fi
    done
    info "卸载完成 / Uninstallation complete."
    task_done
}

detect_network_interfaces() {

    Public_IPv4=$(curl -4s -m 2 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
    Public_IPv6=$(curl -6s -m 2 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
    if [[ -z "$Public_IPv6" ]]; then
        # ip.sb returns a bare address (not key=value); fallback when the cloudflare v6 trace probe is empty
        Public_IPv6=$(curl -6s -m 2 https://ip.sb)
    fi

    [[ -n "$Public_IPv4" ]] && IPv4="$Public_IPv4"
    [[ -n "$Public_IPv6" ]] && IPv6="$Public_IPv6"
    log_info "event=network_addresses ipv4_present=$([[ -n "$Public_IPv4" ]] && printf yes || printf no) ipv6_present=$([[ -n "$Public_IPv6" ]] && printf yes || printf no)"
}

detect_caddy_config() {
    task_start "检测 Caddy 服务 / Detecting Caddy Service"

    # Check if caddy is installed
    if ! command -v caddy > /dev/null 2>&1; then
        task_fail
        error "没有安装Caddy，请先安装Caddy或不加--caddy运行 / Caddy is not installed. Please install Caddy first or run without --caddy flag."
        exit 1
    fi

    # Check if caddy service is running (support both systemd and OpenRC)
    local caddy_running=0
    if command -v systemctl > /dev/null 2>&1; then
        if systemctl is-active --quiet caddy; then
            caddy_running=1
        fi
    elif command -v rc-service > /dev/null 2>&1; then
        if rc-service caddy status > /dev/null 2>&1; then
            caddy_running=1
        fi
    fi

    # Fallback: check for caddy process if service check didn't confirm
    if [[ $caddy_running -eq 0 ]] && command -v pgrep > /dev/null 2>&1; then
        if pgrep -x "caddy" > /dev/null; then
            caddy_running=1
        fi
    fi

    if [[ $caddy_running -eq 0 ]]; then
        task_fail
        error "Caddy已安装但未运行，请启动Caddy服务或不加--caddy运行 / Caddy is installed but not running. Please start Caddy service or run without --caddy flag."
        exit 1
    fi

    # Check if Caddyfile exists
    local caddyfile_paths=("/etc/caddy/Caddyfile" "/etc/caddyfile" "/usr/local/etc/caddy/Caddyfile")
    local caddyfile=""
    for path in "${caddyfile_paths[@]}"; do
        if [[ -f "$path" ]]; then
            caddyfile="$path"
            break
        fi
    done

    if [[ -z "$caddyfile" ]]; then
        task_fail
        error "没有在标准位置找到Caddyfile，请确保Caddyfile存在于 /etc/caddy/ 或 /etc/ / Caddyfile not found in standard locations. Please ensure Caddyfile exists in /etc/caddy/ or /etc/."
        exit 1
    fi

    # Parse Caddyfile to extract the first site block address (domain[:port] or [ipv6]:port)
    # Skip global options, comments, empty lines, and imports
    local domain_line=""
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        # Trim whitespace
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue

        # Skip structural characters and directives
        [[ "$line" == "{" || "$line" == "}" ]] && continue
        [[ "$line" =~ ^@ ]] && continue  # named matchers
        [[ "$line" =~ ^\{ ]] && continue  # global options start with {
        [[ "$line" =~ ^import ]] && continue

        # Remove trailing brace if present (e.g., "example.com:8443 {")
        local address_part="${line%%{*}"
        address_part="$(echo "$address_part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$address_part" ]] && continue

        # Match patterns:
        # - example.com
        # - example.com:8443
        # - [2001:db8::1]:8443
        # - example.com:    (edge case: port without number - should reject)
        if [[ "$address_part" =~ ^\[([a-fA-F0-9:]+)\](:[0-9]+)?$ ]]; then
            # IPv6 in brackets, optional port
            extracted_domain="[${BASH_REMATCH[1]}]"
            extracted_port="${BASH_REMATCH[2]:-443}"  # default 443 if no port
            extracted_port="${extracted_port#:}"  # remove leading colon
        elif [[ "$address_part" =~ ^([a-zA-Z0-9.*-]+)(:[0-9]+)?$ ]]; then
            # Domain name (including wildcards like *.example.com) and optional port
            extracted_domain="${BASH_REMATCH[1]}"
            extracted_port="${BASH_REMATCH[2]:-443}"
            extracted_port="${extracted_port#:}"
        else
            # Not a valid site address - could be a directive like `reverse_proxy`, `file_server`, etc.
            # Continue to next line to find the actual site address
            continue
        fi

        # Validate domain is not empty and doesn't look like a directive
        if [[ -n "$extracted_domain" ]]; then
            domain_line="$line"
            break
        fi
    done < "$caddyfile"

    if [[ -z "$domain_line" ]] || [[ -z "$extracted_domain" ]]; then
        task_fail
        error "无法解析Caddyfile中的域名，请确保第一行非注释行是有效地址如 'example.com' 或 '[2001:db8::1]:8443' / Could not parse domain from Caddyfile. Ensure the first non-comment line is a valid address like 'example.com' or '[2001:db8::1]:8443'."
        exit 1
    fi

    # If user already specified a domain via --domain, respect it but inform about caddy override
    if [[ -n "$domain" ]]; then
        info "用户已通过--domain指定域名 '$domain'，将忽略Caddyfile中的域名 / User specified domain '$domain' via --domain flag. Using it (Caddyfile domain will be ignored)."
    else
        domain="$extracted_domain"
    fi

    # Check if domain is a wildcard (starts with "*.")
    if [[ "${domain:0:2}" == "*." ]]; then
        # If not running in an interactive terminal, fail with instructions
        if [[ ! -t 0 ]]; then
            error "检测到泛域名 '$domain' 且未指定--domain，请通过--domain指定具体域名或在交互模式下运行 / Wildcard domain '$domain' detected and --domain not specified. Please provide a specific domain using --domain flag or run in interactive mode."
            exit 1
        fi

        # Interactive prompt
        warn "泛域名不适用于REALITY，REALITY需要明确的域名进行SNI匹配 / Wildcard domain '$domain' is not supported by REALITY. REALITY requires explicit domain names for SNI matching."
        while true; do
            read -r -p "Please enter a specific domain (e.g., example.com): " user_domain
            # Check for empty input
            if [[ -z "$user_domain" ]]; then
                warn "域名不能为空，请重试 / Domain cannot be empty. Please try again."
                continue
            fi
            # Check for wildcard characters in user input
            if [[ "$user_domain" == *[*]* ]]; then
                warn "域名无效，不能包含通配符*，请输入具体域名 / Invalid domain: wildcard characters (*) are not allowed. Please enter a concrete domain name without '*'."
                continue
            fi
            # Accept the domain
            domain="$user_domain"
            info "使用域名: ${domain} / Using domain: ${domain}"
            break
        done
    fi

    # If user already specified a port via --port, respect it
    if [[ -z "$port" ]]; then
        # When using Caddy, default Xray inbound to 443 (if not user-specified)
        port=443
    else
        info "用户已指定端口 '$port'，Xray将绑定到此端口 / User specified port '$port' via --port flag. Using it (Xray will bind to this port)."
    fi

    # When using Caddy, REALITY destination port is hardcoded to 8443
    reality_dest_port=8443

    # Check if the chosen inbound port is available or used by Xray
    local port_in_use=0
    if command -v ss >/dev/null 2>&1; then
        if ss -ltn "sport = :$port" 2>/dev/null | grep -q .; then
            port_in_use=1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ltn 2>/dev/null | grep -qE "[:]$port($| )"; then
            port_in_use=1
        fi
    else
        if (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
            port_in_use=1
        fi
    fi

    if [[ $port_in_use -eq 1 ]]; then
        # Check if it's Xray
        local is_xray=0
        if command -v ss >/dev/null 2>&1; then
            if ss -ltnp "sport = :$port" 2>/dev/null | grep -q xray; then
                is_xray=1
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -ltnp 2>/dev/null | grep -E "[:.]$port($| )" | grep -q xray; then
                is_xray=1
            fi
        else
            # Without ss/netstat we can't definitively identify the process.
            # If Xray service is active, assume it's safe.
            if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
                if rc-service "$SERVICE_NAME_ALPINE" status >/dev/null 2>&1; then
                    is_xray=1
                fi
            else
                if systemctl is-active --quiet "$SERVICE_NAME"; then
                    is_xray=1
                fi
            fi
        fi

        if [[ $is_xray -eq 1 ]]; then
            info "端口 $port 已被Xray使用，配置后将重启服务 / Port $port is already in use by Xray. Will restart service after configuration."
        else
            task_fail
            # Identify which process is using the port (try ss, netstat, lsof, pgrep)
            local process_info=""
            if command -v ss >/dev/null 2>&1; then
                process_info=$(ss -ltnp "sport = :$port" 2>/dev/null | head -n 2)
            elif command -v netstat >/dev/null 2>&1; then
                process_info=$(netstat -ltnp 2>/dev/null | grep -E "[:.]$port($| )" | head -n 1)
            elif command -v lsof >/dev/null 2>&1; then
                process_info=$(lsof -i :"$port" 2>/dev/null | head -n 2)
            elif command -v pgrep >/dev/null 2>&1; then
                process_info=$(pgrep -fl "$port" | head -n 1)
            fi
            error "端口 $port 被占用，带--caddy参数时Xray必须绑定到端口 $port 才能与Caddy配合 / Port $port is occupied by another service. With --caddy flag, Xray must bind to port $port (default 443) to work with Caddy."
            if [[ -n "$process_info" ]]; then
                error "占用端口的进程 / Process using port $port:"
                error "$process_info"
            else
                error "无法获取进程信息，是否其他服务占用了端口443？ / No process information could be retrieved. Is another service using port 443?"
            fi
            error "请停用上述服务以释放端口 $port，或重新配置Caddy使用其他端口 / Please stop the above service to free port $port, or reconfigure Caddy to use a different port."
            exit 1
        fi
    fi

    task_done_with_info "domain=$domain, xray_port=$port, reality_dest_port=$reality_dest_port"

    info "检测到Caddy配置 / Caddy configuration detected:"
    info "  - 域名/SNI / Domain/SNI: $cyan$domain$none"
    info "  - Xray入站端口 / Xray inbound port: $cyan$port$none"
    info "  - REALITY目标 / REALITY destination: $cyan${domain}:${reality_dest_port}$none"
}

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

generate_shortid() {
    # Generate 8 random bytes and convert to hex
    head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

extract_public_key_from_x25519_output() {
    local x25519_output="$1"
    # Support multiple xray output formats, e.g.:
    # - PublicKey: <value>
    # - Public key: <value>
    echo "$x25519_output" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | awk '
        {
            line = $0
            lower = tolower(line)
            if (lower ~ /public[[:space:]]*key/) {
                sub(/^[^:]*:[[:space:]]*/, "", line)
                print line
                exit
            }
        }
    '
}

extract_private_key_from_x25519_output() {
    local x25519_output="$1"
    # Support multiple xray output formats, e.g.:
    # - PrivateKey: <value>
    # - Private key: <value>
    echo "$x25519_output" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | awk '
        {
            line = $0
            lower = tolower(line)
            if (lower ~ /private[[:space:]]*key/) {
                sub(/^[^:]*:[[:space:]]*/, "", line)
                print line
                exit
            }
        }
    '
}

install_dependencies() {

    task_start "开始准备工作 / Starting Preparation"

    #todo: "qrencode" should be a flag controlled feature
    # Callers may request mode-specific tools (for example jq for atomic JSON patches).
    local tools=("curl" "netstat" "$@")

    if [[ -z "${manager:-}" ]]; then
        for candidate in apt yum dnf pacman apk zypper xbps-install; do
            if command -v "$candidate" >/dev/null 2>&1; then manager="$candidate"; break; fi
        done
    fi
    local install_cmd=""
    case "${manager:-}" in
        apt) install_cmd="apt install -y" ;;
        yum) install_cmd="yum install -y" ;;
        dnf) install_cmd="dnf install -y" ;;
        pacman) install_cmd="pacman -Sy --noconfirm" ;;
        apk) install_cmd="apk add --no-cache" ;;
        zypper) install_cmd="zypper install -y" ;;
        xbps-install) install_cmd="xbps-install -Sy" ;;
        *) error "无法识别包管理器 / Cannot detect package manager"; return 1 ;;
    esac

    # Check for missing tools
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            info "缺少$tool，正在安装 / $tool is missing, attempting to install."
            # Map binary names to package names if different
            local package_name="$tool"
            case "$tool" in
                netstat)
                    package_name="net-tools"
                    ;;
                lsof)
                    package_name="lsof"
                    ;;
            esac
            run_logged dependency_install eval "$install_cmd" "$package_name" || { task_fail; return 1; }
            if ! command -v "$tool" > /dev/null 2>&1; then
                task_fail
                error "安装$tool失败，请手动安装后重新运行脚本 / Failed to install '$tool'. Please install it manually and re-run the script."
                exit 1
            fi
        fi
    done

    task_done

}

initialize_ip_from_netstack() {
    task_start "监测IP / Detect IP"
    if [[ -z "${IPv4:-}" && -z "${IPv6:-}" ]]; then
        detect_network_interfaces
    fi
    if [[ -z $netstack ]]; then
        if [[ -n "$IPv4" ]]; then
            netstack=4
        elif [[ -n "$IPv6" ]]; then
            netstack=6
        else
            error "没有获取到公共IP / No public IP detected"
            exit 1
        fi
    fi

    if [[ "$netstack" == "4" ]]; then
        if [[ -z "$IPv4" ]]; then
            error "用户指定IPv4，但未检测到IPv4公网地址 / netstack=4 selected but no public IPv4 detected"
            exit 1
        fi
        ip=${IPv4}
    elif [[ "$netstack" == "6" ]]; then
        if [[ -z "$IPv6" ]]; then
            error "用户指定IPv6，但未检测到IPv6公网地址 / netstack=6 selected but no public IPv6 detected"
            exit 1
        fi
        ip=${IPv6}
    else
        error "错误: 无效的网络协议栈值 / Error: Invalid netstack value"
        exit 1
    fi
    task_done_with_info "$ip"
}

validate_keepconfig_conflicts() {
    if [[ $keepconfig -ne 1 ]]; then
        return 0
    fi

    if [[ "$arg_port_set" -eq 1 || "$arg_domain_set" -eq 1 || "$arg_uuid_set" -eq 1 || "$arg_shortid_set" -eq 1 || "$arg_mldsa_set" -eq 1 || "$arg_mldsa65seed_set" -eq 1 || "$arg_mldsa65verify_set" -eq 1 || "$addsocks_mode" -eq 1 ]]; then
        error "冲突：--keepconfig不能与配置参数或--addsocks同时使用 / Conflict: --keepconfig cannot be used with config arguments or --addsocks."
        error "使用--keepconfig时，所有运行参数将从${xray_config_path}读取 / When --keepconfig is set, all runtime values are loaded from ${xray_config_path}."
        exit 1
    fi
}

validate_patch_mode_conflicts() {
    # Standalone patch modes: never combined with other flags or each other.
    if [[ $add_limiter_mode -eq 0 && $change_sni_mode -eq 0 ]]; then
        return 0
    fi

    if [[ $add_limiter_mode -eq 1 && $change_sni_mode -eq 1 ]]; then
        error "冲突：--add-limiter与--change-sni不能同时使用 / Conflict: --add-limiter and --change-sni cannot be used together."
        exit 1
    fi

    if [[ $arg_count -gt 1 ]]; then
        error "冲突：--add-limiter/--change-sni是独立补丁模式，不能与其他参数同时使用 / Conflict: --add-limiter/--change-sni are standalone patch modes and cannot be combined with any other flag."
        exit 1
    fi
}

validate_addsocks_conflicts() {
    if [[ "$addsocks_mode" -eq 1 && "$arg_count" -gt 1 ]]; then
        error "冲突：--addsocks是独立模式，不能与其他参数同时使用 / Conflict: --addsocks is a standalone mode and cannot be combined with other flags."
        exit 1
    fi
}

configure_xray_service_identity() {
    runtime_xray_service="$SERVICE_NAME"
    runtime_xray_service_alpine="$SERVICE_NAME_ALPINE"
    if [[ "$xray_config_path" == /usr/local/etc/xray/config.json ]]; then
        runtime_xray_service=xray.service
        runtime_xray_service_alpine=xray
    fi
}

xray_service_is_active() {
    configure_xray_service_identity
    if [[ "${ID:-}" == alpine || "${ID_LIKE:-}" == alpine ]]; then
        rc-service "$runtime_xray_service_alpine" status >/dev/null 2>&1
    else
        systemctl is-active --quiet "$runtime_xray_service"
    fi
}

xray_binary_needs_download() {
    local arch_binary_name="$1"
    local xray_binary="/usr/local/bin/xray"
    local current_version=""
    local release_json=""
    local latest_tag=""
    local latest_version=""

    if [[ ! -x "$xray_binary" ]]; then
        log_info "未找到现有Xray二进制文件，将下载 / Existing Xray binary not found; downloading"
        return 0
    fi

    current_version=$("$xray_binary" version 2>/dev/null | awk 'NR == 1 { print $2; exit }')
    current_version="${current_version#v}"
    if [[ -z "$current_version" ]]; then
        log_info "无法读取现有Xray版本，将下载 / Could not read existing Xray version; downloading"
        return 0
    fi

    release_json=$(curl -fsSL --max-time 15 "$GITHUB_RELEASE_API_URL" 2>>"$LOG_FILE" || true)
    latest_tag=$(printf '%s\n' "$release_json" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    latest_version="${latest_tag%%-*}"
    latest_version="${latest_version#v}"

    if [[ -z "$latest_version" ]]; then
        warn "无法获取最新Xray版本，保留现有二进制 / Could not determine latest Xray version; keeping existing binary"
        log_info "Skipped Xray binary download for ${arch_binary_name}: release metadata unavailable"
        return 1
    fi

    if [[ "$current_version" == "$latest_version" ]]; then
        log_info "现有Xray已是最新版本${current_version}，跳过二进制下载 / Existing Xray ${current_version} is current; skipping binary download"
        return 1
    fi

    log_info "Xray版本${current_version}不是最新版本${latest_version}，将下载 / Xray ${current_version} is older than ${latest_version}; downloading"
    return 0
}

xray_data_checksum() {
    local checksum_key="$1"
    local release_json=""

    release_json=$(curl -fsSL --max-time 15 "$GITHUB_RELEASE_API_URL" 2>>"$LOG_FILE" || true)
    printf '%s\n' "$release_json" |
        sed 's/\\\\n/\n/g' |
        sed -n "s/.*${checksum_key}:[[:space:]]*\([[:xdigit:]]\{64\}\).*/\1/p" |
        head -n 1
}

update_xray_data_file() {
    local asset_name="$1"
    local checksum_key="$2"
    local data_path="${XRAY_ASSET_DIR}/${asset_name}"
    local expected_checksum=""
    local actual_checksum=""
    local temp_path=""

    expected_checksum="$(xray_data_checksum "$checksum_key")"
    if [[ -f "$data_path" && -n "$expected_checksum" ]] && command -v sha256sum >/dev/null 2>&1; then
        actual_checksum="$(sha256sum "$data_path" | awk '{print $1}')"
        if [[ "$actual_checksum" == "$expected_checksum" ]]; then
            log_info "${asset_name}校验和匹配，跳过下载 / ${asset_name} checksum matches; skipping download"
            return 0
        fi
        log_info "${asset_name}校验和不匹配，将更新 / ${asset_name} checksum differs; updating"
    elif [[ -f "$data_path" && -z "$expected_checksum" ]]; then
        warn "无法获取${asset_name}校验和，保留现有文件 / Could not get ${asset_name} checksum; keeping existing file"
        return 0
    elif [[ -f "$data_path" ]] && ! command -v sha256sum >/dev/null 2>&1; then
        warn "缺少sha256sum，将更新${asset_name} / sha256sum is unavailable; updating ${asset_name}"
    fi

    temp_path="$(mktemp "/tmp/nokey.${asset_name}.XXXXXX")" || {
        task_fail
        error "创建${asset_name}临时文件失败 / Failed to create temporary file for ${asset_name}"
        exit 1
    }
    if ! curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/${asset_name}" -o "$temp_path" >> "$LOG_FILE" 2>&1; then
        rm -f "$temp_path"
        task_fail
        error "下载${asset_name}失败 / Failed to download ${asset_name}"
        return 1
    fi

    if [[ -n "$expected_checksum" ]] && command -v sha256sum >/dev/null 2>&1; then
        actual_checksum="$(sha256sum "$temp_path" | awk '{print $1}')"
        if [[ "$actual_checksum" != "$expected_checksum" ]]; then
            rm -f "$temp_path"
            task_fail
            error "${asset_name}校验和验证失败 / Checksum verification failed for ${asset_name}"
            return 1
        fi
    fi

    if ! mv "$temp_path" "$data_path"; then
        rm -f "$temp_path"
        task_fail
        error "安装${asset_name}失败 / Failed to install ${asset_name}"
        return 1
    fi
    log_verbose "Installed verified ${asset_name}"
}

normalize_xray_runtime_permissions() {
    local config_path="${1:-}"
    local config_dir=""
    local asset_file=""

    if [[ -d "$XRAY_ASSET_DIR" ]] && ! chmod 755 "$XRAY_ASSET_DIR"; then
        log_info "Unable to set Xray asset directory permissions: ${XRAY_ASSET_DIR}"
        return 1
    fi

    for asset_file in "${XRAY_ASSET_DIR}/geoip.dat" "${XRAY_ASSET_DIR}/geosite.dat"; do
        if [[ -f "$asset_file" ]] && ! chmod 644 "$asset_file"; then
            log_info "Unable to set Xray asset permissions: ${asset_file}"
            return 1
        fi
    done

    if [[ -n "$config_path" && -f "$config_path" ]]; then
        config_dir="$(dirname "$config_path")"
        if ! chmod 711 "$config_dir" || ! chown "$XRAY_SERVICE_USER" "$config_path" || ! chmod 600 "$config_path"; then
            log_info "Unable to set Xray config permissions: ${config_path}"
            return 1
        fi
    fi

}

load_runtime_vars_from_existing_config() {
    local config_path="$xray_config_path"
    if [[ ! -f "$config_path" && -f "/usr/local/etc/xray/config.json" ]]; then
        config_path="/usr/local/etc/xray/config.json"
        xray_config_path="/usr/local/etc/xray/config.json"
    fi
    local x25519_output=""
    local jq_error=""
    local jq_target="$config_path"
    local jsonc_tmp=""

    task_start "读取现有配置 / Load existing xray config"

    if ! command -v jq >/dev/null 2>&1; then
        task_fail
        error "--keepconfig模式需要jq，请先安装jq / --keepconfig mode requires jq. Please install jq first: apt install -y jq"
        exit 1
    fi

    if [[ ! -f "$config_path" ]]; then
        task_fail
        error "缺少配置文件: $config_path，--keepconfig需要现有配置文件 / Missing config: $config_path. --keepconfig requires an existing config file."
        exit 1
    fi
    if [[ ! -r "$config_path" ]]; then
        task_fail
        error "配置文件不可读 / Config is not readable: $config_path"
        exit 1
    fi
    case "$config_path" in
        *.yaml|*.yml)
            jsonc_tmp="$(mktemp /tmp/nokey-config-json.XXXXXX)" || return 1
            if ! xray_config_to_json "$config_path" "$jsonc_tmp"; then
                rm -f "$jsonc_tmp"
                task_fail
                return 1
            fi
            jq_target="$jsonc_tmp"
            ;;
    esac
    if [[ "$jq_target" == "$config_path" ]] && ! jq empty "$config_path" >/dev/null 2>/tmp/nokey-jq-raw.err; then
        jq_error="$(cat /tmp/nokey-jq-raw.err 2>/dev/null || true)"
        log_verbose "jq raw parse error: ${jq_error}"

        # Config generated by this script may include // comments; strip them and retry.
        jsonc_tmp="$(mktemp /tmp/nokey-config-json.XXXXXX)" || {
            task_fail
            error "无法创建临时文件用于JSONC解析 / Failed to create temporary file for JSONC parsing."
            exit 1
        }
        sed -E 's@^[[:space:]]*//.*$@@; s@[[:space:]]+//.*$@@' "$config_path" > "$jsonc_tmp"

        if ! jq empty "$jsonc_tmp" >/dev/null 2>/tmp/nokey-jq-stripped.err; then
            local stripped_error=""
            stripped_error="$(cat /tmp/nokey-jq-stripped.err 2>/dev/null || true)"
            task_fail
            error "配置文件格式无效 / Invalid config format in $config_path."
            error "jq(原始): ${jq_error}"
            error "jq(去注释): ${stripped_error}"
            error "请检查所报行附近的配置语法，配置内容不会写入日志 / Check syntax near the reported line; config contents are not logged."

            rm -f "$jsonc_tmp" /tmp/nokey-jq-raw.err /tmp/nokey-jq-stripped.err >/dev/null 2>&1 || true
            exit 1
        fi

        jq_target="$jsonc_tmp"
    fi

    port="$(jq -r '.inbounds[0].port // empty' "$jq_target")"
    uuid="$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$jq_target")"
    domain="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$jq_target")"
    shortid="$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$jq_target")"
    private_key="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$jq_target")"
    mldsa65Seed="$(jq -r '.inbounds[0].streamSettings.realitySettings.mldsa65Seed // empty' "$jq_target")"
    reality_dest="$(jq -r '.inbounds[0].streamSettings.realitySettings.dest // empty' "$jq_target")"

    if [[ -z "$domain" && -n "$reality_dest" ]]; then
        # Fallback for configurations that only keep "dest".
        if [[ "$reality_dest" =~ ^\[[^]]+\]:[0-9]+$ ]]; then
            domain="${reality_dest%:*}"
        elif [[ "$reality_dest" =~ ^[^:]+:[0-9]+$ ]]; then
            domain="${reality_dest%:*}"
        else
            domain="$reality_dest"
        fi
    fi

    if [[ "$reality_dest" =~ :([0-9]+)$ ]]; then
        reality_dest_port="${BASH_REMATCH[1]}"
    fi

    if [[ -z "$port" || -z "$uuid" || -z "$domain" || -z "$shortid" || -z "$private_key" ]]; then
        task_fail
        error "配置缺少必需的REALITY字段(port/uuid/domain/shortid/privateKey) / Config missing required REALITY fields (port/uuid/domain/shortid/privateKey)."
        exit 1
    fi

    x25519_output="$(xray x25519 -i "$private_key" 2>>"$LOG_FILE")"
    if [[ -z "$x25519_output" ]]; then
        task_fail
        error "无法从现有私钥推导出公钥: xray x25519 -i <private_key> / Failed to derive public key from existing private key using: xray x25519 -i <private_key>"
        exit 1
    fi

    public_key="$(extract_public_key_from_x25519_output "$x25519_output")"
    if [[ -z "$public_key" ]]; then
        task_fail
        error "无法从xray x25519输出解析公钥 / Failed to parse public key from xray x25519 output."
        exit 1
    fi

    if [[ -n "$mldsa65Seed" ]]; then
        mldsa_enabled=1
        local mldsa_output
        mldsa_output="$(xray mldsa65 -i "$mldsa65Seed" 2>>"$LOG_FILE" || true)"
        mldsa65Verify="$(echo "$mldsa_output" | awk '/Verify:/ {print $2}')"
        if [[ -z "$mldsa65Verify" ]]; then
            task_fail
            error "无法从现有配置中的mldsa65Seed推导出mldsa65验证密钥 / Failed to derive mldsa65 verify key from mldsa65Seed in existing config."
            exit 1
        fi
    else
        mldsa_enabled=0
        mldsa65Verify=""
    fi
    rm -f "$jsonc_tmp" /tmp/nokey-jq-raw.err /tmp/nokey-jq-stripped.err >/dev/null 2>&1 || true
    task_done_with_info "port=${port}, credentials=loaded"
}

cleanup_legacy_xray_access_log() {
    local log_path="${1:-/tmp/xray_access.log}"
    if [[ ! -f "$log_path" || -L "$log_path" ]]; then
        return 0
    fi
    if ! rm -f "$log_path" >> "$LOG_FILE" 2>&1; then
        warn "无法清理旧Xray访问日志: $log_path / Could not remove legacy Xray access log: $log_path"
        return 1
    fi
    log_verbose "Removed legacy Xray access log: $log_path"
}

install_xray() {
    if [[ $force_reinstall == 1 ]]; then
      uninstall_xray
    fi

    task_start "开始，安装或升级XRAY / Install or upgrade XRAY"

    # Keep the running process intact until a validated configuration is ready.
    configure_xray_service_identity
    cleanup_legacy_xray_access_log || { task_fail; error "清理旧Xray访问日志失败 / Failed to clean legacy Xray access log"; exit 1; }

    local arch_binary_name=""
    local arch_name=""
    arch_binary_name="$(resolve_arch_binary_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }
    arch_name="$(resolve_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }

    log_info "检测到系统 / Detected OS: $(resolve_os_family) | 架构 / Architecture: ${arch_name}"

    mkdir -p /usr/local/bin "$XRAY_ASSET_DIR" "$NOKEY_CONFIG_DIR" || { task_fail; error "创建nokey目录失败 / Failed to create nokey directories"; exit 1; }
    log_verbose "Created install directories under /usr/local"

    if xray_binary_needs_download "$arch_binary_name"; then
        log_info "正在从GitHub Releases下载xray二进制文件 / Downloading xray binary from GitHub Releases"
        log_verbose "Downloading: ${GITHUB_RELEASE_BASE_URL}/${arch_binary_name} -> /usr/local/bin/xray"
        local binary_stage=""
        local binary_version=""
        binary_stage="$(mktemp /usr/local/bin/xray.stage.XXXXXX)" || return 1
        if ! run_logged binary_download curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/${arch_binary_name}" -o "$binary_stage" || ! chmod 755 "$binary_stage"; then
            rm -f "$binary_stage"
            task_fail
            return 1
        fi
        binary_version="$("$binary_stage" version 2>/dev/null)" || { rm -f "$binary_stage"; task_fail; return 1; }
        case "$binary_version" in
            Xray\ *) ;;
            *) rm -f "$binary_stage"; task_fail; error "下载的Xray无法通过版本校验 / Downloaded Xray failed version validation."; return 1 ;;
        esac
        mv -f "$binary_stage" /usr/local/bin/xray || { rm -f "$binary_stage"; return 1; }
        log_info "event=binary_updated version=$(printf '%s' "$binary_version" | head -n 1)"
    fi
    update_xray_data_file "geoip.dat" "SHA256-geoip.dat" || exit 1
    update_xray_data_file "geosite.dat" "SHA256-geosite.dat" || exit 1
    normalize_xray_runtime_permissions || { task_fail; error "设置Xray运行时文件权限失败 / Failed to set Xray runtime file permissions"; exit 1; }

    # A preserved conventional Xray configuration keeps its existing service.
    if [[ "$runtime_xray_service" == xray.service ]]; then
        log_info "event=service_preserved service=xray"
        task_done
        return 0
    fi
    local nokey_rc_tmp
    local nokey_service_tmp
    nokey_rc_tmp="$(mktemp /tmp/nokey.rc.XXXXXX)" || { task_fail; error "创建nokey.rc临时文件失败 / Failed to create temporary file for nokey.rc"; exit 1; }
    nokey_service_tmp="$(mktemp /tmp/nokey.service.XXXXXX)" || { task_fail; error "创建nokey.service临时文件失败 / Failed to create temporary file for nokey.service"; exit 1; }

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        log_info "安装OpenRC服务 / Installing OpenRC service: /etc/init.d/${SERVICE_NAME_ALPINE}"
        log_verbose "Downloading service file: ${GITHUB_NOKEY_RC_URL} -> ${nokey_rc_tmp}"
        run_logged download curl -fSL "${GITHUB_NOKEY_RC_URL}" -o "${nokey_rc_tmp}" || { task_fail; error "下载nokey.rc失败 / Failed to download nokey.rc"; exit 1; }
        configure_openrc_crash_restart "${nokey_rc_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "配置nokey崩溃自动重启失败 / Failed to configure nokey crash restart"; exit 1; }
        sed -e "s@/usr/local/etc/nokey/nokey\\.json@${xray_config_path}@g" \
            -e "s@/usr/local/etc/nokey/nokey\\.yaml@${xray_config_path}@g" \
            "${nokey_rc_tmp}" > /etc/init.d/"$SERVICE_NAME_ALPINE" || { task_fail; return 1; }
        chmod 755 /etc/init.d/"$SERVICE_NAME_ALPINE" || return 1
        rm -f "${nokey_rc_tmp}" >> "$LOG_FILE" 2>&1
        log_verbose "Installed OpenRC service file from nokey.rc"
        rc-update add "$SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用OpenRC服务$SERVICE_NAME_ALPINE失败 / Failed to enable OpenRC service $SERVICE_NAME_ALPINE"; exit 1; }
        log_verbose "Enabled OpenRC service: $SERVICE_NAME_ALPINE"
        if [ -f /etc/init.d/xray ]; then
            rc-service xray stop 2>/dev/null || true
            rc-update del xray 2>/dev/null || true
            rm -f /etc/init.d/xray 2>/dev/null || true
        fi
    else
        log_info "安装systemd服务 / Installing systemd service: /etc/systemd/system/${SERVICE_NAME}"
        log_verbose "Downloading service file: ${GITHUB_NOKEY_SERVICE_URL} -> ${nokey_service_tmp}"
        run_logged download curl -fSL "${GITHUB_NOKEY_SERVICE_URL}" -o "${nokey_service_tmp}" || { task_fail; error "下载nokey.service失败 / Failed to download nokey.service"; exit 1; }
        # shellcheck disable=SC2016
        sed -e "s/\\\$INSTALL_USER/${XRAY_SERVICE_USER}/g" \
            -e "s@/usr/local/etc/nokey/nokey\\.json@${xray_config_path}@g" \
            -e "s@/usr/local/etc/nokey/nokey\\.yaml@${xray_config_path}@g" \
            -e '/\${temp_CapabilityBoundingSet}/d' \
            -e '/\${temp_AmbientCapabilities}/d' \
            -e '/\${temp_NoNewPrivileges}/d' \
            "${nokey_service_tmp}" > /etc/systemd/system/"$SERVICE_NAME" || { task_fail; error "写入/etc/systemd/system/$SERVICE_NAME失败 / Failed to write /etc/systemd/system/$SERVICE_NAME"; exit 1; }
        configure_systemd_crash_restart /etc/systemd/system/"$SERVICE_NAME" >> "$LOG_FILE" 2>&1 || { task_fail; error "配置nokey崩溃自动重启失败 / Failed to configure nokey crash restart"; exit 1; }
        rm -f "${nokey_service_tmp}" >> "$LOG_FILE" 2>&1
        log_verbose "Installed systemd service file from nokey.service"
        systemctl daemon-reload >> "$LOG_FILE" 2>&1 || { task_fail; error "systemctl daemon-reload失败 / systemctl daemon-reload failed"; exit 1; }
        systemctl enable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用systemd服务$SERVICE_NAME失败 / Failed to enable systemd service $SERVICE_NAME"; exit 1; }
        log_verbose "Enabled systemd service: $SERVICE_NAME"
        if [ -f /etc/systemd/system/xray.service ]; then
            systemctl stop xray.service 2>/dev/null || true
            systemctl disable xray.service 2>/dev/null || true
            rm -f /etc/systemd/system/xray.service 2>/dev/null || true
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi

    task_done

}

uninstall_in_alpine() {
   {
     run_logged service_stop rc-service "$SERVICE_NAME_ALPINE" stop || true
     rc-update del "$SERVICE_NAME_ALPINE" 2>/dev/null || true
     rm -rf "/usr/local/bin/xray"
     rm -rf "/usr/local/share/xray"
     rm -rf "$NOKEY_CONFIG_DIR"
     rm -rf "/etc/init.d/$SERVICE_NAME_ALPINE"
     rc-service xray stop 2>/dev/null || true
     rc-update del xray 2>/dev/null || true
     rm -rf "/etc/init.d/xray" 2>/dev/null || true
   } >> "$LOG_FILE" 2>&1
}

uninstall_xray() {
# Check if geodata files exist and are recent (less than 1 week old)
    task_start "什么？要卸载重装？ / Force Reinstall"

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
      info "Alpine系统：卸载nokey / Alpine OS: uninstall nokey"
      uninstall_in_alpine
    else
      {
        run_logged service_stop systemctl stop "$SERVICE_NAME" || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f /etc/systemd/system/"$SERVICE_NAME"
        systemctl stop xray.service 2>/dev/null || true
        systemctl disable xray.service 2>/dev/null || true
        rm -f /etc/systemd/system/xray.service 2>/dev/null || true
        systemctl daemon-reload
        rm -rf "/usr/local/bin/xray"
        rm -rf "/usr/local/share/xray"
        rm -rf "$NOKEY_CONFIG_DIR"
      } >> "$LOG_FILE" 2>&1
    fi

    task_done

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

show_banner() {
    display_result "NoKey · Xray VLESS REALITY" "$cyan"
    display_result "版本 / Version: $SCRIPT_VERSION"
    display_result "$GITHUB_URL"
}

parse_args() {
    # Parse command line arguments
    for arg in "$@"; do
      arg_count=$((arg_count + 1))
      case $arg in
        --help)
          show_help
          ;;
        --force)
          force_reinstall=1
          ;;
        --netstack=*)
          case "${arg#*=}" in
            4)
              netstack=4
              ;;
            6)
              netstack=6
              ;;
            *)
              error "错误: 无效的网络协议栈值 / Error: Invalid netstack value"
              show_help 1
              ;;
          esac
          ;;
        --port=*)
          port="${arg#*=}"
          if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            error "错误: 端口必须是 1-65535 的数字 / Error: --port must be an integer between 1 and 65535"
            show_help 1
          fi
          arg_port_set=1
          ;;
        --domain=*)
          domain="${arg#*=}"
          arg_domain_set=1
          ;;
        --uuid=*)
          uuid="${arg#*=}"
          arg_uuid_set=1
          ;;
        --mldsa65Seed=*)
          mldsa65Seed="${arg#*=}"
          arg_mldsa65seed_set=1
          ;;
        --mldsa65Verify=*)
          mldsa65Verify="${arg#*=}"
          arg_mldsa65verify_set=1
          ;;
        --mldsa)
          mldsa_enabled=1
          arg_mldsa_set=1
          ;;
        --caddy)
          caddy_mode=1
          ;;
        --realm)
          realm_mode=1
          ;;
        --realm-only)
            realm_mode=1
            realm_only=1
            ;;
        --default-route)
            default_route_mode=1
            ;;
        --default-route=*)
            default_route_mode=1
            default_route_choice="${arg#*=}"
            case "$default_route_choice" in
                4|6) ;;
                *) display_result "--default-route仅支持4或6 / Use --default-route=4|6." >&2; exit 1 ;;
            esac
            ;;
        --remote=*)
            realm_remote="${arg#*=}"
            ;;
        --listen=*)
          realm_listen="${arg#*=}"
          ;;
        --shortid=*)
          shortid="${arg#*=}"
          arg_shortid_set=1
          ;;
        --keepconfig)
          keepconfig=1
          ;;
        --remove)
          remove_mode=1
          ;;
        --add-limiter)
          add_limiter_mode=1
          ;;
        --change-sni)
          change_sni_mode=1
          ;;
        --addsocks)
          addsocks_mode=1
          ;;
        --dry-run)
          dry_run=1
          ;;
        --menu)
          menu_mode=1
          ;;
        *)
          error "什么鬼参数: $arg / Unknown option: $arg"
          show_help 1
          ;;
      esac
    done

    validate_keepconfig_conflicts
    validate_patch_mode_conflicts
    validate_addsocks_conflicts
    if [[ "$default_route_mode" -eq 1 && ( "$remove_mode" -eq 1 || "$keepconfig" -eq 1 || "$realm_only" -eq 1 || "$add_limiter_mode" -eq 1 || "$change_sni_mode" -eq 1 || "$addsocks_mode" -eq 1 || "$menu_mode" -eq 1 ) ]]; then
        display_result "--default-route与当前参数冲突 / --default-route conflicts with the selected mode." >&2
        exit 1
    fi

     if [[ $realm_mode -eq 1 ]]; then
         if [[ -z "$realm_remote" ]]; then
             error "错误: --realm 模式下 --remote 是必填项 / Error: --remote is required when using --realm."
             error "用法: --realm --remote <host:port> [--listen <host:port>] / Usage: --realm --remote <host:port> [--listen <host:port>]"
             show_help
         fi
         # Validate --remote format: must contain a colon + port
         if ! [[ "$realm_remote" =~ ^\[?[^\]]*\]?:[0-9]+$ ]]; then
             error "错误: --remote 格式无效，应为 <host>:<port> (例如 1.2.3.4:443) / Error: Invalid --remote format. Expected <host>:<port> (e.g., 1.2.3.4:443)."
             exit 1
         fi
     fi

}

run_feature_script() {
    local feature_name="$1"
    shift
    local feature_path="${script_dir}/${feature_name}"
    local feature_url="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/${feature_name}"

    if [[ -f "$feature_path" ]]; then
        bash "$feature_path" "$@"
    else
        bash <(curl -fsSL "$feature_url") "$@"
    fi
}

show_feature_menu() {
    local choice=""
    local remote=""
    local listen=""
    local acme_domain=""
    local cf_token=""
    local hysteria_domain=""
    local hysteria_cf_token=""

    if ! exec 3</dev/tty; then
        error "--menu requires an interactive terminal / --menu需要交互式终端"
        return 1
    fi

    while true; do
        display_result ""
        display_result "NoKey menu"
        display_result "1) Install Xray VLESS Reality"
        display_result "2) Install Realm"
        display_result "3) Add Xray SOCKS5"
        display_result "4) Configure Xray WARP"
        display_result "5) 选择默认出口 / Default egress"
        display_result "6) Enable BBR"
        display_result "7) Get SSL certificate with acme.sh"
        display_result "8) Install Hysteria2 server"
        display_result "9) Add IPv6 Xray Shadowsocks 2022"
        display_result "0) 退出 / Exit"
        read -r -p "Select an option: " choice <&3 || break
        case "$choice" in
            1) run_feature_script nokey.sh; break ;;
            2)
                read -r -p "Realm remote host:port: " remote <&3
                read -r -p "Realm listen address (optional): " listen <&3
                if [[ -n "$listen" ]]; then
                    run_feature_script realm.sh "--remote=$remote" "--listen=$listen"
                else
                    run_feature_script realm.sh "--remote=$remote"
                fi
                break
                ;;
            3) run_feature_script xray-socks.sh; break ;;
            4) run_feature_script xray-warp.sh; break ;;
            5) run_feature_script nokey.sh --default-route; break ;;
            6) run_feature_script bbr.sh; break ;;
            7)
                read -r -p "Certificate domain: " acme_domain <&3
                read -r -s -p "Cloudflare API token (optional, press Enter for HTTP-01): " cf_token <&3
                echo
                if [[ -n "$cf_token" ]]; then
                    export CF_Token="$cf_token"
                else
                    unset CF_Token
                fi
                run_feature_script acme-cert.sh "--domain=$acme_domain"
                unset CF_Token
                break
                ;;
            8)
                read -r -p "Hysteria2 domain: " hysteria_domain <&3
                read -r -s -p "Cloudflare API token (optional, press Enter for certificate paths): " hysteria_cf_token <&3
                echo
                if [[ -n "$hysteria_cf_token" ]]; then
                    export HYSTERIA_CF_TOKEN="$hysteria_cf_token"
                else
                    unset HYSTERIA_CF_TOKEN
                fi
                run_feature_script hysteria2.sh "--domain=$hysteria_domain"
                unset HYSTERIA_CF_TOKEN
                break
                ;;
            9) run_feature_script xray-shadowsocks.sh; break ;;
            0) break ;;
            *) warn "Invalid menu choice / 无效选择" ;;
        esac
    done
    exec 3<&-
}




# Returns 0 if <port> is free or already owned by <process_name>, so the port can
# be safely reused by our service; 1 otherwise. Falls back to service status when
# ss/netstat are unavailable.
# Usage: is_port_reusable <port> <process_name> <systemd_service> <openrc_service>
is_port_reusable() {
    local check_port="$1"
    local process_name="$2"
    local systemd_service="$3"
    local openrc_service="$4"
    local port_in_use=0

    if command -v ss >/dev/null 2>&1; then
        if ss -ltn "sport = :$check_port" 2>/dev/null | grep -q .; then
            port_in_use=1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ltn 2>/dev/null | grep -qE "[:]$check_port($| )"; then
            port_in_use=1
        fi
    else
        if (echo > /dev/tcp/127.0.0.1/"$check_port") >/dev/null 2>&1; then
            port_in_use=1
        fi
    fi

    if [[ $port_in_use -eq 0 ]]; then
        return 0
    fi

    # Port is in use: reusable only if it belongs to our service
    if command -v ss >/dev/null 2>&1; then
        if ss -ltnp "sport = :$check_port" 2>/dev/null | grep -q "$process_name"; then
            return 0
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ltnp 2>/dev/null | grep -E "[:.]$check_port($| )" | grep -q "$process_name"; then
            return 0
        fi
    else
        # Without ss/netstat we cannot identify the process; if the service is
        # active, assume it owns the port.
        if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            if rc-service "$openrc_service" status >/dev/null 2>&1; then
                return 0
            fi
        else
            if systemctl is-active --quiet "$systemd_service"; then
                return 0
            fi
        fi
    fi
    return 1
}

# Probe a REALITY target candidate. Mirrors 3x-ui's REALITY Target Scanner
# feasibility gate: the server must negotiate TLS 1.3, ALPN h2, and present a
# cert chain that verifies. curl verifies the chain by default; --tlsv1.3
# forces TLS 1.3; --http2 + %{http_version}==2 proves h2. X25519 is implied:
# every TLS 1.3 server in the pool negotiates it (3x-ui additionally requires
# it). Also records TLS-handshake latency (%{time_appconnect}) into the
# probe_latency_ms global for the picker to report. Returns 0 if feasible.
# The probe outcome (and why) is appended to the log.
probe_reality_target() {
    local candidate="$1"
    local probe_out=""
    local curl_rc=0
    probe_latency_ms=""
    probe_out="$(curl -sSI --max-time "$REALITY_SCAN_TIMEOUT" --tlsv1.3 --http2 -o /dev/null -w '%{http_version}|%{time_appconnect}' "https://$candidate/" 2>/dev/null)" || curl_rc=$?
    local http_version="${probe_out%%|*}"
    local latency_sec="${probe_out#*|}"
    if [[ -n "$latency_sec" && "$latency_sec" != "$http_version" ]]; then
        probe_latency_ms="$(awk -v t="$latency_sec" 'BEGIN { printf "%.0f", t * 1000 }')"
    fi
    if [[ "$http_version" == "2" ]]; then
        log_info "REALITY probe: $candidate -> feasible (TLS 1.3 + h2 verified, ${probe_latency_ms}ms)"
        return 0
    fi
    if [[ $curl_rc -ne 0 ]]; then
        log_info "REALITY probe: $candidate -> rejected (curl rc=$curl_rc: connect/TLS/cert failure)"
    else
        log_info "REALITY probe: $candidate -> rejected (negotiated HTTP/$http_version, need h2)"
    fi
    return 1
}

# Auto-pick an SNI when the user did not pass --domain: probe the candidate
# pool and use the first feasible one; fall back to DEFAULT_DOMAIN if none
# responds. Skips the scan entirely when a domain is already set. Each probe
# step and the reason for the pick are reported to stdout and the log.
pick_default_domain() {
    [[ -n $domain ]] && return 0
    local candidate
    local shuffled=("${REALITY_TARGET_CANDIDATES[@]}")
    local i j tmp
    # Fisher-Yates shuffle so no two installs probe the same first SNI
    # (avoid a fixed scan-order fingerprint across one-click deployments).
    for ((i = ${#shuffled[@]} - 1; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        tmp="${shuffled[i]}"
        shuffled[i]="${shuffled[j]}"
        shuffled[j]="$tmp"
    done
    info "自动探测REALITY目标SNI / Auto-probing REALITY target SNI:"
    for candidate in "${shuffled[@]}"; do
        if probe_reality_target "$candidate"; then
            domain="$candidate"
            info "  ${candidate} -> ${green}可用 / feasible${none} (TLS 1.3 + h2 验证通过 / verified, ${probe_latency_ms}ms)"
            info "自动选择REALITY目标 / Auto-selected REALITY target: ${cyan}${domain}${none}"
            return 0
        fi
        info "  ${candidate} -> 不可用 / not feasible (原因见日志 / reason in log)"
    done
    domain="$DEFAULT_DOMAIN"
    warn "所有候选均不可用，使用默认SNI / No feasible target probed; using default SNI: ${cyan}${domain}${none}"
    return 1
}

initialize_variables() {
    # If caddy mode is enabled, detect and set domain/port from Caddyfile
    if [[ $caddy_mode -eq 1 ]]; then
        detect_caddy_config
    fi

    initialize_ip_from_netstack

    task_start "寻找一个合适的端口 / Find an Available Port"
    if [[ -z $port ]]; then
      # Prefer 443 when it is free or already owned by Xray, otherwise random
      if is_port_reusable 443 xray "$SERVICE_NAME" "$SERVICE_NAME_ALPINE"; then
        port=443
      else
        base=$((10000 + RANDOM % 50000))  # Start at a random offset
        port_found=0
        for i in $(seq 0 1000); do
          port=$((base + i))
          if ! (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
            port_found=1
            break
          fi
        done
        if [[ $port_found -eq 0 ]]; then
          task_fail
          error "没有找到可用端口 / Could not find an unused port."
          exit 1
        fi
      fi
      # info "\n找到一个空闲随机端口，如果有防火墙需要放行 / Random unused port found, if firewall enabled, add tcp rules for: ${cyan}$port${none}"
    fi
    task_done_with_info "$port"

    # Default domain if not set (auto-scan SNI).
    if [[ -z $domain ]]; then
        pick_default_domain || true
    else
        info "用户指定了自己的SNI / User specified SNI: ${cyan}${domain}${none}"
    fi
}

generate_crypto() {
    task_start "生成一个UUID / Generate UUID"
    if [[ -z $uuid ]]; then
        uuid=$(generate_uuid)
    fi
    task_done


    if [[ -z $private_key ]]; then
      local x25519_status=0
      keys=$(xray x25519 2>>"$LOG_FILE") || x25519_status=$?
      if [[ -z "$keys" ]]; then
        task_fail
        log_verbose "xray x25519 failed: exit status ${x25519_status}"
        if [[ "$x25519_status" -eq 137 ]]; then
          error "xray x25519被终止（退出码137），请检查容器内存限制和OOM记录 / xray x25519 was killed (exit 137); check the container memory limit and OOM events."
        else
          error "生成x25519密钥失败（退出码${x25519_status}），请查看$LOG_FILE / Failed to generate x25519 keys (exit ${x25519_status}); check $LOG_FILE."
        fi
        exit 1
      fi
      task_start "生成一个私钥 / Generate Private Key"
      private_key=$(extract_private_key_from_x25519_output "$keys")
      if [[ -z "$private_key" ]]; then
        task_fail
        error "无法从x25519输出解析私钥 / Failed to parse PrivateKey from x25519 output."
        exit 1
      fi
      task_done
      task_start "生成一个公钥 / Generate Public Key"
      public_key=$(extract_public_key_from_x25519_output "$keys")
      if [[ -z "$public_key" ]]; then
        task_fail
        error "无法从x25519输出解析公钥 / Failed to parse PublicKey from x25519 output."
        exit 1
      fi
      task_done
    fi

    task_start "生成一个shortid / Generate shortid"
    if [[ -z $shortid ]]; then
      shortid=$(generate_shortid)
      task_done
    fi


    if [[ $mldsa_enabled == 1 ]]; then
      task_start "生成ML-DSA-65密钥对 / Generate ML-DSA-65 Keys"
      if [[ -z $mldsa65Seed || -z $mldsa65Verify ]]; then
        # info "\nmldsa65Seed mldsa65Verify 没有指定，自动生成 / Generating mldsa65keys"
        mldsa65keys=$(xray mldsa65)
        if [[ -z "$mldsa65keys" ]]; then
          task_fail
          error "生成ML-DSA-65密钥失败，xray是否安装正确？ / Failed to generate ML-DSA-65 keys. Is xray installed correctly?"
          exit 1
        fi
        mldsa65Seed=$(echo "$mldsa65keys" | awk '/Seed:/ {print $2}')
        mldsa65Verify=$(echo "$mldsa65keys" | awk '/Verify:/ {print $2}')
        # info "私钥 (PrivateKey) = ${cyan}${mldsa65Seed}${none}"
        # info "公钥 (PublicKey) = ${cyan}${mldsa65Verify}${none}"
      fi
      task_done
    else
      mldsa65Seed=""
      mldsa65Verify=""
    fi
}

build_xray_config() {
    build_default_route_settings || return 1
    # info "网络栈netstack = ${cyan}${netstack}${none}"
    # info "本机IP = ${cyan}${ip}${none}"
    # info "端口Port = ${cyan}${port}${none}"
    # info "用户UUID = ${cyan}${uuid}${none}"
    # info "域名SNI = ${cyan}$domain${none}"

    # Randomize the REALITY fallback rate limit around 1 Mbps sustained / 2 Mbps
    # burst (targets: 125000 / 250000 bytes-per-sec). Xray docs mandate
    # randomization for one-click installers to avoid a fixed-rate fingerprint.
    fallback_bytes_per_sec=$((125000 * (85 + RANDOM % 31) / 100))
    fallback_burst_bytes_per_sec=$((250000 * (85 + RANDOM % 31) / 100))

    reality_template=$(cat <<-EOF
log:
  loglevel: error
inbounds:
  - port: ${port}
    protocol: vless
    settings:
      clients:
        - id: "${uuid}"
          flow: xtls-rprx-vision
      decryption: none
    streamSettings:
      network: tcp
      security: reality
      realitySettings:
        show: false
        minClientVer: "0.0.0"
        dest: "${domain}:${reality_dest_port}"
        xver: 0
        serverNames: ["${domain}"]
        privateKey: "${private_key}"
        shortIds: ["${shortid}"]
        limitFallbackUpload:
          afterBytes: 0
          bytesPerSec: ${fallback_bytes_per_sec}
          burstBytesPerSec: ${fallback_burst_bytes_per_sec}
        limitFallbackDownload:
          afterBytes: 0
          bytesPerSec: ${fallback_bytes_per_sec}
          burstBytesPerSec: ${fallback_burst_bytes_per_sec}
    sniffing:
      enabled: true
      destOverride: [http, tls, quic]
      routeOnly: true
outbounds:
  - ${default_outbound_json}
  - protocol: freedom
    streamSettings:
      sockopt:
        domainStrategy: ForceIPv4
    tag: force_ipv4
  - protocol: freedom
    streamSettings:
      sockopt:
        domainStrategy: ForceIPv6
    tag: force_ipv6
  - tag: warp_out
    protocol: socks
    settings:
      servers:
        - address: "127.0.0.1"
          port: 40000
  - protocol: blackhole
    tag: block
dns:
  servers: ${dns_servers_json}
  queryStrategy: "${dns_query_strategy}"
routing:
  domainStrategy: IPIfNonMatch
  rules:
    # Add custom routing rules above the default block rules.
    - type: field
      ip: ["geoip:private", "geoip:cn"]
      outboundTag: block
    - type: field
      outboundTag: block
      protocol: [bittorrent]
EOF
    )
    if [[ "$mldsa_enabled" -eq 1 ]]; then
        reality_template="$(printf '%s\n' "$reality_template" | sed '/privateKey:/a\        mldsa65Seed: "'"$mldsa65Seed"'"')"
    fi
    if [[ -n "$socks_inbound_json" ]]; then
        require_xray_yaml_tool || return 1
        local socks_yaml=""
        socks_yaml="$(printf '%s\n' "$socks_inbound_json" | "$xray_yaml_tool_path" -p=json -o=yaml '.' -)" || return 1
        local socks_entry=""
        socks_entry="$(printf '%s\n' "$socks_yaml" | sed '1s/^/  - /; 2,$s/^/    /')"
        reality_template="${reality_template/outbounds:/$socks_entry
outbounds:}"
    fi
    local config_path="$xray_config_path"
    local config_dir=""
    task_start "快好了，手搓 / Configuring $config_path"

    config_dir=$(dirname "$config_path")

    if [[ ! -d "$config_dir" ]]; then
        if ! mkdir -p "$config_dir"; then
            task_fail
            error "创建配置目录失败: $config_dir / Failed to create config directory: $config_dir"
            exit 1
        fi
    fi

    pending_xray_config="$(mktemp "${config_path}.stage.XXXXXX")" || return 1
    if ! printf '%s\n' "$reality_template" > "$pending_xray_config"; then
        rm -f "$pending_xray_config"
        pending_xray_config=""
        task_fail
        return 1
    fi
    chmod 600 "$pending_xray_config" || return 1
    log_info "event=config_staged preferred=ipv${default_route_choice} dns_query=${dns_query_strategy}"
    task_done
}

# Egress is independent of the address family used by clients to reach this VPS.
detect_egress_network() {
    egress_ipv4_available=0
    egress_ipv6_available=0
    local family=""
    local route_ok=1
    for family in 4 6; do
        route_ok=1
        if command -v ip >/dev/null 2>&1; then
            if [[ "$family" == 4 ]]; then
                ip -4 route get 1.1.1.1 >/dev/null 2>&1 || route_ok=0
            else
                ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1 || route_ok=0
            fi
        fi
        [[ "$route_ok" -eq 1 ]] || continue
        if curl "-${family}" -fsS --noproxy '*' --connect-timeout 2 --max-time 4 \
                https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1 ||
           curl "-${family}" -fsS --noproxy '*' --connect-timeout 2 --max-time 4 \
                https://api64.ipify.org >/dev/null 2>&1; then
            if [[ "$family" == 4 ]]; then egress_ipv4_available=1; else egress_ipv6_available=1; fi
        fi
    done
    [[ "$egress_ipv4_available" -eq 1 || "$egress_ipv6_available" -eq 1 ]]
}

select_default_route() {
    local selection=""
    if [[ -z "$default_route_choice" ]] && ! { exec 3</dev/tty; } 2>/dev/null; then
        display_result "需要交互终端；自动化请用 --default-route=4|6 / A terminal is required; use --default-route=4|6 for automation." >&2
        return 1
    fi
    if [[ -z "$egress_ipv4_available" || -z "$egress_ipv6_available" ]]; then
        detect_egress_network || {
            exec 3<&-
            display_result "没有可用出口 / No reachable IPv4 or IPv6 egress." >&2
            return 1
        }
    fi
    if [[ -z "$default_route_choice" ]]; then
        while true; do
            display_result "选择默认出口 / Default egress"
            if [[ "$egress_ipv4_available" -eq 1 ]]; then
                display_result "1) IPv4 优先 / Prefer IPv4"
            else
                display_result "1) IPv4 不可用 / IPv4 unavailable"
            fi
            if [[ "$egress_ipv6_available" -eq 1 ]]; then
                display_result "2) IPv6 优先 / Prefer IPv6"
            else
                display_result "2) IPv6 不可用 / IPv6 unavailable"
            fi
            display_result "0) 取消 / Cancel"
            printf '选择 / Select: '
            if ! read -r selection <&3; then exec 3<&-; return 2; fi
            case "$selection" in
                0) exec 3<&-; return 2 ;;
                1) [[ "$egress_ipv4_available" -eq 1 ]] && { default_route_choice=4; break; } ;;
                2) [[ "$egress_ipv6_available" -eq 1 ]] && { default_route_choice=6; break; } ;;
            esac
            display_result "无效或不可用的出口 / Invalid or unavailable egress." >&2
        done
        exec 3<&-
    fi
    case "$default_route_choice" in
        4) [[ "$egress_ipv4_available" -eq 1 ]] && return 0 ;;
        6) [[ "$egress_ipv6_available" -eq 1 ]] && return 0 ;;
    esac
    display_result "所选出口不可用 / Selected egress is not reachable." >&2
    return 1
}

build_default_route_settings() {
    # Template-only callers may already supply interface detection results.
    if [[ -z "$egress_ipv4_available" ]]; then
        egress_ipv4_available=0
        [[ -n "${IPv4:-}" ]] && egress_ipv4_available=1
    fi
    if [[ -z "$egress_ipv6_available" ]]; then
        egress_ipv6_available=0
        [[ -n "${IPv6:-}" ]] && egress_ipv6_available=1
    fi
    if [[ -z "$default_route_choice" ]]; then
        default_route_choice=4
        [[ "$egress_ipv4_available" -eq 1 ]] || default_route_choice=6
    fi
    case "$default_route_choice" in
        4) [[ "$egress_ipv4_available" -eq 1 ]] || return 1 ;;
        6) [[ "$egress_ipv6_available" -eq 1 ]] || return 1 ;;
        *) return 1 ;;
    esac
    local prioritize_ipv6=false
    [[ "$default_route_choice" == 6 ]] && prioritize_ipv6=true
    dns_query_strategy=UseIP
    if [[ "$egress_ipv4_available" -eq 0 ]]; then
        dns_query_strategy=UseIPv6
    elif [[ "$egress_ipv6_available" -eq 0 ]]; then
        dns_query_strategy=UseIPv4
    fi
    local v4='"1.1.1.1","8.8.8.8"'
    local v6='"2606:4700:4700::1111","2001:4860:4860::8888"'
    if [[ "$egress_ipv4_available" -eq 1 && "$egress_ipv6_available" -eq 1 ]]; then
        if [[ "$default_route_choice" == 6 ]]; then dns_servers_json="[$v6,$v4,\"localhost\"]"; else dns_servers_json="[$v4,$v6,\"localhost\"]"; fi
    elif [[ "$egress_ipv4_available" -eq 1 ]]; then
        dns_servers_json="[$v4,\"localhost\"]"
    else
        dns_servers_json="[$v6,\"localhost\"]"
    fi
    default_outbound_json="{\"tag\":\"direct\",\"protocol\":\"freedom\",\"streamSettings\":{\"sockopt\":{\"domainStrategy\":\"UseIP\",\"happyEyeballs\":{\"tryDelayMs\":250,\"prioritizeIPv6\":${prioritize_ipv6},\"interleave\":1,\"maxConcurrentTry\":4}}}}"
}

apply_default_route_patch() {
    build_default_route_settings || return 1
    # Do not override a custom proxy/bind/chained-egress policy implicitly.
    if ! jq -e '
        (.outbounds | type == "array" and length > 0) and
        (.outbounds[0].protocol == "freedom") and
        (([.outbounds[] | select(.tag == "direct")] | length) <= 1) and
        ((.outbounds[0].tag // "") as $first |
            ($first == "direct" or $first == "force_ipv4" or $first == "force_ipv6" or
             ([.outbounds[] | select(.tag == "direct")] | length) == 0)) and
        (all(.outbounds[]; (.tag != "direct") or .protocol == "freedom")) and
        ((.outbounds[0].sendThrough // "0.0.0.0") == "0.0.0.0") and
        ((.outbounds[0].streamSettings.sockopt.dialerProxy // "") == "") and
        ((.outbounds[0].proxySettings.tag // "") == "") and
        (all(.outbounds[] | select(.tag == "direct");
            ((.sendThrough // "0.0.0.0") == "0.0.0.0") and
            ((.streamSettings.sockopt.dialerProxy // "") == "") and
            ((.proxySettings.tag // "") == "")))
        ' "$patch_jq_source" >/dev/null 2>&1; then
        error "默认出站存在自定义代理或绑定策略，无法安全修改 / Custom default proxy or bind policy prevents a safe egress change."
        return 1
    fi
    jq --argjson preferred "$default_outbound_json" --argjson servers "$dns_servers_json" --arg query "$dns_query_strategy" '
        .outbounds as $original |
        ($original[0].tag // "") as $firstTag |
        (if ($original | any(.tag == "direct")) then
            ($original[] | select(.tag == "direct"))
         elif ($firstTag == "force_ipv4" or $firstTag == "force_ipv6") then $preferred
         else $original[0] end) as $base |
        ($base | (if .settings.domainStrategy? != null then .settings.domainStrategy = "AsIs" else . end) |
            .streamSettings.sockopt.domainStrategy = "UseIP" |
            .streamSettings.sockopt.happyEyeballs = $preferred.streamSettings.sockopt.happyEyeballs) as $default |
        .outbounds = ([$default] + [$original[] |
            select(if ($original | any(.tag == "direct")) then .tag != "direct"
                   elif ($firstTag == "force_ipv4" or $firstTag == "force_ipv6") then true
                   else . != $original[0] end)]) |
        .dns.queryStrategy = $query |
        .dns.servers = (($servers + (.dns.servers // [])) | reduce .[] as $server ([]; if index($server) == null then . + [$server] else . end))
        ' "$patch_jq_source" > "$patch_tmp_out" 2>>"$LOG_FILE"
}

collect_xray_diagnostics() {
    configure_xray_service_identity
    local diagnostic=""
    if [[ "${ID:-}" == alpine || "${ID_LIKE:-}" == alpine ]]; then
        diagnostic="$(rc-service "$runtime_xray_service_alpine" status 2>&1 | tail -n 30)"
    else
        diagnostic="$(journalctl -u "$runtime_xray_service" -n 40 --since '2 minutes ago' --no-pager -o cat 2>&1 | tail -n 40)"
    fi
    printf '%s\n' "$diagnostic" | sanitize_log_stream | while IFS= read -r line; do
        log_event ERROR "event=service_diagnostic $line"
    done
}

restart_xray_service() {
    configure_xray_service_identity
    task_start "启动并检查Xray / Start and check Xray"
    normalize_xray_runtime_permissions "$xray_config_path" || { task_fail; return 1; }
    if [[ "${ID:-}" == alpine || "${ID_LIKE:-}" == alpine ]]; then
        run_logged service_restart rc-service "$runtime_xray_service_alpine" restart || { task_fail; collect_xray_diagnostics; return 1; }
    else
        run_logged service_restart systemctl restart "$runtime_xray_service" || { task_fail; collect_xray_diagnostics; return 1; }
    fi
    local attempt=0
    while [[ "$attempt" -lt 3 ]]; do
        if xray_service_is_active; then task_done; return 0; fi
        attempt=$((attempt + 1))
        sleep 1
    done
    task_fail
    collect_xray_diagnostics
    return 1
}

commit_xray_config() {
    local staged="$1"
    local target="$xray_config_path"
    local backup=""
    local restore_stage=""
    if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) || -L "$staged" || ! -f "$staged" ]]; then
        error "配置目标不安全或暂存配置缺失 / Unsafe config target or missing staged config."
        return 1
    fi
    case "$target" in
        *.yaml|*.yml)
            if jq empty "$staged" >/dev/null 2>&1; then
                local yaml_stage=""
                yaml_stage="$(mktemp "${target}.stage.XXXXXX")" || return 1
                if ! xray_json_to_config "$staged" "$yaml_stage" "$target"; then
                    rm -f "$yaml_stage"
                    return 1
                fi
                rm -f "$staged"
                staged="$yaml_stage"
            fi
            ;;
    esac
    chmod 600 "$staged" || return 1
    local config_format="json"
    case "$target" in *.yaml|*.yml) config_format="yaml" ;; esac
    if ! run_logged config_validate xray run -test -format "$config_format" -c stdin: < "$staged"; then
        error "Xray配置校验失败，原配置已保留 / Configuration validation failed; original configuration preserved."
        rm -f "$staged"
        return 1
    fi
    if [[ -f "$target" ]]; then
        backup="$(mktemp "${target}.backup.XXXXXX")" || return 1
        if ! cat "$target" > "$backup" || ! chmod 600 "$backup"; then rm -f "$backup"; return 1; fi
        last_config_backup="$backup"
        log_info "event=config_backup path=$backup"
    fi
    # Move only a same-filesystem temporary file into place.
    if [[ "$(dirname "$staged")" != "$(dirname "$target")" ]]; then
        restore_stage="$(mktemp "${target}.stage.XXXXXX")" || return 1
        if ! cat "$staged" > "$restore_stage"; then rm -f "$restore_stage"; return 1; fi
        rm -f "$staged"
        staged="$restore_stage"
    fi
    chmod 600 "$staged" || return 1
    if ! mv -f "$staged" "$target"; then return 1; fi
    if restart_xray_service; then
        log_info "event=config_applied preferred=ipv${default_route_choice:-unchanged}"
        return 0
    fi
    log_event ERROR "event=config_apply_failed rollback_required=1"
    if [[ -n "$backup" ]]; then
        restore_stage="$(mktemp "${target}.rollback.XXXXXX")" || return 1
        if cat "$backup" > "$restore_stage" && chmod 600 "$restore_stage" && mv -f "$restore_stage" "$target" && restart_xray_service; then
            log_event WARN "event=config_rollback status=success backup=$backup"
            error "应用失败，已恢复原配置 / Apply failed; previous configuration restored."
        else
            rm -f "$restore_stage"
            log_event ERROR "event=config_rollback status=failed backup=$backup"
            error "恢复配置后服务未就绪，请检查日志 / Service is not ready after rollback; check the log."
        fi
    else
        rm -f "$target"
        log_event ERROR "event=config_rollback status=no_previous_config"
    fi
    return 1
}

configure_xray() {
    if [[ $keepconfig -eq 1 ]]; then
        initialize_ip_from_netstack
        load_runtime_vars_from_existing_config
        configure_xray_journald_logging || return 1
    else
        if [[ -z "$egress_ipv4_available" || -z "$egress_ipv6_available" ]]; then
            detect_egress_network || { error "没有可用出口 / No reachable egress."; return 1; }
        fi
        initialize_variables
        generate_crypto
        if [[ "$addsocks_mode" -eq 1 ]]; then
            task_start "生成SOCKS5入站 / Generate SOCKS5 inbound"
            prepare_socks_inbound || { task_fail; return 1; }
            task_done_with_info "port=${socks_port}"
        fi
        build_xray_config || return 1
        commit_xray_config "$pending_xray_config" || return 1
        pending_xray_config=""
    fi
}


# ---- Patch modes (--add-limiter / --change-sni / --addsocks) ----

# Resolve the jq-parseable view of the existing config: the config itself when
# it is pure JSON, or a comment-stripped temp copy otherwise. Sets
# $patch_jq_source to the path to read from; records a temp file in
# $patch_cleanup (if any) for the caller to remove.
resolve_jq_config_source() {
    local config_path="$xray_config_path"
    if [[ ! -f "$config_path" && -f "/usr/local/etc/xray/config.json" ]]; then
        config_path="/usr/local/etc/xray/config.json"
        xray_config_path="/usr/local/etc/xray/config.json"
    fi
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
            if ! xray_config_to_json "$config_path" "$patch_cleanup"; then
                rm -f "$patch_cleanup"
                patch_cleanup=""
                return 1
            fi
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
    sed -E 's@^[[:space:]]*//.*$@@; s@[[:space:]]+//.*$@@' "$config_path" > "$patch_cleanup"
    if ! jq empty "$patch_cleanup" >/dev/null 2>&1; then
        rm -f "$patch_cleanup"
        patch_cleanup=""
        error "配置文件格式无效 / Invalid config format in $config_path."
        return 1
    fi
    patch_jq_source="$patch_cleanup"
}

configure_xray_journald_logging() {
    local journald_tmp=""

    if ! resolve_jq_config_source; then
        return 1
    fi

    journald_tmp="$(mktemp /tmp/nokey-config-journald.XXXXXX)" || {
        error "创建journald配置临时文件失败 / Failed to create temporary file for journald config."
        rm -f "$patch_cleanup"
        return 1
    }

    if ! jq 'del(.log.access, .log.error)' "$patch_jq_source" > "$journald_tmp" 2>>"$LOG_FILE"; then
        error "移除Xray文件日志配置失败，请查看$LOG_FILE / Failed to remove Xray file logging. Check $LOG_FILE."
        rm -f "$journald_tmp" "$patch_cleanup"
        return 1
    fi

    if ! commit_xray_config "$journald_tmp"; then
        error "写入journald配置失败: $xray_config_path / Failed to write journald config to $xray_config_path."
        rm -f "$journald_tmp" "$patch_cleanup"
        return 1
    fi

    [[ -n "$patch_cleanup" ]] && rm -f "$patch_cleanup"
    patch_cleanup=""
    log_info "Configured Xray logging for systemd journal"
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

    # Xray password-auth entries use "users".
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
    display_result "$proxy_url"
    info "SOCKS5测试命令 / SOCKS5 test command:"
    display_result "$curl_command"
    echo "$proxy_url" >> "${share_output_file:-$URL_FILE}"
    echo "$curl_command" >> "${share_output_file:-$URL_FILE}"
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

    if [[ "$addsocks_mode" -ne 1 && "$default_route_mode" -ne 1 ]] && ! jq -e '.inbounds[0].streamSettings.realitySettings' "$patch_jq_source" >/dev/null 2>&1; then
        task_fail
        error "配置中没有REALITY设置，无法修补 / No REALITY settings found in config; cannot patch."
        rm -f "$patch_cleanup"
        exit 1
    fi

    patch_tmp_out="$(mktemp "${xray_config_path}.stage.XXXXXX")" || {
        task_fail
        error "创建临时文件失败 / Failed to create temporary file."
        exit 1
    }

    if [[ "$default_route_mode" -eq 1 ]]; then
        apply_default_route_patch || { task_fail; rm -f "$patch_tmp_out" "$patch_cleanup"; return 1; }
    elif [[ "$add_limiter_mode" -eq 1 ]]; then
        add_limiter_to_existing_config || { task_fail; rm -f "$patch_tmp_out" "$patch_cleanup"; exit 1; }
    elif [[ "$change_sni_mode" -eq 1 ]]; then
        change_sni_in_existing_config || { task_fail; rm -f "$patch_tmp_out" "$patch_cleanup"; exit 1; }
    elif [[ "$addsocks_mode" -eq 1 ]]; then
        add_socks_to_existing_config || { task_fail; rm -f "$patch_tmp_out" "$patch_cleanup"; exit 1; }
    fi

    # Preserve runtime logging policy except the legacy file sinks, then commit once.
    local clean_stage=""
    clean_stage="$(mktemp "${xray_config_path}.stage.XXXXXX")"
    if [[ -z "$clean_stage" ]] || ! jq 'del(.log.access, .log.error)' "$patch_tmp_out" > "$clean_stage"; then
        rm -f "$patch_tmp_out" "$patch_cleanup" "$clean_stage"
        return 1
    fi
    rm -f "$patch_tmp_out" "$patch_cleanup"
    patch_cleanup=""
    commit_xray_config "$clean_stage" || return 1
    task_done
    if [[ "$default_route_mode" -eq 1 ]]; then
        info "默认出口 / Default egress: IPv${default_route_choice} 优先 / preferred"
        info "配置备份 / Backup: $last_config_backup"
        return 0
    fi

    if [[ "$addsocks_mode" -eq 1 ]]; then
        output_socks_proxy
        return 0
    fi

    # Regenerate links from the patched config so SNI/limiter changes are reflected.
    initialize_ip_from_netstack
    load_runtime_vars_from_existing_config
    output_results || return 1
}


# ---- Realm functions ----

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
    run_logged download curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/${arch_binary_name}" -o /usr/local/bin/realm || { task_fail; error "下载${arch_binary_name}失败 / Failed to download ${arch_binary_name}"; exit 1; }
    chmod 755 /usr/local/bin/realm

    local realm_rc_tmp
    local realm_service_tmp
    realm_rc_tmp="$(mktemp /tmp/nokey.realm.rc.XXXXXX)" || { task_fail; error "创建realm.rc临时文件失败 / Failed to create temporary file for realm.rc"; exit 1; }
    realm_service_tmp="$(mktemp /tmp/nokey.realm.service.XXXXXX)" || { task_fail; error "创建realm.service临时文件失败 / Failed to create temporary file for realm.service"; exit 1; }

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        log_info "安装OpenRC服务 / Installing OpenRC service: /etc/init.d/${REALM_SERVICE_NAME_ALPINE}"
        log_verbose "Downloading service file: ${GITHUB_REALM_RC_URL} -> ${realm_rc_tmp}"
        run_logged download curl -fSL "${GITHUB_REALM_RC_URL}" -o "${realm_rc_tmp}" || { task_fail; error "下载realm.rc失败 / Failed to download realm.rc"; exit 1; }
        configure_openrc_crash_restart "${realm_rc_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "配置realm崩溃自动重启失败 / Failed to configure realm crash restart"; exit 1; }
        install -m 755 "${realm_rc_tmp}" /etc/init.d/"$REALM_SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "安装/etc/init.d/$REALM_SERVICE_NAME_ALPINE失败 / Failed to install /etc/init.d/$REALM_SERVICE_NAME_ALPINE"; exit 1; }
        rm -f "${realm_rc_tmp}" >> "$LOG_FILE" 2>&1
        log_verbose "Installed OpenRC service file from realm.rc"
        rc-update add "$REALM_SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用OpenRC服务$REALM_SERVICE_NAME_ALPINE失败 / Failed to enable OpenRC service $REALM_SERVICE_NAME_ALPINE"; exit 1; }
    else
        log_info "安装systemd服务 / Installing systemd service: /etc/systemd/system/${REALM_SERVICE_NAME}"
        log_verbose "Downloading service file: ${GITHUB_REALM_SERVICE_URL} -> ${realm_service_tmp}"
        run_logged download curl -fSL "${GITHUB_REALM_SERVICE_URL}" -o "${realm_service_tmp}" || { task_fail; error "下载realm.service失败 / Failed to download realm.service"; exit 1; }
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
    log_info "event=realm_config_written path=$realm_config"
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
show_help() {
  display_result "当前版本 / Version: ${cyan}${SCRIPT_VERSION}${none} "
  display_result "使用方法: $0 [options] / Usage"
  display_result "选项: / Options"
  display_result "  --netstack=4|6     连接地址使用IPv4或IPv6 / Inbound share address family"
  display_result "  --default-route   菜单选择默认出口 / Choose preferred IPv4 or IPv6 egress"
  display_result "  --default-route=4|6  非交互选择默认出口 / Set preferred egress without a menu"
  display_result "  --port=NUMBER      设置端口号 (默认: 随机) / Set port number"
  display_result "  --domain=DOMAIN    设置SNI域名 (默认: www.amd.com) / Set SNI domain"
  display_result "  --uuid=STRING      设置UUID (默认: 自动生成) / Set UUID"
  display_result "  --mldsa            启用ML-DSA签名生成 (默认: 关闭) / Enable ML-DSA signature generation (default: off)"
  display_result "  --mldsa65Seed=STRING  设置ML-DSA-65私钥 (默认: 自动生成) / Set ML-DSA-65 private key"
  display_result "  --mldsa65Verify=STRING  设置ML-DSA-65公钥 (默认: 自动生成) / Set ML-DSA-65 public key"
  display_result "  --caddy            从运行的Caddy服务自动检测域名和端口 / Detect domain and port from Caddy service"
  display_result "  --keepconfig       保留现有配置并从中生成输出链接 / Keep existing Xray config and generate links from it"
  display_result "  --add-limiter      为现有配置添加REALITY回落限速(独立模式, 不能与其他参数连用) / Add REALITY fallback rate limit to existing config (standalone, no other flags)"
  display_result "  --change-sni       仅更换现有配置的REALITY SNI(独立模式, 不能与其他参数连用) / Re-randomize the REALITY SNI in existing config (standalone, no other flags)"
  display_result "  --addsocks         添加随机端口和凭据的SOCKS5入站；Xray运行时仅修补现有配置 / Add a SOCKS5 inbound with random port and credentials; patch only when Xray is running"
  display_result "  --force            强制重装 / Force Reinstall"
   display_result "  --realm            额外安装Realm转发代理 (与 --remote 搭配) / Also install Realm relay proxy alongside Xray (use with --remote)"
   display_result "  --realm-only      仅安装Realm转发代理 (不安装Xray, 与 --remote 搭配) / Install Realm relay proxy only (without Xray, use with --remote)"
  display_result "  --remote=ADDRESS   设置Realm远程地址 (必填, 格式 host:port) / Set Realm remote address (required, format host:port)"
  display_result "  --listen=ADDRESS   设置Realm监听地址 (可选, 默认派生自远程端口) / Set Realm listen address (optional, defaults to remote port on any address)"
  display_result "  --remove           卸载Xray (和已安装的Realm) 与NoKey / Uninstall Xray (and Realm if installed) and NoKey"
  display_result "  --dry-run          仅预览安装动作，不写入系统 / Preview actions only"
  display_result "  --menu             打开其他功能菜单 / Open the feature menu"
  display_result "  --help             显示此帮助信息 / Show this help message"

  exit "${1:-0}"
}

dry_run_preview() {
    task_start "预览安装流程 / Dry Run"
    if [[ "$default_route_mode" -eq 1 ]]; then
        build_default_route_settings || return 1
        info "默认出口 / Default egress: IPv${default_route_choice} 优先 / preferred"
        info "DNS queryStrategy=${dns_query_strategy} servers=${dns_servers_json}"
    fi

    local os_family
    os_family="$(resolve_os_family)"

    info "预览模式：不会对系统做任何实际更改 / Dry run mode enabled: no file/service/system changes will be made."
    log_verbose "DRY RUN | OS=${os_family}"

    if [[ $realm_mode -eq 1 ]]; then
        local realm_arch_name=""
        realm_arch_name="$(resolve_realm_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }
        info "${green}=== Realm 转发代理 / Realm Relay Proxy ===${none}"
        if [[ $realm_only -eq 1 ]]; then
            info "模式: 仅Realm (不安装Xray) / Mode: Realm only (no Xray)"
        fi
        if [[ "$realm_arch_name" == *musl* ]]; then
            info "链接: musl (Alpine兼容) / Link: musl (Alpine-compatible)"
        fi
        info "远程地址 / Remote: ${cyan}${realm_remote}${none}"
        if [[ -n "$realm_listen" ]]; then
            info "监听地址 / Listen: ${cyan}${realm_listen}${none}"
        else
            info "监听地址 / Listen: ${cyan}(自动派生自远程端口)${none}"
        fi

        info "将创建目录 / Would create directories:"
        info "  ${REALM_CONFIG_DIR}"

        info "将下载文件 / Would download files:"
        info "  ${GITHUB_RELEASE_BASE_URL}/${realm_arch_name} -> /usr/local/bin/realm"

        info "将设置权限 / Would set permission:"
        info "  chmod 755 /usr/local/bin/realm"

        if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            info "将安装服务(OpenRC) / Would install service (OpenRC):"
            info "  ${GITHUB_REALM_RC_URL} -> /tmp/nokey.realm.rc.<pid>"
            info "  /tmp/nokey.realm.rc.<pid> -> /etc/init.d/${REALM_SERVICE_NAME_ALPINE}"
            info "  rc-update add ${REALM_SERVICE_NAME_ALPINE}"
        else
            info "将安装服务(systemd) / Would install service (systemd):"
            info "  ${GITHUB_REALM_SERVICE_URL} -> /tmp/nokey.realm.service.<pid>"
            info "  /tmp/nokey.realm.service.<pid> -> /etc/systemd/system/${REALM_SERVICE_NAME}"
            info "  systemctl daemon-reload"
            info "  systemctl enable ${REALM_SERVICE_NAME}"
        fi

        info "将写入配置 / Would write config:"
        info "  ${REALM_CONFIG_DIR}/config.json"
        info ""
    fi

    info "${green}=== Xray (VLESS Reality) ===${none}"
    if [[ $realm_only -eq 1 ]]; then
        info "跳过Xray安装: --realm-only 模式 / Skipping Xray: --realm-only mode"
        task_done
        return
    fi

    local arch_binary_name=""
    local arch_name=""
    arch_binary_name="$(resolve_arch_binary_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }
    arch_name="$(resolve_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }

    info "检测到系统 / Detected OS: ${os_family} | 架构 / Architecture: ${arch_name}"

    info "将创建目录 / Would create directories:"
    info "  /usr/local/bin"
    info "  /usr/local/share/xray"
    info "  ${NOKEY_CONFIG_DIR}"

    info "将下载文件 / Would download files:"
    info "  ${GITHUB_RELEASE_BASE_URL}/${arch_binary_name} -> /usr/local/bin/xray"
    info "  ${GITHUB_RELEASE_BASE_URL}/geoip.dat -> /usr/local/share/xray/geoip.dat"
    info "  ${GITHUB_RELEASE_BASE_URL}/geosite.dat -> /usr/local/share/xray/geosite.dat"
    if [[ "$xray_config_path" == *.yaml || "$xray_config_path" == *.yml ]] &&
       ! xray_yq_is_compatible "$NOKEY_YQ_INSTALL_PATH" &&
       ! xray_yq_is_compatible "$(command -v yq 2>/dev/null || true)"; then
        info "  https://github.com/mikefarah/yq/releases/download/${NOKEY_YQ_VERSION}/yq_$(uname -s | tr '[:upper:]' '[:lower:]')_${arch_name} -> ${NOKEY_YQ_INSTALL_PATH} (SHA-256 verified)"
    fi

    info "将设置权限 / Would set permission:"
    info "  chmod 755 /usr/local/bin/xray"

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        info "将安装服务(OpenRC) / Would install service (OpenRC):"
        info "  ${GITHUB_NOKEY_RC_URL} -> /tmp/nokey.rc.<pid>"
        info "  /tmp/nokey.rc.<pid> -> /etc/init.d/${SERVICE_NAME_ALPINE}"
        info "  rc-update add ${SERVICE_NAME_ALPINE}"
        info "  rc-service ${SERVICE_NAME_ALPINE} restart (after config generation)"
    else
        info "将安装服务(systemd) / Would install service (systemd):"
        info "  ${GITHUB_NOKEY_SERVICE_URL} -> /tmp/nokey.service.<pid>"
        info "  /tmp/nokey.service.<pid> -> /etc/systemd/system/${SERVICE_NAME}"
        info "  systemctl daemon-reload"
        info "  systemctl enable ${SERVICE_NAME}"
        info "  systemctl restart ${SERVICE_NAME} (after config generation)"
    fi

    if [[ $keepconfig -eq 1 ]]; then
        info "将保留现有配置 / Would keep existing config:"
        info "  ${xray_config_path}"
        info "将解析现有配置以生成输出链接 / Would parse existing config for URL output variables."
    else
        info "将写入配置 / Would write config:"
        info "  ${xray_config_path}"
    fi

    task_done
}


check_service_status() {
    task_start "检查服务状态 / Check service"
    if [[ "$realm_mode" -eq 1 ]]; then
        if [[ "${ID:-}" == alpine || "${ID_LIKE:-}" == alpine ]]; then
            if ! run_logged realm_status rc-service "$REALM_SERVICE_NAME_ALPINE" status; then task_fail; return 1; fi
        elif ! systemctl is-active --quiet "$REALM_SERVICE_NAME"; then
            task_fail
            run_logged realm_status systemctl status --no-pager "$REALM_SERVICE_NAME" || true
            return 1
        fi
    fi
    if [[ "$realm_only" -ne 1 ]] && ! xray_service_is_active; then
        task_fail
        collect_xray_diagnostics
        error "Xray服务未运行 / Xray service is not active."
        return 1
    fi
    task_done
}

generate_share_links() {
    if [[ $netstack == "6" && "$ip" != \[*\] ]]; then
      ip="[$ip]"
    fi

    vless_reality_url_short="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}#${current_hostname}"

    info "分享链接 / Share Link:"

    if [[ $mldsa_enabled == 1 ]]; then
      vless_reality_mldsa_url="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}&pqv=${mldsa65Verify}#${current_hostname}"
      display_result "${vless_reality_mldsa_url}"
      echo "$vless_reality_mldsa_url" >> "${share_output_file:-$URL_FILE}"
      info "不含mldsa / Without mldsa:"
      display_result "${vless_reality_url_short}"
      echo "$vless_reality_url_short" >> "${share_output_file:-$URL_FILE}"
    else
      display_result "${vless_reality_url_short}"
      echo "$vless_reality_url_short" >> "${share_output_file:-$URL_FILE}"
    fi
}

generate_clash_config() {
    local server_ip_for_clash=$ip
    if [[ $netstack == "6" ]]; then
        # for clash meta, ipv6 does not need bracket.
        # The ip var is already bracketed for vless url.
        server_ip_for_clash=${ip#\[}
        server_ip_for_clash=${server_ip_for_clash%\]}
    fi

    clash_meta_config=$(cat <<-EOF
- name: ${current_hostname}
  type: vless
  server: ${server_ip_for_clash}
  port: ${port}
  client-fingerprint: ${fingerprint}
  tls: true
  servername: ${domain}
  flow: xtls-rprx-vision
  network: tcp
  reality-opts:
    public-key: ${public_key}
    short-id: ${shortid}
    support-x25519mlkem768: true
  uuid: ${uuid}
EOF
)
    info "Clash.meta 配置 / Clash.meta config:"
    display_result "${clash_meta_config}"
    echo "$clash_meta_config" >> "${share_output_file:-$URL_FILE}"
}

# Emit an extra IPv6 share URL + clash entry when the box is dual-stack but the
# primary netstack is IPv4. The main links above already cover the primary IP.
generate_ipv6_variants() {
    [[ $netstack == "4" && -n "${IPv6:-}" ]] || return 0

    local ipv6_link
    ipv6_link="vless://${uuid}@[${IPv6}]:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}#${current_hostname}-ipv6"
    info "分享链接 (IPv6) / Share Link (IPv6):"
    display_result "${ipv6_link}"
    echo "$ipv6_link" >> "${share_output_file:-$URL_FILE}"

    local ipv6_clash
    ipv6_clash=$(cat <<-EOF
- name: ${current_hostname}-ipv6
  type: vless
  server: ${IPv6}
  port: ${port}
  client-fingerprint: ${fingerprint}
  tls: true
  servername: ${domain}
  flow: xtls-rprx-vision
  network: tcp
  reality-opts:
    public-key: ${public_key}
    short-id: ${shortid}
    support-x25519mlkem768: true
  uuid: ${uuid}
EOF
)
    info "Clash.meta 配置 (IPv6) / Clash.meta config (IPv6):"
    display_result "${ipv6_clash}"
    echo "$ipv6_clash" >> "${share_output_file:-$URL_FILE}"
}

output_results() {
    # Chrome offers the ML-KEM key share required by current REALITY servers.
    fingerprint="chrome"
    check_service_status || return 1
    if [[ "$realm_only" -eq 1 ]]; then
        print_service_commands "$REALM_SERVICE_NAME" "$REALM_SERVICE_NAME_ALPINE"
        return
    fi
    separator
    display_result "Xray VLESS REALITY" "$green"
    display_result "IP:Port → ${ip}:${port}"
    display_result "UUID → ${uuid}"
    separator
    generate_share_links
    generate_clash_config
    generate_ipv6_variants
    if [[ "$addsocks_mode" -eq 1 ]]; then
        output_socks_proxy
    fi
    info "连接信息 / Connection details: $URL_FILE"
    info "日志 / Log: $LOG_FILE"
    print_service_commands "$runtime_xray_service" "$runtime_xray_service_alpine"
}


# Main function
main() {
    SECONDS=0
    local xray_active=0
    local route_status=0
    parse_args "$@" || return 1
    if [[ "$xray_config_path" == "$NOKEY_CONFIG_FILE" && ! -f "$xray_config_path" && -f "${NOKEY_CONFIG_DIR}/nokey.json" ]]; then
        xray_config_path="${NOKEY_CONFIG_DIR}/nokey.json"
    fi
    if [[ "$keepconfig" -eq 1 || "$add_limiter_mode" -eq 1 || "$change_sni_mode" -eq 1 || "$addsocks_mode" -eq 1 || "$default_route_mode" -eq 1 ]]; then
        if [[ ! -f "$xray_config_path" && -f /usr/local/etc/xray/config.json ]]; then
            xray_config_path=/usr/local/etc/xray/config.json
        fi
    fi
    configure_xray_service_identity
    if [[ "$menu_mode" -eq 1 ]]; then show_feature_menu; return $?; fi
    if [[ "$default_route_mode" -eq 1 ]]; then
        if [[ ! -f "$xray_config_path" && -f /usr/local/etc/xray/config.json ]]; then
            xray_config_path=/usr/local/etc/xray/config.json
        fi
        if [[ -f "$xray_config_path" && "$arg_count" -gt 1 && ! ( "$arg_count" -eq 2 && "$dry_run" -eq 1 ) ]]; then
            display_result "已有配置时--default-route须单独使用 / Use --default-route alone for an existing config." >&2
            return 1
        fi
        select_default_route || route_status=$?
        [[ "$route_status" -eq 2 ]] && return 0
        [[ "$route_status" -eq 0 ]] || return "$route_status"
    fi
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    elif [[ "$dry_run" -ne 1 ]]; then
        display_result "无法识别的OS / Cannot determine OS." >&2
        return 1
    fi
    if [[ "$dry_run" -eq 1 ]]; then
        detect_network_interfaces
        initialize_ip_from_netstack
        dry_run_preview || return 1
        return 0
    fi
    check_root || return 1
    init_output_files preserve-shares || return 1
    if [[ "$remove_mode" -ne 1 && "$realm_only" -ne 1 &&
          ! ( "$default_route_mode" -eq 1 && -f "$xray_config_path" ) ]]; then
        begin_share_output || return 1
    fi
    show_banner
    log_info "event=run_version version=$SCRIPT_VERSION"
    if [[ -n "$egress_ipv4_available" && -n "$egress_ipv6_available" ]]; then
        log_info "event=egress_detected ipv4=$egress_ipv4_available ipv6=$egress_ipv6_available"
    fi
    if [[ "$default_route_mode" -eq 1 && -f "$xray_config_path" ]]; then
        install_dependencies jq || return 1
        patch_existing_xray_config
        return $?
    fi
    if [[ "$add_limiter_mode" -eq 1 || "$change_sni_mode" -eq 1 ]]; then
        install_dependencies jq || return 1
        patch_existing_xray_config || return 1
        commit_share_output || return 1
        info "补丁完成 / Patch complete."
        return 0
    fi
    if [[ "$addsocks_mode" -eq 1 ]]; then
        if xray_service_is_active; then xray_active=1; fi
        if [[ "$xray_active" -eq 1 && ! -f "$xray_config_path" ]]; then
            error "Xray正在运行但缺少配置文件 / Xray is active but its configuration is missing."
            return 1
        fi
        if [[ "$xray_active" -eq 1 || -f "$xray_config_path" ]]; then
            install_dependencies jq || return 1
            patch_existing_xray_config || return 1
            commit_share_output || return 1
            info "SOCKS5入站添加完成 / SOCKS5 inbound added."
            return 0
        fi
    fi
    if [[ "$remove_mode" -eq 1 ]]; then
        remove_alias
        [[ "$realm_mode" -eq 1 ]] && uninstall_realm
        [[ "$realm_only" -ne 1 ]] && uninstall_xray
        info "卸载完成 / Uninstallation complete."
        return 0
    fi
    if [[ "$keepconfig" -eq 1 ]]; then install_dependencies jq || return 1; else install_dependencies || return 1; fi
    case "$xray_config_path" in *.yaml|*.yml) require_xray_yaml_tool || return 1 ;; esac
    detect_network_interfaces
    if [[ "$realm_only" -ne 1 ]]; then
        if [[ "$keepconfig" -ne 1 && -z "$egress_ipv4_available" ]]; then
            detect_egress_network || { error "没有可用出口 / No reachable egress."; return 1; }
        fi
        log_info "event=egress_detected ipv4=${egress_ipv4_available:-unknown} ipv6=${egress_ipv6_available:-unknown}"
        install_xray || return 1
        configure_xray || return 1
        enable_bbr
        add_alias_if_missing
    fi
    if [[ "$realm_mode" -eq 1 ]]; then
        initialize_ip_from_netstack
        install_realm || return 1
        configure_realm || return 1
        restart_realm_service || return 1
    fi
    output_results || return 1
    if [[ -n "$share_output_file" ]]; then commit_share_output || return 1; fi
    info "总用时 / Elapsed: ${SECONDS}s"
    log_info "event=run_complete duration_s=$SECONDS"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
    main "$@"
fi
