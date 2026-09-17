#!/bin/bash
# shellcheck disable=SC2154

# Constants and Configuration

readonly SCRIPT_VERSION="2026.28"
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
readonly SERVICE_NAME="xray.service"
readonly SERVICE_NAME_ALPINE="xray"
readonly GITHUB_RELEASE_BASE_URL="https://github.com/livingfree2023/nokey/releases/latest/download"
readonly GITHUB_XRAY_RC_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/xray.rc"
readonly GITHUB_XRAY_SERVICE_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/xray.service"
readonly GITHUB_REALM_RC_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/realm.rc"
readonly GITHUB_REALM_SERVICE_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/realm.service"
readonly REALM_SERVICE_NAME="realm.service"
readonly REALM_SERVICE_NAME_ALPINE="realm"
readonly REALM_CONFIG_DIR="/usr/local/etc/realm"
# Sing-box constants
readonly SINGBOX_SERVICE_NAME="sing-box.service"
readonly SINGBOX_SERVICE_NAME_ALPINE="sing-box"
readonly GITHUB_SINGBOX_SERVICE_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/sing-box.service"
readonly GITHUB_SINGBOX_RC_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/sing-box.rc"
readonly SINGBOX_CONFIG_DIR="/etc/sing-box"

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
xray_config_path="/usr/local/etc/xray/config.json"
patch_jq_source=""
patch_cleanup=""
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

# --singbox installs alongside Xray; --singbox-only suppresses the Xray path.
sing_box_mode=0
sing_box_only=0
# Output helpers use a separate context so the requested install mode stays immutable.
result_sing_box_mode=0
menu_mode=0

# Last REALITY probe latency in ms (set by probe_reality_target; read by pick_default_domain)
probe_latency_ms=""

init_output_files() {
    : > "$LOG_FILE"
    : > "$URL_FILE"
}

# Helper functions
error() {
    echo -e "\n${red}$1${none}\n" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "\n${yellow}$1${none}\n" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${yellow}$1${none}" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${green}$1${none}" | tee -a "$LOG_FILE"
}

task_start() {
    echo -n -e "${yellow}$1 ... ${none}" | tee -a "$LOG_FILE"
}

task_done() {
    echo -e "[${green}OK${none}]" | tee -a "$LOG_FILE"
}

task_done_with_info() {
    echo -e "${cyan}$1${none} [${green}OK${none}]" | tee -a  "$LOG_FILE"
}

task_fail() {
    echo -e "[${red}FAILED${none}]" | tee -a "$LOG_FILE"
}

log_verbose() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Verbose info → log only (not stdout)
log_info() {
    echo -e "${yellow}$1${none}" >> "$LOG_FILE"
}

# Simple output separator for stdout
separator() {
    echo -e "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${none}"
}

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
resolve_singbox_arch_name() {
    case "${1:-$(uname -m)}" in
        x86_64|amd64)
            echo "sing-box_amd64"
            ;;
        aarch64|arm64)
            echo "sing-box_arm64"
            ;;
        *)
            return 1
            ;;
    esac
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
                echo "已从 $file 移除别名 (备份: $file.bak) / Removed alias from $file (backup created as $file.bak)"
            else
                echo "$file 中未找到别名 / Alias not found in $file"
            fi
        fi
    done
    info "\n卸载完成 / Uninstallation complete."
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
    echo "Detected interface / 找到网卡: $Public_IPv4 $Public_IPv6" >> "$LOG_FILE"
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

    declare -A os_package_command=(
        [apt]="apt install -y"
        [yum]="yum install -y"
        [dnf]="dnf install -y"
        [pacman]="pacman -Sy --noconfirm"
        [apk]="apk add --no-cache"
        [zypper]="zypper install -y"
        [xbps-install]="xbps-install -Sy"
    )

    # Fallback detection using which
    if [[ -z "$manager" ]]; then
        for candidate in "${!os_package_command[@]}"; do
            if command -v "$candidate" > /dev/null 2>&1; then
                manager=$candidate
                # info "\nfound manager $manager in fallback"
                break
            fi
        done
    fi

    if [[ -z "$manager" ]]; then
        error "无法识别包管理器 / Cannot detect package manager"
        return 1
    fi

    local install_cmd="${os_package_command[$manager]}"

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
            eval "$install_cmd" "$package_name"  >> "$LOG_FILE" 2>&1
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
        error "使用--keepconfig时，所有运行参数将从/usr/local/etc/xray/config.json读取 / When --keepconfig is set, all runtime values are loaded from /usr/local/etc/xray/config.json."
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

xray_service_is_active() {
    if [ "${ID:-}" = "alpine" ] || [ "${ID_LIKE:-}" = "alpine" ]; then
        rc-service "$SERVICE_NAME_ALPINE" status >/dev/null 2>&1
    else
        systemctl is-active --quiet "$SERVICE_NAME"
    fi
}

load_runtime_vars_from_existing_config() {
    local config_path="/usr/local/etc/xray/config.json"
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
    if ! jq empty "$config_path" >/dev/null 2>/tmp/nokey-jq-raw.err; then
        jq_error="$(cat /tmp/nokey-jq-raw.err 2>/dev/null || true)"
        log_verbose "jq raw parse error: ${jq_error}"

        # Config generated by this script may include // comments; strip them and retry.
        jsonc_tmp="$(mktemp /tmp/nokey-config-json.XXXXXX)" || {
            task_fail
            error "无法创建临时文件用于JSONC解析 / Failed to create temporary file for JSONC parsing."
            exit 1
        }
        sed -E 's@[[:space:]]+//.*$@@' "$config_path" > "$jsonc_tmp"

        if ! jq empty "$jsonc_tmp" >/dev/null 2>/tmp/nokey-jq-stripped.err; then
            local stripped_error=""
            stripped_error="$(cat /tmp/nokey-jq-stripped.err 2>/dev/null || true)"
            task_fail
            error "配置文件格式无效 / Invalid config format in $config_path."
            error "jq(原始): ${jq_error}"
            error "jq(去注释): ${stripped_error}"
            error "提示：修复所报行附近的语法问题，下面是原始配置文件附近的行 / Tip: remove syntax issues near the reported line/column. Showing nearby lines from original config:"

            local line_no
            line_no="$(echo "$jq_error" | sed -nE 's/.*line ([0-9]+), column.*/\1/p' | head -n1)"
            if [[ -n "$line_no" ]]; then
                local start_line=$((line_no - 2))
                local end_line=$((line_no + 2))
                if [[ $start_line -lt 1 ]]; then
                    start_line=1
                fi
                nl -ba "$config_path" | sed -n "${start_line},${end_line}p" | tee -a "$LOG_FILE"
            else
                nl -ba "$config_path" | sed -n '1,40p' | tee -a "$LOG_FILE"
            fi

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
    task_done_with_info "port=${port}, domain=${domain}, uuid=${uuid}"
}

install_xray() {
    if [[ $force_reinstall == 1 ]]; then
      uninstall_xray
    fi

    task_start "开始，安装或升级XRAY / Install or upgrade XRAY"

    # 如果xray已在运行，先停掉，否则二进制文件被锁无法覆写
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        rc-service "$SERVICE_NAME_ALPINE" stop 2>/dev/null || true
    else
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    fi

    local arch_binary_name=""
    local arch_name=""
    arch_binary_name="$(resolve_arch_binary_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }
    arch_name="$(resolve_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }

    log_info "检测到系统 / Detected OS: $(resolve_os_family) | 架构 / Architecture: ${arch_name}"
    
    log_info "正在从GitHub Releases下载xray二进制文件 / Downloading xray binary and data files from GitHub Releases"

    mkdir -p /usr/local/bin /usr/local/share/xray /usr/local/etc/xray /var/log/xray || { task_fail; error "创建xray目录失败 / Failed to create xray directories"; exit 1; }
    log_verbose "Created install directories under /usr/local and /var/log/xray"

    log_verbose "Downloading: ${GITHUB_RELEASE_BASE_URL}/${arch_binary_name} -> /usr/local/bin/xray"
    curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/${arch_binary_name}" -o /usr/local/bin/xray >> "$LOG_FILE" 2>&1 || { task_fail; error "下载${arch_binary_name}失败 / Failed to download ${arch_binary_name}"; exit 1; }
    log_verbose "Downloading: ${GITHUB_RELEASE_BASE_URL}/geoip.dat -> /usr/local/share/xray/geoip.dat"
    curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/geoip.dat" -o /usr/local/share/xray/geoip.dat >> "$LOG_FILE" 2>&1 || { task_fail; error "下载geoip.dat失败 / Failed to download geoip.dat"; exit 1; }
    log_verbose "Downloading: ${GITHUB_RELEASE_BASE_URL}/geosite.dat -> /usr/local/share/xray/geosite.dat"
    curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/geosite.dat" -o /usr/local/share/xray/geosite.dat >> "$LOG_FILE" 2>&1 || { task_fail; error "下载geosite.dat失败 / Failed to download geosite.dat"; exit 1; }
    chmod 755 /usr/local/bin/xray
    log_verbose "Set executable permissions on /usr/local/bin/xray"

    local xray_rc_tmp
    local xray_service_tmp
    xray_rc_tmp="$(mktemp /tmp/nokey.xray.rc.XXXXXX)" || { task_fail; error "创建xray.rc临时文件失败 / Failed to create temporary file for xray.rc"; exit 1; }
    xray_service_tmp="$(mktemp /tmp/nokey.xray.service.XXXXXX)" || { task_fail; error "创建xray.service临时文件失败 / Failed to create temporary file for xray.service"; exit 1; }

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            log_info "安装OpenRC服务 / Installing OpenRC service: /etc/init.d/${SERVICE_NAME_ALPINE}"
        log_verbose "Downloading service file: ${GITHUB_XRAY_RC_URL} -> ${xray_rc_tmp}"
        curl -fSL "${GITHUB_XRAY_RC_URL}" -o "${xray_rc_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "下载xray.rc失败 / Failed to download xray.rc"; exit 1; }
        configure_openrc_crash_restart "${xray_rc_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "配置xray崩溃自动重启失败 / Failed to configure xray crash restart"; exit 1; }
        install -m 755 "${xray_rc_tmp}" /etc/init.d/"$SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "安装/etc/init.d/$SERVICE_NAME_ALPINE失败 / Failed to install /etc/init.d/$SERVICE_NAME_ALPINE"; exit 1; }
        rm -f "${xray_rc_tmp}" >> "$LOG_FILE" 2>&1
        log_verbose "Installed OpenRC service file from xray.rc"
        rc-update add "$SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用OpenRC服务$SERVICE_NAME_ALPINE失败 / Failed to enable OpenRC service $SERVICE_NAME_ALPINE"; exit 1; }
        log_verbose "Enabled OpenRC service: $SERVICE_NAME_ALPINE"
    else
        log_info "安装systemd服务 / Installing systemd service: /etc/systemd/system/${SERVICE_NAME}"
        log_verbose "Downloading service file: ${GITHUB_XRAY_SERVICE_URL} -> ${xray_service_tmp}"
        curl -fSL "${GITHUB_XRAY_SERVICE_URL}" -o "${xray_service_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "下载xray.service失败 / Failed to download xray.service"; exit 1; }
        # shellcheck disable=SC2016
        sed -e 's/\$INSTALL_USER/nobody/g' \
            -e '/\${temp_CapabilityBoundingSet}/d' \
            -e '/\${temp_AmbientCapabilities}/d' \
            -e '/\${temp_NoNewPrivileges}/d' \
            "${xray_service_tmp}" > /etc/systemd/system/"$SERVICE_NAME" || { task_fail; error "写入/etc/systemd/system/$SERVICE_NAME失败 / Failed to write /etc/systemd/system/$SERVICE_NAME"; exit 1; }
        configure_systemd_crash_restart /etc/systemd/system/"$SERVICE_NAME" >> "$LOG_FILE" 2>&1 || { task_fail; error "配置xray崩溃自动重启失败 / Failed to configure xray crash restart"; exit 1; }
        rm -f "${xray_service_tmp}" >> "$LOG_FILE" 2>&1
        log_verbose "Installed systemd service file from xray.service"
        systemctl daemon-reload >> "$LOG_FILE" 2>&1 || { task_fail; error "systemctl daemon-reload失败 / systemctl daemon-reload failed"; exit 1; }
        systemctl enable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用systemd服务$SERVICE_NAME失败 / Failed to enable systemd service $SERVICE_NAME"; exit 1; }
        log_verbose "Enabled systemd service: $SERVICE_NAME"
    fi

    task_done

}

install_singbox() {
    if [[ $force_reinstall == 1 ]]; then
      uninstall_singbox
    fi
    
    task_start "开始，安装或升级Sing-box / Install or upgrade Sing-box"
    
    # Detect OS type (similar to install-singbox.sh)
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi

    log_info "检测到系统 / Detected OS: $OS (${OS_ID:-unknown})"
    
    # Check root privileges
    if [[ $dry_run -eq 1 ]]; then
        return
    fi
    if [ "$EUID" -ne 0 ]; then
        error "请以root身份运行此脚本 / Please run as root: ${red}sudo -i${none}"
        exit 1
    fi
    
    # Install dependencies based on OS
    task_start "安装系统依赖 / Installing system dependencies"
    
    case "$OS" in
        alpine)
            apk update >> "$LOG_FILE" 2>&1 || { task_fail; error "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc >> "$LOG_FILE" 2>&1 || {
                task_fail; error "依赖安装失败"; exit 1
            }
            
            # 确保 OpenRC 运行
            if ! rc-service --list 2>/dev/null | grep -q "^openrc"; then
                rc-update add openrc boot >/dev/null 2>&1 || true
                rc-service openrc start >/dev/null 2>&1 || true
            fi
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >> "$LOG_FILE" 2>&1 || { task_fail; error "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl >> "$LOG_FILE" 2>&1 || {
                task_fail; error "依赖安装失败"; exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl >> "$LOG_FILE" 2>&1 || {
                task_fail; error "依赖安装失败"; exit 1
            }
            ;;
        *)
            warn "未识别的系统类型，尝试继续..."
            ;;
    esac
    
    task_done
    
    # For sing-box, we'll use default values similar to install-singbox.sh
    # Generate random port if not set (prefer 443 when free or owned by sing-box)
    if [[ -z $port ]]; then
        if is_port_reusable 443 sing-box "$SINGBOX_SERVICE_NAME" "$SINGBOX_SERVICE_NAME_ALPINE"; then
            port=443
        else
            if ! select_random_unused_port; then
                task_fail
                error "没有找到可用的Sing-box端口 / Could not find an unused Sing-box port."
                exit 1
            fi
            port="$random_unused_port"
        fi
        log_info "使用端口: $port"
    fi
    
    # Generate UUID if not set (sing-box VLESS uses standard UUID format)
    if [[ -z $uuid ]]; then
        uuid=$(generate_uuid)
        log_info "自动生成UUID / Auto-generated UUID"
    fi
    
    # Default domain if not set
    if [[ -z $domain ]]; then
        pick_default_domain || true
    fi
    
    # Install sing-box binary
    log_info "正在从GitHub Releases下载sing-box二进制文件 / Downloading sing-box binary from GitHub Releases"

    # Determine architecture and download appropriate sing-box binary
    local arch_binary_name=""
    local arch_name=""
    arch_binary_name="$(resolve_singbox_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }
    arch_name="$(resolve_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }
    
    log_info "检测到系统 / Detected OS: $(resolve_os_family) | 架构 / Architecture: ${arch_name}"
    
    mkdir -p /usr/local/bin || { task_fail; error "创建sing-box目录失败 / Failed to create sing-box directories"; exit 1; }
    log_verbose "Created install directories under /usr/local"
    
    local download_url="${GITHUB_RELEASE_BASE_URL}/${arch_binary_name}"
    log_verbose "Downloading: ${download_url} -> /usr/local/bin/sing-box"
    if curl -fSL "$download_url" -o /usr/local/bin/sing-box >> "$LOG_FILE" 2>&1; then
        chmod 755 /usr/local/bin/sing-box
        log_verbose "Set executable permissions on /usr/local/bin/sing-box"
        if ! /usr/local/bin/sing-box version >/dev/null 2>&1; then
            warn "下载的二进制无法执行(glibc/musl不兼容)，回退到apk安装 / Downloaded binary cannot execute (glibc/musl mismatch); fallback to apk"
            rm -f /usr/local/bin/sing-box
            if [[ "$OS" == "alpine" ]]; then
                apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box >> "$LOG_FILE" 2>&1 || {
                    task_fail; error "通过apk安装sing-box失败 / Failed to install sing-box via apk"; exit 1;
                }
            else
                task_fail; error "下载的sing-box二进制文件无法执行 / Downloaded sing-box binary cannot execute"; exit 1;
            fi
        fi
    else
        warn "从Release下载sing-box失败，回退到官方安装脚本 / Failed to download sing-box from Release; fallback to official installer"
        # Fallback to official sing-box installer
        if [[ "$OS" == "alpine" ]]; then
            apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box >> "$LOG_FILE" 2>&1 || {
                task_fail; error "通过apk安装sing-box失败 / Failed to install sing-box via apk"; exit 1;
            }
        else
            bash <(curl -fsSL https://sing-box.app/install.sh) >> "$LOG_FILE" 2>&1 || {
                task_fail; error "通过官方脚本安装sing-box失败 / Failed to install sing-box via official script"; exit 1;
            }
        fi
    fi
    
    # Create configuration directory and file
    mkdir -p "$SINGBOX_CONFIG_DIR" || { task_fail; error "创建sing-box配置目录失败 / Failed to create sing-box config directory"; exit 1; }
    
    # Generate Reality keypair using sing-box
    task_start "生成Reality密钥对 / Generate Reality Key Pair"
    keys=$(sing-box generate reality-keypair 2>>"$LOG_FILE")
    if [[ -z "$keys" ]]; then
        task_fail
        error "生成Reality密钥失败，sing-box是否安装正确？ / Failed to generate Reality keys. Is sing-box installed correctly?"
        exit 1
    fi
    private_key=$(extract_private_key_from_x25519_output "$keys")
    public_key=$(extract_public_key_from_x25519_output "$keys")
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        task_fail
        error "无法解析Reality密钥 / Failed to parse Reality keys"
        exit 1
    fi
    task_done_with_info "${public_key}"
    
    # Generate shortid if not set
    task_start "生成shortid / Generate shortid"
    if [[ -z $shortid ]]; then
        shortid=$(generate_shortid)
    fi
    task_done_with_info "${shortid}"
    
    # Generate sing-box config (VLESS Reality Vision)
    local config_path="${SINGBOX_CONFIG_DIR}/config.json"
    cat > "$config_path" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen_port": $port,
      "users": [
        {
          "name": "nokey",
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "alpn": ["h2", "http/1.1"],
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$domain",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$shortid"],
          "max_time_difference": "1m"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
EOF
    
    # Validate configuration if sing-box is available
    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$config_path" >/dev/null 2>&1; then
            info "配置文件验证通过 / Config file validation passed"
        else
            warn "配置文件验证失败，但将继续... / Config file validation failed, but continuing..."
        fi
    fi
    
    # Setup service (if not already installed by package manager)
    if [[ ! -f "/etc/init.d/$SINGBOX_SERVICE_NAME_ALPINE" && ! -f "/etc/systemd/system/$SINGBOX_SERVICE_NAME" ]]; then
        local service_tmp
        service_tmp="$(mktemp /tmp/nokey.sing-box.service.XXXXXX)" || { task_fail; error "创建sing-box.service临时文件失败 / Failed to create temporary file for sing-box.service"; exit 1; }
        
        if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            log_info "安装OpenRC服务 / Installing OpenRC service: /etc/init.d/${SINGBOX_SERVICE_NAME_ALPINE}"
            log_verbose "Downloading service file: ${GITHUB_SINGBOX_RC_URL} -> ${service_tmp}"
            if curl -fSL "${GITHUB_SINGBOX_RC_URL}" -o "${service_tmp}" >> "$LOG_FILE" 2>&1; then
                if ! install -m 755 "${service_tmp}" /etc/init.d/"$SINGBOX_SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1; then
                    task_fail
                    error "安装sing-box OpenRC服务失败 / Failed to install sing-box OpenRC service"
                    exit 1
                fi
                rm -f "${service_tmp}" >> "$LOG_FILE" 2>&1
                log_verbose "Installed OpenRC service file from sing-box.rc"
                rc-update add "$SINGBOX_SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || warn "添加sing-box开机自启失败 / Failed to add sing-box to startup"
            else
                warn "下载sing-box.rc失败，服务可能已被包管理器安装 / Failed to download sing-box.rc; service may already be installed by package manager"
                rm -f "${service_tmp}" >> "$LOG_FILE" 2>&1
            fi
        else
            log_info "安装systemd服务 / Installing systemd service: /etc/systemd/system/${SINGBOX_SERVICE_NAME}"
            log_verbose "Downloading service file: ${GITHUB_SINGBOX_SERVICE_URL} -> ${service_tmp}"
            if curl -fSL "${GITHUB_SINGBOX_SERVICE_URL}" -o "${service_tmp}" >> "$LOG_FILE" 2>&1; then
                if ! cp "${service_tmp}" /etc/systemd/system/"$SINGBOX_SERVICE_NAME" >> "$LOG_FILE" 2>&1; then
                    task_fail
                    error "安装sing-box systemd服务失败 / Failed to install sing-box systemd service"
                    exit 1
                fi
                rm -f "${service_tmp}" >> "$LOG_FILE" 2>&1
                log_verbose "Installed systemd service file from sing-box.service"
                systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
                systemctl enable "$SINGBOX_SERVICE_NAME" >> "$LOG_FILE" 2>&1 || warn "启用sing-box服务失败 / Failed to enable sing-box service"
            else
                warn "下载sing-box.service失败，服务可能已被包管理器安装 / Failed to download sing-box.service; service may already be installed by package manager"
                rm -f "${service_tmp}" >> "$LOG_FILE" 2>&1
            fi
        fi
    else
        info "服务文件已存在，跳过服务安装 / Service file already exists, skipping service setup"
    fi

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        configure_openrc_crash_restart /etc/init.d/"$SINGBOX_SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "配置sing-box崩溃自动重启失败 / Failed to configure sing-box crash restart"; exit 1; }
    else
        configure_systemd_crash_restart /etc/systemd/system/"$SINGBOX_SERVICE_NAME" >> "$LOG_FILE" 2>&1 || { task_fail; error "配置sing-box崩溃自动重启失败 / Failed to configure sing-box crash restart"; exit 1; }
        systemctl daemon-reload >> "$LOG_FILE" 2>&1 || { task_fail; error "systemctl daemon-reload失败 / systemctl daemon-reload failed"; exit 1; }
    fi
    
    # Restart sing-box to pick up the new config
    task_start "启动Sing-box服务 / Starting Sing-box Service"
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        if rc-service "$SINGBOX_SERVICE_NAME_ALPINE" restart >> "$LOG_FILE" 2>&1; then
            task_done
        else
            warn "重启Sing-box服务失败，请手动启动 / Failed to restart sing-box service, please start manually"
            task_done
        fi
    else
        if systemctl restart "$SINGBOX_SERVICE_NAME" >> "$LOG_FILE" 2>&1; then
            task_done
        else
            warn "重启Sing-box服务失败，请手动启动 / Failed to restart sing-box service, please start manually"
            task_done
        fi
    fi
}

uninstall_singbox() {
    task_start "卸载 Sing-box / Uninstall Sing-box"
    {
        if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            rc-service "$SINGBOX_SERVICE_NAME_ALPINE" stop 2>/dev/null || true
            rc-update del "$SINGBOX_SERVICE_NAME_ALPINE" 2>/dev/null || true
            rm -f "/etc/init.d/$SINGBOX_SERVICE_NAME_ALPINE"
        else
            systemctl stop "$SINGBOX_SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$SINGBOX_SERVICE_NAME" 2>/dev/null || true
            rm -f "/etc/systemd/system/$SINGBOX_SERVICE_NAME" 2>/dev/null || true
            systemctl daemon-reload 2>/dev/null || true
        fi
        rm -f /usr/local/bin/sing-box
        rm -rf "$SINGBOX_CONFIG_DIR"
    } >> "$LOG_FILE" 2>&1
    task_done
}

uninstall_in_alpine() {
   {
     rc-service "$SERVICE_NAME_ALPINE" stop
     rc-update del "$SERVICE_NAME_ALPINE"
     rm -rf "/usr/local/bin/xray"
     rm -rf "/usr/local/share/xray"
     rm -rf "/usr/local/etc/xray/"
     rm -rf "/etc/init.d/$SERVICE_NAME_ALPINE"
   } >> "$LOG_FILE" 2>&1
}

uninstall_xray() {
# Check if geodata files exist and are recent (less than 1 week old)
    task_start "什么？要卸载重装？ / Force Reinstall"
    
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
      info "\nAlpine系统：卸载xray / Alpine OS: uninstall xray"
      uninstall_in_alpine
    else
      {
        systemctl stop "$SERVICE_NAME"
        systemctl disable "$SERVICE_NAME"
        rm -f /etc/systemd/system/"$SERVICE_NAME"
        systemctl daemon-reload
        rm -rf "/usr/local/bin/xray"
        rm -rf "/usr/local/share/xray"
        rm -rf "/usr/local/etc/xray/"
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
    echo -e "      ___         ___         ___         ___               "
    echo -e "     /__/\\       /  /\\       /__/|       /  /\\        ___   "
    echo -e "     \\  \\:\\     /  /::\\     |  |:|      /  /:/_      /__/|  "
    echo -e "      \\  \\:\\   /  /:/\\:\\    |  |:|     /  /:/ /\\    |  |:|  "
    echo -e "  _____\\__\\:\\ /  /:/  \\:\\ __|  |:|    /  /:/ /:/_   |  |:|  "
    echo -e " /__/::::::::/__/:/ \\__\\:/__/\_|:|___/__/:/ /:/ /\\__|__|:|  "
    echo -e " \\  \\:\\~~\\~~\\\\  \\:\\ /  /:\\  \\:\\/:::::\\  \\:\\/:/ /:/__/::::\\  "
    echo -e "  \\  \\:\\  ~~~ \\  \\:\\  /:/ \\  \\::/~~~~ \\  \\::/ /:/   ~\\~~\\:\\ "
    echo -e "   \\  \\:\\      \\  \\:\\/:/   \\  \\:\\      \\  \\:\\/:/      \\  \\:\\"
    echo -e "    \\  \\:\\      \\  \\::/     \\  \\:\\      \\  \\::/        \\__\\/"
    echo -e "     \\__\\/       \\__\\/       \\__\\/       \\__\\/              "



    echo "项目地址，欢迎点点点点星 / STAR ME PLEEEEEAAAASE"
    echo -e "${cyan}$GITHUB_URL${none}"
    echo -e "支持带参数执行，不带参数直接无敌 / Supports parameters, no params just works — see ${cyan}--help${none}"

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
        --singbox)
            sing_box_mode=1
            ;;
        --singbox-only)
            sing_box_mode=1
            sing_box_only=1
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
        echo ""
        echo "NoKey menu"
        echo "1) Install Xray VLESS Reality"
        echo "2) Install Realm"
        echo "3) Add Xray SOCKS5"
        echo "4) Configure Xray WARP"
        echo "5) Install Sing-box VLESS Reality"
        echo "6) Enable BBR"
        echo "7) Get SSL certificate with acme.sh"
        echo "8) Install Hysteria2 server"
        echo "9) Exit"
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
            5) run_feature_script singbox.sh; break ;;
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
            9) break ;;
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

    # Default domain if not set (auto-scan SNI; both sing-box and xray modes)
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
      keys=$(xray x25519)
      if [[ -z "$keys" ]]; then
        task_fail
        error "生成x25519密钥失败，xray是否安装正确？ / Failed to generate x25519 keys. Is xray installed correctly?"
        exit 1
      fi
      task_start "生成一个私钥 / Generate Private Key"
      private_key=$(extract_private_key_from_x25519_output "$keys")
      if [[ -z "$private_key" ]]; then
        task_fail
        error "无法从x25519输出解析私钥 / Failed to parse PrivateKey from x25519 output."
        exit 1
      fi
      task_done_with_info "${private_key}"
      task_start "生成一个公钥 / Generate Public Key"
      public_key=$(extract_public_key_from_x25519_output "$keys")
      if [[ -z "$public_key" ]]; then
        task_fail
        error "无法从x25519输出解析公钥 / Failed to parse PublicKey from x25519 output."
        exit 1
      fi
      task_done_with_info "${public_key}"
    fi

    task_start "生成一个shortid / Generate shortid"
    if [[ -z $shortid ]]; then
      shortid=$(generate_shortid)
      task_done_with_info "${shortid}" 
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
      { 
        "log": {
          "access": "/tmp/xray_access.log",
          "error": "/tmp/xray_error.log",
          "loglevel": "error"
        },
        "inbounds": [
          {
            "port": ${port},
            "protocol": "vless",
            "settings": {
              "clients": [
                {
                  "id": "${uuid}",
                  "flow": "xtls-rprx-vision"
                }
              ],
              "decryption": "none"
            },
            "streamSettings": {
              "network": "tcp",
              "security": "reality",
              "realitySettings": {
                "show": false,
                "minClientVer": "0.0.0",
                "dest": "${domain}:${reality_dest_port}",
                "xver": 0,
                "serverNames": ["${domain}"],
                "privateKey": "${private_key}",
                "mldsa65Seed": "${mldsa65Seed}",
                "shortIds": ["${shortid}"],
                "limitFallbackUpload": {
                  "afterBytes": 0,
                  "bytesPerSec": ${fallback_bytes_per_sec},
                  "burstBytesPerSec": ${fallback_burst_bytes_per_sec}
                },
                "limitFallbackDownload": {
                  "afterBytes": 0,
                  "bytesPerSec": ${fallback_bytes_per_sec},
                  "burstBytesPerSec": ${fallback_burst_bytes_per_sec}
                }
              }
            },
            "sniffing": {
              "enabled": true,
              "destOverride": ["http", "tls", "quic"],
              "routeOnly": true
            }
          }${socks_inbound_json:+,
${socks_inbound_json}}
        ],
        "outbounds": [
          {
            "protocol": "freedom",
            "settings": {},
            "tag": "direct"
          },
          {
            "protocol": "freedom",
            "streamSettings": {
              "sockopt": {
                "domainStrategy": "ForceIPv4"
              }
            },
            "tag": "force_ipv4"
          },
          {
            "protocol": "freedom",
            "streamSettings": {
              "sockopt": {
                "domainStrategy": "ForceIPv6"
              }
            },
            "tag": "force_ipv6"
          },
          {
            "tag": "warp_out",
            "protocol": "socks",
            "settings": {
                "servers": [
                    {
                        "address": "127.0.0.1",
                        "port": 40000
                    }
                ]
            }
          },
          {
            "protocol": "blackhole",
            "tag": "block"
          }
        ],
        "dns": {
          "servers": [
            "8.8.8.8",
            "1.1.1.1",
            "2001:4860:4860::8888",
            "2606:4700:4700::1111",
            "localhost"
          ]
        },
        "routing": {
          "domainStrategy": "IPIfNonMatch",
          "rules": [
            {
              "type": "field",
              "ip": ["geoip:private"],
              "outboundTag": "block"
            },
            {
              "type": "field",
              "outboundTag": "block",
              "protocol": [
                "bittorrent"
              ]
            },
            {
              "type": "field",
              "domain": [],
              "outboundTag": "force_ipv4"
            },
            {
              "type": "field",
              "domain": [],
              "outboundTag": "force_ipv6"
            },
            {
              "type": "field",
              "domain": [],
              "outboundTag": "warp_out"
            }
          ]
        }
      }
EOF
    )
    if [[ $mldsa_enabled != 1 ]]; then
      reality_template=$(echo "$reality_template" | sed '/"mldsa65Seed":/d')
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
    
    if ! echo "$reality_template" > "$config_path"; then
        task_fail
        error "写入xray配置文件失败: $config_path / Failed to write xray config to $config_path."
        [[ -f "$config_path" ]] && rm -f "$config_path"
        error "已删除不完整的配置文件，请检查权限、磁盘空间和$LOG_FILE获取详情 / Partial config file removed. Check permissions, disk space, and $LOG_FILE for details."
        exit 1
    fi
    task_done

log_info "--- ${config_path} ---"
    cat "$config_path" >> "$LOG_FILE"
}

restart_xray_service() {
    task_start "冲刺，开启服务 / Starting Service"
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        restart_cmd=(rc-service "$SERVICE_NAME_ALPINE" restart)
    else
        restart_cmd=(systemctl restart "$SERVICE_NAME")
    fi
    if ! "${restart_cmd[@]}" >> "$LOG_FILE" 2>&1; then
        task_fail
        error "重启xray服务失败，请查看$LOG_FILE获取详情 / Failed to restart xray service. Check $LOG_FILE for details."
        exit 1
    fi
    task_done
}
configure_xray() {
    if [[ $keepconfig -eq 1 ]]; then
        initialize_ip_from_netstack
        info "将保留现有配置 --keepconfig / Keeping existing config due to --keepconfig"
        load_runtime_vars_from_existing_config
        info "跳过配置生成 --keepconfig / Skip config generation due to --keepconfig"
    else
        initialize_variables
        generate_crypto
        if [[ "$addsocks_mode" -eq 1 ]]; then
            task_start "生成SOCKS5入站 / Generate SOCKS5 inbound"
            prepare_socks_inbound || { task_fail; exit 1; }
            task_done_with_info "port=${socks_port}, user=${socks_username}"
        fi
        build_xray_config
    fi
    restart_xray_service
}


# ---- Patch modes (--add-limiter / --change-sni / --addsocks) ----

# Resolve the jq-parseable view of the existing config: the config itself when
# it is pure JSON, or a comment-stripped temp copy otherwise. Sets
# $patch_jq_source to the path to read from; records a temp file in
# $patch_cleanup (if any) for the caller to remove.
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

    # Xray names password-auth entries "users" (Sing-box uses different schema names).
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

    if ! mv "$patch_tmp_out" "$xray_config_path"; then
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
show_help() {
  echo -e "当前版本 / Version: ${cyan}${SCRIPT_VERSION}${none} "
  echo "使用方法: $0 [options] / Usage"
  echo "选项: / Options"
  echo "  --netstack=4|6     使用IPv4或IPv6 (默认: 自动检测) / Use IPv4 or IPv6"
  echo "  --port=NUMBER      设置端口号 (默认: 随机) / Set port number"
  echo "  --domain=DOMAIN    设置SNI域名 (默认: www.amd.com) / Set SNI domain"
  echo "  --uuid=STRING      设置UUID (默认: 自动生成) / Set UUID"
  echo "  --mldsa            启用ML-DSA签名生成 (默认: 关闭) / Enable ML-DSA signature generation (default: off)"
  echo "  --mldsa65Seed=STRING  设置ML-DSA-65私钥 (默认: 自动生成) / Set ML-DSA-65 private key"
  echo "  --mldsa65Verify=STRING  设置ML-DSA-65公钥 (默认: 自动生成) / Set ML-DSA-65 public key"
  echo "  --caddy            从运行的Caddy服务自动检测域名和端口 / Detect domain and port from Caddy service"
  echo "  --keepconfig       保留现有配置并从中生成输出链接 / Keep existing config.json and generate links from it"
  echo "  --add-limiter      为现有配置添加REALITY回落限速(独立模式, 不能与其他参数连用) / Add REALITY fallback rate limit to existing config (standalone, no other flags)"
  echo "  --change-sni       仅更换现有配置的REALITY SNI(独立模式, 不能与其他参数连用) / Re-randomize the REALITY SNI in existing config (standalone, no other flags)"
  echo "  --addsocks         添加随机端口和凭据的SOCKS5入站；Xray运行时仅修补现有配置 / Add a SOCKS5 inbound with random port and credentials; patch only when Xray is running"
  echo "  --force            强制重装 / Force Reinstall"
   echo "  --realm            额外安装Realm转发代理 (与 --remote 搭配) / Also install Realm relay proxy alongside Xray/Sing-box (use with --remote)"
   echo "  --realm-only      仅安装Realm转发代理 (不安装Xray/Sing-box, 与 --remote 搭配) / Install Realm relay proxy only (without Xray/Sing-box, use with --remote)"
   echo "  --singbox         在Xray旁额外安装Sing-box / Install Sing-box alongside Xray"
   echo "  --singbox-only    仅安装Sing-box (不安装Xray, 使用VLESS Reality Vision) / Install Sing-box only (without Xray, uses VLESS Reality Vision)"
  echo "  --remote=ADDRESS   设置Realm远程地址 (必填, 格式 host:port) / Set Realm remote address (required, format host:port)"
  echo "  --listen=ADDRESS   设置Realm监听地址 (可选, 默认派生自远程端口) / Set Realm listen address (optional, defaults to remote port on any address)"
  echo "  --remove           卸载Xray (和已安装的Realm) 与NoKey / Uninstall Xray (and Realm if installed) and NoKey"
  echo "  --dry-run          仅预览安装动作，不写入系统 / Preview actions only"
  echo "  --menu             打开其他功能菜单 / Open the feature menu"
  echo "  --help             显示此帮助信息 / Show this help message"

  exit "${1:-0}"
}

dry_run_preview() {
    task_start "预览安装流程 / Dry Run"

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

    # Handle sing-box mode in dry run
    if [[ "$sing_box_mode" -eq 1 ]]; then
        info "${green}=== Sing-box (VLESS Reality Vision) ===${none}"
        if [[ "$sing_box_only" -eq 1 ]]; then
            info "模式: 仅Sing-box (不安装Xray) / Mode: Sing-box only (no Xray)"
        else
            info "模式: Xray + Sing-box / Mode: Xray + Sing-box"
        fi
        if [[ "$realm_only" -eq 1 ]]; then
            info "跳过Sing-box安装: --realm-only 模式 / Skipping Sing-box: --realm-only mode"
            task_done
            return
        fi
        
        local singbox_arch_name=""
        singbox_arch_name="$(resolve_singbox_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }
        
        info "将创建目录 / Would create directories:"
        info "  /usr/local/bin"
        info "  $SINGBOX_CONFIG_DIR"
        
        info "将下载文件 / Would download files:"
        info "  ${GITHUB_RELEASE_BASE_URL}/${singbox_arch_name} -> /usr/local/bin/sing-box"
        
        info "将设置权限 / Would set permission:"
        info "  chmod 755 /usr/local/bin/sing-box"
        
        info "将生成密钥 / Would generate Reality keys:"
        info "  sing-box generate reality-keypair"
        info "  private_key / public_key pair"
        
        info "将生成shortid / Would generate shortid:"
        info "  random 16-character hex string"
        
        if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            info "将安装服务(OpenRC) / Would install service (OpenRC):"
            info "  ${GITHUB_SINGBOX_RC_URL} -> /tmp/nokey.sing-box.rc.<pid>"
            info "  /tmp/nokey.sing-box.rc.<pid> -> /etc/init.d/${SINGBOX_SERVICE_NAME_ALPINE}"
            info "  rc-update add ${SINGBOX_SERVICE_NAME_ALPINE}"
        else
            info "将安装服务(systemd) / Would install service (systemd):"
            info "  ${GITHUB_SINGBOX_SERVICE_URL} -> /tmp/nokey.sing-box.service.<pid>"
            info "  /tmp/nokey.sing-box.service.<pid> -> /etc/systemd/system/${SINGBOX_SERVICE_NAME}"
            info "  systemctl daemon-reload"
            info "  systemctl enable ${SINGBOX_SERVICE_NAME}"
        fi
        
        info "将写入配置 / Would write config:"
        info "  $SINGBOX_CONFIG_DIR/config.json"
        info "  协议: VLESS Reality Vision with xtls-rprx-vision flow"
        info ""
    fi
    
    # --singbox-only skips Xray; --singbox previews both services.
    if [[ "$sing_box_only" -eq 1 ]]; then
        task_done
        return
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
    info "  /usr/local/etc/xray"

    info "将下载文件 / Would download files:"
    info "  ${GITHUB_RELEASE_BASE_URL}/${arch_binary_name} -> /usr/local/bin/xray"
    info "  ${GITHUB_RELEASE_BASE_URL}/geoip.dat -> /usr/local/share/xray/geoip.dat"
    info "  ${GITHUB_RELEASE_BASE_URL}/geosite.dat -> /usr/local/share/xray/geosite.dat"

    info "将设置权限 / Would set permission:"
    info "  chmod 755 /usr/local/bin/xray"

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        info "将安装服务(OpenRC) / Would install service (OpenRC):"
        info "  ${GITHUB_XRAY_RC_URL} -> /tmp/nokey.xray.rc.<pid>"
        info "  /tmp/nokey.xray.rc.<pid> -> /etc/init.d/${SERVICE_NAME_ALPINE}"
        info "  rc-update add ${SERVICE_NAME_ALPINE}"
        info "  rc-service ${SERVICE_NAME_ALPINE} restart (after config generation)"
    else
        info "将安装服务(systemd) / Would install service (systemd):"
        info "  ${GITHUB_XRAY_SERVICE_URL} -> /tmp/nokey.xray.service.<pid>"
        info "  /tmp/nokey.xray.service.<pid> -> /etc/systemd/system/${SERVICE_NAME}"
        info "  systemctl daemon-reload"
        info "  systemctl enable ${SERVICE_NAME}"
        info "  systemctl restart ${SERVICE_NAME} (after config generation)"
    fi

    if [[ $keepconfig -eq 1 ]]; then
        info "将保留现有配置 / Would keep existing config:"
        info "  /usr/local/etc/xray/config.json"
        info "将解析现有config.json以生成输出链接 / Would parse existing config.json for URL output variables."
    else
        info "将写入配置 / Would write config:"
        info "  /usr/local/etc/xray/config.json"
    fi

    task_done
}


check_service_status() {
    task_start "检查服务状态 / Checking Service"

    if [[ $realm_mode -eq 1 ]]; then
        if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            if ! rc-service "$REALM_SERVICE_NAME_ALPINE" status >> "$LOG_FILE" 2>&1; then
                error "Realm服务未运行 / Realm service is not active"
                rc-service "$REALM_SERVICE_NAME_ALPINE" status | tee -a "$LOG_FILE"
                error "详细日志记录在 $LOG_FILE / See complete logs"
                exit 1
            fi
        else
            if ! systemctl is-active --quiet "$REALM_SERVICE_NAME"; then
                error "Realm服务未运行 / Realm service is not active"
                systemctl status "$REALM_SERVICE_NAME" | tee -a "$LOG_FILE"
                error "详细日志记录在 $LOG_FILE / See complete logs"
                exit 1
            fi
        fi
    fi

    if [[ $realm_only -eq 1 ]]; then
        task_done
        return
    fi

    # Check the service whose connection details are about to be emitted.
    if [[ "$result_sing_box_mode" -eq 1 ]]; then
        if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            if rc-service "$SINGBOX_SERVICE_NAME_ALPINE" status >> "$LOG_FILE" 2>&1; then
                info "Sing-box服务运行中 / Sing-box is running"
            else
                error "Sing-box服务未运行 / Sing-box service is not active"
                rc-service "$SINGBOX_SERVICE_NAME_ALPINE" status | tee -a "$LOG_FILE"
                error "详细日志记录在 $LOG_FILE / See complete logs"
                exit 1
            fi
        else
            if systemctl is-active --quiet "$SINGBOX_SERVICE_NAME"; then
                info "Sing-box服务运行中 / Sing-box is running"
            else
                error "Sing-box服务未运行 / Sing-box service is not active"
                systemctl status "$SINGBOX_SERVICE_NAME" | tee -a "$LOG_FILE"
                error "详细日志记录在 $LOG_FILE / See complete logs"
                exit 1
            fi
        fi
        task_done
        return
    fi

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
      if rc-service "$SERVICE_NAME_ALPINE" status >> "$LOG_FILE" 2>&1; then 
          info "Xray服务运行中 / Xray is running"
      else
        error "Xray服务未运行 / Xray service is not active" 
        rc-service "$SERVICE_NAME_ALPINE" status | tee -a "$LOG_FILE"
        error "详细日志记录在 $LOG_FILE / See complete logs"
        exit 1
      fi
    else
      if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "Xray服务运行中 / Xray is running"
      else
        error "Xray服务未运行 / Xray service is not active" 
        systemctl status "$SERVICE_NAME" | tee -a "$LOG_FILE"
        error "详细日志记录在 $LOG_FILE / See complete logs"
        exit 1
      fi
    fi

    task_done
}

generate_share_links() {
    if [[ "$result_sing_box_mode" -eq 1 ]]; then
        local server_ip=$ip
        if [[ $netstack == "6" ]]; then
            server_ip="[$ip]"
        fi
        local link
        link="vless://${uuid}@${server_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}#${current_hostname}"
        info "分享链接 / Share Link:"
        echo -e "${magenta}${link}${none}" | tee -a "$LOG_FILE"
        echo "$link" >> "$URL_FILE"
        return
    fi

    if [[ $netstack == "6" ]]; then
      ip="[$ip]"
    fi
    
    vless_reality_url_short="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}#${current_hostname}"

    info "分享链接 / Share Link:"
    
    if [[ $mldsa_enabled == 1 ]]; then
      vless_reality_mldsa_url="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}&pqv=${mldsa65Verify}#${current_hostname}"
      echo -e "${magenta}${vless_reality_mldsa_url}${none}"  | tee -a "$LOG_FILE"
      echo "$vless_reality_mldsa_url" >> "$URL_FILE"
      info "不含mldsa / Without mldsa:"
      echo -e "${magenta}${vless_reality_url_short}${none}"  | tee -a "$LOG_FILE"
      echo "$vless_reality_url_short" >> "$URL_FILE"
    else
      echo -e "${magenta}${vless_reality_url_short}${none}"  | tee -a "$LOG_FILE"
      echo "$vless_reality_url_short" >> "$URL_FILE"
    fi
}

generate_clash_config() {
    if [[ "$result_sing_box_mode" -eq 1 ]]; then
        local server_ip=$ip
        if [[ $netstack == "6" ]]; then
            server_ip=${ip:1:-1}
        fi
        local clash_config
        clash_config=$(cat <<-EOF
- name: ${current_hostname}
  type: vless
  server: ${server_ip}
  port: ${port}
  client-fingerprint: ${fingerprint}
  tls: true
  servername: ${domain}
  flow: xtls-rprx-vision
  network: tcp
  reality-opts:
    public-key: ${public_key}
    short-id: ${shortid}
  uuid: ${uuid}
EOF
)
        info "Clash.meta 配置 / Clash.meta config:"
        echo -e "${cyan}${clash_config}${none}" | tee -a "$LOG_FILE"
        echo "$clash_config" >> "$URL_FILE"
        return
    fi

    local server_ip_for_clash=$ip
    if [[ $netstack == "6" ]]; then
        # for clash meta, ipv6 does not need bracket.
        # The ip var is already bracketed for vless url.
        server_ip_for_clash=${ip:1:-1}
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
  uuid: ${uuid}
EOF
)
    info "Clash.meta 配置 / Clash.meta config:"
    echo -e "${cyan}${clash_meta_config}${none}" | tee -a "$LOG_FILE"
    echo "$clash_meta_config" >> "$URL_FILE"
}

# Emit an extra IPv6 share URL + clash entry when the box is dual-stack but the
# primary netstack is IPv4. The main links above already cover the primary IP.
generate_ipv6_variants() {
    [[ $netstack == "4" && -n "${IPv6:-}" ]] || return 0

    local ipv6_link
    ipv6_link="vless://${uuid}@[${IPv6}]:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}#${current_hostname}-ipv6"
    info "分享链接 (IPv6) / Share Link (IPv6):"
    echo -e "${magenta}${ipv6_link}${none}" | tee -a "$LOG_FILE"
    echo "$ipv6_link" >> "$URL_FILE"

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
  uuid: ${uuid}
EOF
)
    info "Clash.meta 配置 (IPv6) / Clash.meta config (IPv6):"
    echo -e "${cyan}${ipv6_clash}${none}" | tee -a "$LOG_FILE"
    echo "$ipv6_clash" >> "$URL_FILE"
}

output_results() {
    # 指纹FingerPrint
    fingerprint="random"

    # QR code tip → log only
    log_info "二维码生成命令：安装qrencode后运行 / For QR code, install qrencode and run: qrencode -t UTF8 -r $URL_FILE"

    check_service_status
    
    echo "" | tee -a "$LOG_FILE"
    separator | tee -a "$LOG_FILE"
    if [[ "$result_sing_box_mode" -eq 1 ]]; then
        echo -e "  ${green}✓${none} VLESS Reality Vision" | tee -a "$LOG_FILE"
    else
        echo -e "  ${green}✓${none} Xray VLESS Reality" | tee -a "$LOG_FILE"
    fi
    echo -e "  ${cyan}IP:Port${none} → ${ip}:${port}" | tee -a "$LOG_FILE"
    if [[ "$result_sing_box_mode" -ne 1 ]] || [[ -n "$public_key" ]]; then
        echo -e "  ${cyan}UUID${none} → ${uuid}" | tee -a "$LOG_FILE"
    fi
    separator | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    generate_share_links
    generate_clash_config
    generate_ipv6_variants
    if [[ "$addsocks_mode" -eq 1 ]]; then
        output_socks_proxy
    fi
    if [[ "$result_sing_box_mode" -eq 1 ]]; then
        print_service_commands "$SINGBOX_SERVICE_NAME" "$SINGBOX_SERVICE_NAME_ALPINE"
    else
        print_service_commands "$SERVICE_NAME" "$SERVICE_NAME_ALPINE"
    fi
}


# Main function
main() {
    SECONDS=0
    local install_singbox_alongside=0
    local xray_active=0

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    else
        error "无法识别的OS / Cannot determine OS."
        exit 1
    fi

    show_banner
    parse_args "$@"

    if [[ "$menu_mode" -eq 1 ]]; then
        show_feature_menu
        exit $?
    fi

    if [[ "$sing_box_mode" -eq 1 && "$sing_box_only" -eq 0 ]]; then
        install_singbox_alongside=1
    fi

    # init_output_files must stay after parse_args: non-action flags exit above and must not truncate nokey.log/.url
    if [[ "$dry_run" -eq 1 ]]; then
        detect_network_interfaces
        initialize_ip_from_netstack
        dry_run_preview
        exit 0
    fi

    init_output_files
    echo -e "当前版本 / Version: ${cyan}${SCRIPT_VERSION}${none} " | tee -a "$LOG_FILE"

    check_root

    if [[ "$add_limiter_mode" -eq 1 || "$change_sni_mode" -eq 1 ]]; then
        install_dependencies jq
        patch_existing_xray_config
        info "补丁完成 / Patch complete."
        exit 0
    fi

    if [[ "$addsocks_mode" -eq 1 ]]; then
        if xray_service_is_active; then
            xray_active=1
        fi
        if [[ "$xray_active" -eq 1 && ! -f "$xray_config_path" ]]; then
            error "Xray正在运行但缺少配置文件: $xray_config_path / Xray is active but its config file is missing: $xray_config_path"
            exit 1
        fi
        # Preserve any installed configuration, whether the service is active or stopped.
        if [[ "$xray_active" -eq 1 || -f "$xray_config_path" ]]; then
            install_dependencies jq
            patch_existing_xray_config
            info "SOCKS5入站添加完成 / SOCKS5 inbound added."
            exit 0
        fi
    fi

    if [[ "$remove_mode" -eq 1 ]]; then
        remove_alias
        if [[ "$realm_mode" -eq 1 ]]; then
            uninstall_realm
        fi
        if [[ "$sing_box_mode" -eq 1 ]]; then
            uninstall_singbox
        fi
        if [[ "$realm_only" -ne 1 && "$sing_box_only" -ne 1 ]]; then
            uninstall_xray
        fi
        info "卸载完成 / Uninstallation complete ... [${green}OK${none}]"
        exit 0
    fi

    if [[ "$keepconfig" -eq 1 ]]; then
        install_dependencies jq
    else
        install_dependencies
    fi
    detect_network_interfaces

    if [[ "$realm_only" -ne 1 ]]; then
        # Default and --singbox modes install Xray. --singbox-only skips it.
        if [[ "$sing_box_only" -ne 1 ]]; then
            install_xray
            configure_xray

            # Emit Xray results before Sing-box replaces the shared runtime vars.
            if [[ "$install_singbox_alongside" -eq 1 ]]; then
                result_sing_box_mode=0
                output_results
                port=""
                initialize_ip_from_netstack
            fi
        fi

        if [[ "$sing_box_mode" -eq 1 ]]; then
            initialize_ip_from_netstack
            install_singbox
        fi

        enable_bbr
        add_alias_if_missing
    fi

    # Handle realm installation (can be combined with either xray or sing-box)
    if [[ "$realm_mode" -eq 1 ]]; then
        initialize_ip_from_netstack
        install_realm
        configure_realm
        restart_realm_service
    fi

    result_sing_box_mode="$sing_box_mode"
    output_results
    info "总用时 / Elapsed Time:  ${green}$SECONDS 秒${none}"
    # info "日志文件 / Log File:  ${green}$LOG_FILE${none}"
    info "下次可以直接用别名${cyan}nokey${none}启动本脚本最新版 / Next time just run ${cyan}nokey${none} to use the latest version"
    echo -e "---------- ${cyan}live free or die hard${none} -------------" | tee -a "$LOG_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
    main "$@"
fi
