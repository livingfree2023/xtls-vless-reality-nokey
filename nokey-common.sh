#!/bin/bash
# shellcheck disable=SC2034,SC2154

if [[ -z "${LOG_FILE:-}" ]]; then
    readonly LOG_FILE="nokey.log"
fi
if [[ -z "${URL_FILE:-}" ]]; then
    readonly URL_FILE="nokey.url"
fi
if [[ -t 1 ]]; then
    readonly red=$'\033[91m'
    readonly green=$'\033[92m'
    readonly yellow=$'\033[93m'
    readonly magenta=$'\033[95m'
    readonly cyan=$'\033[96m'
    readonly none=$'\033[0m'
else
    readonly red=''
    readonly green=''
    readonly yellow=''
    readonly magenta=''
    readonly cyan=''
    readonly none=''
fi

# All file writes are opt-in through helpers; sourcing this file performs no I/O.
validate_log_level() {
    case "${NOKEY_LOG_LEVEL:-INFO}" in
        DEBUG|debug) nokey_log_threshold=0 ;;
        INFO|info) nokey_log_threshold=1 ;;
        WARN|warn) nokey_log_threshold=2 ;;
        ERROR|error) nokey_log_threshold=3 ;;
        *) printf '%s\n' 'NOKEY_LOG_LEVEL must be DEBUG, INFO, WARN, or ERROR' >&2; return 2 ;;
    esac
}

secure_output_file() {
    local output_path="$1"
    if [[ -L "$output_path" || ( -e "$output_path" && ! -f "$output_path" ) ]]; then
        printf 'Refusing unsafe output path: %s\n' "$output_path" >&2
        return 1
    fi
    (umask 077; : >> "$output_path") || return 1
    chmod 600 "$output_path"
}

# Mike Farah yq v4 is required only when reading or writing Xray YAML.
require_xray_yaml_tool() {
    if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -Eq 'version v4\.'; then
        error "YAML配置需要Mike Farah yq v4 / YAML config requires Mike Farah yq v4: https://github.com/mikefarah/yq#install"
        return 1
    fi
}

xray_config_to_json() {
    local input="$1" output="$2"
    case "$input" in
        *.yaml|*.yml)
            require_xray_yaml_tool || return 1
            yq -o=json '.' "$input" > "$output" || return 1
            ;;
        *) jq '.' "$input" > "$output" || return 1 ;;
    esac
    jq -e 'type == "object"' "$output" >/dev/null
}

xray_json_to_config() {
    local input="$1" output="$2" target="$3"
    case "$target" in
        *.yaml|*.yml)
            require_xray_yaml_tool || return 1
            yq -p=json -o=yaml '.' "$input" > "$output" || return 1
            ;;
        *) cat "$input" > "$output" || return 1 ;;
    esac
}

# Preserve useful legacy diagnostics while removing credentials written by older
# installers. Copy metadata first, then atomically replace the same-directory
# file; any failure leaves the restricted original untouched.
sanitize_log_history() (
    local history_path="$1" history_tmp=""
    [[ -f "$history_path" && ! -L "$history_path" ]] || return 1
    history_tmp="$(mktemp "${history_path}.sanitize.XXXXXX")" || return 1
    trap 'rm -f "$history_tmp"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! cp -p "$history_path" "$history_tmp" ||
       ! chmod 600 "$history_tmp" ||
       ! sanitize_log_stream < "$history_path" > "$history_tmp" ||
       ! touch -r "$history_path" "$history_tmp" ||
       ! mv -f "$history_tmp" "$history_path"; then
        rm -f "$history_tmp"
        return 1
    fi
)

init_output_files() {
    local rotate_log=0
    validate_log_level || return $?
    secure_output_file "$LOG_FILE" || return 1
    secure_output_file "$URL_FILE" || return 1
    if [[ -L "${LOG_FILE}.1" || ( -e "${LOG_FILE}.1" && ! -f "${LOG_FILE}.1" ) ]]; then
        printf '%s\n' 'Refusing unsafe previous log path' >&2
        return 1
    fi
    [[ "$(wc -c < "$LOG_FILE")" -gt 1048576 ]] && rotate_log=1
    sanitize_log_history "$LOG_FILE" || return 1
    if [[ "$rotate_log" -eq 1 ]]; then
        mv -f "$LOG_FILE" "${LOG_FILE}.1" || return 1
        chmod 600 "${LOG_FILE}.1" || return 1
        secure_output_file "$LOG_FILE" || return 1
    elif [[ -f "${LOG_FILE}.1" ]]; then
        secure_output_file "${LOG_FILE}.1" || return 1
        sanitize_log_history "${LOG_FILE}.1" || return 1
    fi
    if [[ "${1:-}" != preserve-shares ]]; then : > "$URL_FILE" || return 1; fi
    nokey_run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    log_event INFO 'run_start'
}

# Redact known runtime values before parsing arbitrary command diagnostics.
# The awk pass also handles unknown credentials, URI payloads, ANSI sequences,
# and multiline JSON sensitive values. Never log command argv or raw configs.
sanitize_log_stream() {
    local log_line="" secret_name="" secret_value="" secret_part=""
    while IFS= read -r log_line || [[ -n "$log_line" ]]; do
        for secret_name in private_key public_key uuid shortid mldsa65Seed mldsa65Verify socks_username socks_password; do
            secret_value="${!secret_name:-}"
            while [[ -n "$secret_value" ]]; do
                secret_part="${secret_value%%$'\n'*}"
                if [[ -n "$secret_part" ]]; then
                    log_line="${log_line//"$secret_part"/[redacted]}"
                fi
                [[ "$secret_value" == *$'\n'* ]] || break
                secret_value="${secret_value#*$'\n'}"
            done
        done
        printf '%s\n' "$log_line"
    done | awk '
        BEGIN { esc = sprintf("%c", 27); hiding = 0 }
        {
            gsub(esc "\\[[0-9;?]*[ -/]*[@-~]", "")
            gsub(/\\[eE]\[[0-9;]*m/, "")
            lower = tolower($0)
            if (hiding) {
                print "[redacted multiline sensitive value]"
                if ($0 ~ /[\]}]/ || lower ~ /-----end .*private key-----/) hiding = 0
                next
            }
            if (lower ~ /-----begin .*private key-----/) {
                print "[redacted private key]"; hiding = 1; next
            }
            if (lower ~ /generate (private key|public key|shortid)|生成一个(私钥|公钥|shortid)|uuid[[:space:]]*(→|->)/) {
                print "[redacted legacy credential output]"; next
            }
            if (lower ~ /(^|[^[:alnum:]_])(privatekey|private_key|private-key|publickey|public_key|public-key|password|passwd|pass|token|secret|authorization|id|users?|uuid|shortids?|short_id|pbk|sid|mldsa65seed|mldsa65verify|seed)["[:space:]]*[:=]/) {
                if ($0 ~ /[:=][[:space:]]*$/ || ($0 ~ /[:=][[:space:]]*[\[{]/ && $0 !~ /[\]}][[:space:]]*,?[[:space:]]*$/)) hiding = 1
                print "[redacted diagnostic containing sensitive field]"
                next
            }
            gsub(/[[:alpha:]][[:alnum:]+.-]*:\/\/[^[:space:]<>"\047]+/, "[redacted-url]")
            print
        }
    '
}

log_event() {
    local event_level="$1" message="${2:-}" event_rank=1 timestamp="" clean_line="" phase_label="${nokey_phase:-main}"
    validate_log_level || return $?
    case "$event_level" in
        DEBUG) event_rank=0 ;;
        INFO) event_rank=1 ;;
        WARN) event_rank=2 ;;
        ERROR) event_rank=3 ;;
        *) return 2 ;;
    esac
    [[ "$event_rank" -ge "$nokey_log_threshold" ]] || return 0
    secure_output_file "$LOG_FILE" || return 1
    nokey_run_id="${nokey_run_id:-$(date -u '+%Y%m%dT%H%M%SZ')-$$}"
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    [[ "$phase_label" =~ ^[[:alnum:]_.-]+$ ]] || phase_label=unknown
    while IFS= read -r clean_line || [[ -n "$clean_line" ]]; do
        printf '%s [%s] run=%s phase=%s %s\n' "$timestamp" "$event_level" "$nokey_run_id" "$phase_label" "$clean_line"
    done < <(printf '%s\n' "$message" | sanitize_log_stream) >> "$LOG_FILE"
}

# stdout-only result output deliberately bypasses the diagnostic log.
display_result() {
    printf '%b%s%b\n' "${2:-}" "${1:-}" "$none"
}

ui_message() {
    local ui_level="$1" ui_color="$2" ui_text="$3"
    display_result "$ui_text" "$ui_color"
    log_event "$ui_level" "$ui_text"
}

error() { ui_message ERROR "$red" "$1"; }
warn() { ui_message WARN "$yellow" "$1"; }
info() { ui_message INFO "$yellow" "$1"; }
success() { ui_message INFO "$green" "$1"; }
log_info() { log_event INFO "$1"; }
log_verbose() { log_event DEBUG "$1"; }

task_start() {
    local stack_depth="${nokey_task_depth:-0}"
    nokey_task_label="$1"
    nokey_task_started="$(date '+%s')"
    nokey_task_labels[stack_depth]="$nokey_task_label"
    nokey_task_starts[stack_depth]="$nokey_task_started"
    nokey_task_depth=$((stack_depth + 1))
    display_result "[...] $nokey_task_label" "$yellow"
    log_event INFO "task_start label=$nokey_task_label"
}

task_finish() {
    local task_status="$1" task_level="$2" task_color="$3" task_detail="${4:-}" elapsed=0
    local stack_depth="${nokey_task_depth:-0}" task_label=Task task_started=""
    if [[ "$stack_depth" -gt 0 ]]; then
        stack_depth=$((stack_depth - 1))
        task_label="${nokey_task_labels[$stack_depth]}"
        task_started="${nokey_task_starts[$stack_depth]}"
        unset 'nokey_task_labels[stack_depth]' 'nokey_task_starts[stack_depth]'
    fi
    if [[ -n "$task_started" ]]; then
        elapsed=$(( $(date '+%s') - task_started ))
    fi
    display_result "[$task_status] ${task_label}${task_detail:+: $task_detail}" "$task_color"
    log_event "$task_level" "task_end label=${task_label} status=$task_status duration_s=$elapsed${task_detail:+ detail=$task_detail}"
    nokey_task_depth="$stack_depth"
    if [[ "$stack_depth" -gt 0 ]]; then
        nokey_task_label="${nokey_task_labels[$((stack_depth - 1))]}"
        nokey_task_started="${nokey_task_starts[$((stack_depth - 1))]}"
    else
        nokey_task_label=""
        nokey_task_started=""
    fi
}

task_done() { task_finish OK INFO "$green"; }
task_done_with_info() { task_finish OK INFO "$green" "$1"; }
task_fail() { task_finish FAILED ERROR "$red"; }

# Capture command diagnostics without ever logging arguments (which may contain
# credentials). The subshell scopes signal cleanup and preserves caller traps.
# Use external commands or read-only functions: shell state changes stay local.
run_logged() (
    local nokey_phase="$1" command_status=0 started="" capture_file="" line="" capture_status=0 diagnostic_level=INFO
    shift
    [[ "$#" -gt 0 ]] || return 2
    started="$(date '+%s')"
    log_event INFO 'command_start' || return 1
    capture_file="$(mktemp "${TMPDIR:-/tmp}/nokey-command.XXXXXX")" || return 1
    trap 'rm -f "$capture_file"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    chmod 600 "$capture_file" || return 1
    if "$@" > "$capture_file" 2>&1; then
        command_status=0
    else
        command_status=$?
    fi
    [[ "$command_status" -ne 0 ]] && diagnostic_level=ERROR
    while IFS= read -r line || [[ -n "$line" ]]; do
        log_event "$diagnostic_level" "diagnostic $line" || capture_status=1
    done < <(sanitize_log_stream < "$capture_file")
    rm -f "$capture_file"
    if [[ "$command_status" -eq 0 ]]; then
        log_event INFO "command_end exit=0 duration_s=$(( $(date '+%s') - started ))" || capture_status=1
    else
        log_event ERROR "command_end exit=$command_status duration_s=$(( $(date '+%s') - started ))" || capture_status=1
    fi
    [[ "$command_status" -ne 0 ]] && return "$command_status"
    return "$capture_status"
)

print_service_commands() {
    local systemd_service="$1" openrc_service="$2"
    if [[ "${ID:-}" == alpine || "${ID_LIKE:-}" == alpine ]] || command -v rc-service >/dev/null 2>&1; then
        info "Restart / 重启: rc-service ${openrc_service} restart"
        info "Status / 状态: rc-service ${openrc_service} status"
    elif command -v systemctl >/dev/null 2>&1; then
        info "Restart / 重启: systemctl restart ${systemd_service}"
        info "Status / 状态: systemctl status ${systemd_service}"
    fi
}

separator() {
    display_result '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' "$cyan"
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
    echo "Detected interface / 找到网卡: $Public_IPv4 $Public_IPv6" >> "$LOG_FILE"
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
