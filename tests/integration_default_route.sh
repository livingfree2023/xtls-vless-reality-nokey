#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Opt-in real Xray/HTTPS test. Run this file with Bash, never source it or use bash -c.
# Requires Bash, jq, curl, ss, and Xray 26.10.21+ in PATH. No installer/service changes.
set -euo pipefail

INTEGRATION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTEGRATION_TMP=""
integration_xray_pid=""

integration_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

integration_stop_xray() {
    local attempt
    if [[ -n "$integration_xray_pid" ]]; then
        kill "$integration_xray_pid" 2>/dev/null || true
        for ((attempt=0; attempt<30; attempt++)); do
            kill -0 "$integration_xray_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$integration_xray_pid" 2>/dev/null; then
            kill -KILL "$integration_xray_pid" 2>/dev/null || true
        fi
        wait "$integration_xray_pid" 2>/dev/null || true
        integration_xray_pid=""
    fi
}

integration_cleanup() {
    integration_stop_xray
    [[ -z "$INTEGRATION_TMP" ]] || rm -rf "$INTEGRATION_TMP"
}

trap integration_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

for integration_command in bash jq curl ss xray; do
    command -v "$integration_command" >/dev/null 2>&1 || integration_fail "$integration_command is required; real integration was not run"
done
[[ -z "${BASH_EXECUTION_STRING:-}" ]] || integration_fail 'Run the test file with Bash rather than bash -c'
INTEGRATION_XRAY="$(command -v xray)"
integration_version="$("$INTEGRATION_XRAY" version | awk 'NR == 1 {print $2}')"
if [[ "$integration_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    integration_version_number=$((10#${BASH_REMATCH[1]} * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]}))
    [[ "$integration_version_number" -ge 261021 ]] || integration_fail 'Xray 26.10.21+ is required; installed binary was not changed'
else
    integration_fail 'Could not confirm Xray version; real integration was not run'
fi

INTEGRATION_TMP="$(mktemp -d "${TMPDIR:-/tmp}/nokey-egress.XXXXXX")"
chmod 700 "$INTEGRATION_TMP"
cd "$INTEGRATION_TMP"
# Source from an actual file so nokey's BASH_EXECUTION_STRING main guard stays off.
# shellcheck source=/dev/null
source "$INTEGRATION_ROOT/nokey.sh"

# Return only the address family; actual external addresses never reach stdout.
integration_response_family() {
    local value octet
    value="$(awk '/^ip=/ {sub(/^ip=/, ""); print; found=1; exit} END {if (!found) exit 1}' "$INTEGRATION_TMP/response" 2>/dev/null)" || value="$(tr -d '\r\n ' < "$INTEGRATION_TMP/response")"
    if [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        for octet in ${value//./ }; do
            [[ ${#octet} -le 3 ]] && ((10#$octet <= 255)) || return 1
        done
        printf '4\n'
    elif [[ "$value" == *:* && "$value" =~ ^[0-9a-fA-F:.]+$ ]]; then
        printf '6\n'
    else
        return 1
    fi
}

integration_request() {
    local url="$1" proxy="${2:-}" family="${3:-}"
    local -a args=(--silent --show-error --fail --max-time 18 --connect-timeout 8)
    if [[ -n "$family" ]]; then args+=("-$family"); fi
    if [[ -n "$proxy" ]]; then
        args+=(--noproxy '' --socks5-hostname "$proxy")
    else
        args+=(--noproxy '*')
    fi
    curl "${args[@]}" "$url" > "$INTEGRATION_TMP/response" 2> "$INTEGRATION_TMP/curl-error" || return $?
    integration_response_family
}

integration_port_in_use() {
    ss -lnt | awk -v port="$1" 'NR > 1 {address=$4; sub(/^.*:/, "", address); if (address == port) found=1} END {exit !found}'
}

integration_choose_port() {
    local attempt candidate
    for ((attempt=0; attempt<100; attempt++)); do
        candidate=$((20000 + RANDOM))
        if ! integration_port_in_use "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

egress_ipv4_available=0
egress_ipv6_available=0
for integration_family in 4 6; do
    if integration_actual="$(integration_request 'https://one.one.one.one/cdn-cgi/trace' '' "$integration_family")" && [[ "$integration_actual" == "$integration_family" ]]; then
        if [[ "$integration_family" == 4 ]]; then egress_ipv4_available=1; else egress_ipv6_available=1; fi
        printf 'Real IPv%s HTTPS egress: available\n' "$integration_family"
    else
        printf 'SKIP: real IPv%s HTTPS egress unavailable\n' "$integration_family"
    fi
done
[[ "$egress_ipv4_available" -eq 1 || "$egress_ipv6_available" -eq 1 ]] || integration_fail 'No usable real HTTPS egress'

# Validate the complete generated REALITY template using fresh disposable keys.
# Parsing does not bind its inbound or touch installed configs/services.
export XRAY_LOCATION_ASSET="${XRAY_LOCATION_ASSET:-/usr/local/share/xray}"
port=443
domain=www.cloudflare.com
reality_dest_port=443
uuid="$("$INTEGRATION_XRAY" uuid)"
keys="$("$INTEGRATION_XRAY" x25519)"
private_key="$(extract_private_key_from_x25519_output "$keys")"
shortid=1234567890abcdef
mldsa_enabled=0
mldsa65Seed=""
xray_config_path="$INTEGRATION_TMP/template.json"
for integration_template_family in 4 6; do
    if [[ "$integration_template_family" == 4 && "$egress_ipv4_available" -eq 0 ]] || [[ "$integration_template_family" == 6 && "$egress_ipv6_available" -eq 0 ]]; then continue; fi
    default_route_choice="$integration_template_family"
    build_xray_config > "$INTEGRATION_TMP/template-output" 2>&1 || integration_fail 'Could not stage REALITY template'
    if ! "$INTEGRATION_XRAY" run -test -format json -c stdin: < "$pending_xray_config" > "$INTEGRATION_TMP/template-check.log" 2>&1; then
        tail -n 15 "$INTEGRATION_TMP/template-check.log" | sanitize_log_stream >&2
        integration_fail 'Actual Xray rejected complete REALITY template'
    fi
    [[ ! -e "$xray_config_path" ]] || integration_fail 'Template validation unexpectedly committed config'
    if grep -qF "$private_key" "$LOG_FILE"; then integration_fail 'Template private key entered diagnostic log'; fi
    rm -f "$pending_xray_config"
    printf 'PASS: complete REALITY template | IPv%s preference | actual Xray validation\n' "$integration_template_family"
done

integration_probe() {
    local preference="$1" label="$2" url="$3" expected="$4" hosts="${5:-}"
    [[ -n "$hosts" ]] || hosts='{}'
    local port attempt ready=0 actual
    default_route_choice="$preference"
    build_default_route_settings || integration_fail "Cannot build IPv${preference} settings"
    port="$(integration_choose_port)" || integration_fail 'No unused loopback test port found'
    jq -n --argjson outbound "$default_outbound_json" --argjson servers "$dns_servers_json" \
        --arg strategy "$dns_query_strategy" --argjson port "$port" --argjson hosts "$hosts" '
        {log:{loglevel:"warning"},
         inbounds:[{listen:"127.0.0.1",port:$port,protocol:"socks",settings:{auth:"noauth"}}],
         outbounds:[$outbound],dns:{servers:$servers,queryStrategy:$strategy,hosts:$hosts}}
    ' > "$INTEGRATION_TMP/config.json" || integration_fail 'Cannot render isolated Xray configuration'
    chmod 600 "$INTEGRATION_TMP/config.json"
    "$INTEGRATION_XRAY" run -test -c "$INTEGRATION_TMP/config.json" > "$INTEGRATION_TMP/config-test.log" 2>&1 \
        || integration_fail "Actual Xray rejected IPv${preference} generated configuration"
    "$INTEGRATION_XRAY" run -c "$INTEGRATION_TMP/config.json" > "$INTEGRATION_TMP/runtime.log" 2>&1 &
    integration_xray_pid=$!
    for ((attempt=0; attempt<50; attempt++)); do
        kill -0 "$integration_xray_pid" 2>/dev/null || integration_fail 'Isolated Xray exited during startup'
        if integration_port_in_use "$port"; then ready=1; break; fi
        sleep 0.1
    done
    [[ "$ready" -eq 1 ]] || integration_fail 'Isolated loopback SOCKS listener was not ready'
    actual="$(integration_request "$url" "127.0.0.1:$port")" || integration_fail "prefer IPv${preference}: ${label} HTTPS request failed"
    [[ "$actual" == "$expected" ]] || integration_fail "prefer IPv${preference}: ${label} expected IPv${expected}, got IPv${actual}"
    integration_stop_xray
    printf 'PASS: prefer IPv%s | %s | actual IPv%s HTTPS\n' "$preference" "$label" "$actual"
}

for integration_preference in 4 6; do
    if [[ "$integration_preference" == 4 && "$egress_ipv4_available" -eq 0 ]] || [[ "$integration_preference" == 6 && "$egress_ipv6_available" -eq 0 ]]; then
        printf 'SKIP: IPv%s preference cases; family unavailable\n' "$integration_preference"
        continue
    fi
    integration_probe "$integration_preference" 'dual-stack destination' 'https://one.one.one.one/cdn-cgi/trace' "$integration_preference"
    if [[ "$egress_ipv4_available" -eq 1 ]]; then
        integration_probe "$integration_preference" 'real IPv4-only destination' 'https://ipv4.icanhazip.com' 4
    else
        printf 'SKIP: real IPv4-only destination; IPv4 unavailable\n'
    fi
    if [[ "$egress_ipv6_available" -eq 1 ]]; then
        integration_probe "$integration_preference" 'real IPv6-only destination' 'https://ipv6.icanhazip.com' 6
    else
        printf 'SKIP: real IPv6-only destination; IPv6 unavailable\n'
    fi
done

if [[ "$egress_ipv4_available" -eq 1 && "$egress_ipv6_available" -eq 1 ]]; then
    integration_probe 6 'unreachable preferred IPv6 falls back' 'https://one.one.one.one/cdn-cgi/trace' 4 \
        '{"one.one.one.one":["2001:db8::1","1.1.1.1"]}'
    integration_probe 4 'unreachable preferred IPv4 falls back' 'https://one.one.one.one/cdn-cgi/trace' 6 \
        '{"one.one.one.one":["192.0.2.1","2606:4700:4700::1111"]}'
else
    printf 'SKIP: dual-stack failover cases; both real address families are required\n'
fi
printf 'Real Xray egress integration completed; temporary listener and files will be removed.\n'
