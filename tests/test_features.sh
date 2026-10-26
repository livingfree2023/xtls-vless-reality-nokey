#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

scripts=(nokey.sh nokey-common.sh realm.sh xray-socks.sh xray-shadowsocks.sh xray-warp.sh bbr.sh warp-helper.sh acme-cert.sh hysteria2.sh)
for script in "${scripts[@]}"; do
    [[ -x "$REPO_ROOT/$script" ]] || { echo "FAIL: $script is not executable"; exit 1; }
    bash -n "$REPO_ROOT/$script"
done

grep -q 'install_dependencies jq' "$REPO_ROOT/xray-socks.sh"
grep -q 'install_dependencies jq' "$REPO_ROOT/xray-warp.sh"

realm_output="$(bash "$REPO_ROOT/realm.sh" --remote=1.2.3.4:443 --dry-run)"
[[ "$realm_output" == *"Realm dry-run"* ]]

bbr_output="$(bash "$REPO_ROOT/bbr.sh" --dry-run)"
[[ "$bbr_output" == *"BBR dry-run"* ]]

acme_output="$(bash "$REPO_ROOT/acme-cert.sh" --domain=example.com --dry-run)"
[[ "$acme_output" == *"ACME dry-run"* ]]

hysteria_output="$(bash "$REPO_ROOT/hysteria2.sh" --domain=example.com --dry-run)"
[[ "$hysteria_output" == *"Hysteria2 dry-run"* ]]
[[ "$hysteria_output" == *"Port:"* ]]
grep -q 'run_feature_script xray-shadowsocks.sh' "$REPO_ROOT/nokey.sh"
(
    set +u
    # shellcheck source=/dev/null
    source "$REPO_ROOT/xray-shadowsocks.sh"
    set -u
    local_global_ipv6_addresses() { printf '%s\n' '2001:db8::10' '2001:db8::11'; }
    ss_listen=""
    select_shadowsocks_ipv6
    [[ "$ss_listen" == '2001:db8::10' ]]
    ss_listen='::'
    if select_shadowsocks_ipv6 >/dev/null; then exit 1; fi
    ss_listen='2001:db8::11'
    select_shadowsocks_ipv6
    generate_shadowsocks_password
    [[ "$(printf '%s' "$ss_password" | base64 -d | wc -c | tr -d ' ')" -eq 16 ]]
    ss_port=8443
    ss_password='AAAAAAAAAAAAAAAAAAAAAA=='
    xray_config_path="$(mktemp /tmp/nokey-ss-config.XXXXXX)"
    patch_jq_source="$xray_config_path"
    printf '%s\n' '{"inbounds":[{"tag":"existing","port":443}],"outbounds":[{"protocol":"freedom"}]}' > "$xray_config_path"
    build_shadowsocks_config
    jq -e --arg tag "$SHADOWSOCKS_TAG" --arg listen "$ss_listen" \
        '.inbounds | length == 2 and .[0].tag == "existing" and .[1].tag == $tag and .[1].listen == $listen and .[1].settings.method == "2022-blake3-aes-128-gcm" and .[1].settings.network == "tcp,udp"' \
        "$patch_tmp_out" >/dev/null
    rm -f "$xray_config_path" "$patch_tmp_out"
)
hysteria_acme_output="$(HYSTERIA_CF_TOKEN=test-token bash "$REPO_ROOT/hysteria2.sh" --domain=example.com --dry-run)"
[[ "$hysteria_acme_output" == *"built-in ACME DNS-01"* ]]
[[ "$(bash "$REPO_ROOT/hysteria2.sh" --help)" == *"--cert-path=PATH"* ]]
[[ "$(bash "$REPO_ROOT/hysteria2.sh" --help)" == *"--key-path=PATH"* ]]
certificate_output="$(bash "$REPO_ROOT/hysteria2.sh" --domain=example.com --cert-path=/tmp/fullchain.pem --key-path=/tmp/private.key --dry-run)"
[[ "$certificate_output" == *"provided certificate and private key"* ]]
[[ "$certificate_output" == *"Certificate: /tmp/fullchain.pem"* ]]
grep -q 'https://get.hy2.sh/' "$REPO_ROOT/hysteria2.sh"
grep -q 'cloudflare_api_token' "$REPO_ROOT/hysteria2.sh"
grep -q 'type: dns' "$REPO_ROOT/hysteria2.sh"
grep -q 'HYSTERIA_CF_TOKEN' "$REPO_ROOT/nokey.sh"
grep -q 'print_service_commands' "$REPO_ROOT/nokey-common.sh"

[[ -x "$REPO_ROOT/hysteria2.rc" ]]
grep -q 'ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml' "$REPO_ROOT/hysteria2.service"
awk '/configure_openrc_crash_restart/{found=1} found && /chmod 755/{ok=1} END{exit !ok}' "$REPO_ROOT/hysteria2.sh"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
(
    # Exercise the pinned installer without network access or system writes.
    GITHUB_CMD=""
    # shellcheck source=/dev/null
    source "$REPO_ROOT/nokey-common.sh"
    yq_fixture="$fixture_dir/fake-yq"
    yq_target="$fixture_dir/installed-yq"
    printf '#!/bin/sh\nprintf "yq version %s\\n"\n' "$NOKEY_YQ_VERSION" > "$yq_fixture"
    chmod 755 "$yq_fixture"
    fixture_sha="$(xray_sha256_file "$yq_fixture")"
    xray_yq_expected_sha256() { printf '%s\n' "$fixture_sha"; }
    curl() {
        local arg="" output="" next=0
        for arg in "$@"; do
            if [[ "$next" -eq 1 ]]; then output="$arg"; break; fi
            [[ "$arg" == -o ]] && next=1
        done
        [[ -n "$output" ]] || return 1
        cp "$yq_fixture" "$output"
    }
    install_xray_yaml_tool "$yq_target"
    xray_yq_is_compatible "$yq_target"
    rm -f "$yq_target"
    xray_yq_expected_sha256() { printf '%064d\n' 0; }
    if install_xray_yaml_tool "$yq_target" >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$yq_target" ]]
    [[ -z "$(find "$fixture_dir" -name 'installed-yq.stage.*' -print)" ]]
)
mkdir -p "$fixture_dir/.acme.sh/example.com_ecc"
touch "$fixture_dir/.acme.sh/example.com_ecc/fullchain.cer" "$fixture_dir/.acme.sh/example.com_ecc/example.com.key"
touch "$fixture_dir/custom.crt" "$fixture_dir/custom.key"
(
    LOG_FILE="$fixture_dir/log"
    URL_FILE="$fixture_dir/url"
    ACME_HOME="$fixture_dir/.acme.sh"
    GITHUB_CMD=""
    # shellcheck source=/dev/null
    source "$REPO_ROOT/hysteria2.sh"
    domain=example.com
    find_certificate_pair
    [[ "$cert_path" == *"fullchain.cer" ]]
    [[ "$key_path" == *"example.com.key" ]]
    cert_path="$fixture_dir/custom.crt"
    key_path="$fixture_dir/custom.key"
    find_certificate_pair
    [[ "$cert_path" == *"custom.crt" ]]
    [[ "$key_path" == *"custom.key" ]]
    cert_path="$fixture_dir/missing.crt"
    key_path="$fixture_dir/missing.key"
    if prompt_for_certificates; then
        exit 1
    fi
    password=test-password
    port=443
    write_share_urls
    grep -q "type: hysteria2" "$URL_FILE"
)

[[ "$(bash "$REPO_ROOT/xray-socks.sh" --help)" == *"Usage: xray-socks.sh"* ]]
if command -v yq >/dev/null 2>&1; then
    (
        GITHUB_CMD=""
        # shellcheck source=/dev/null
        source "$REPO_ROOT/xray-socks.sh"
        xray_config_path="$fixture_dir/xray.yaml"
        printf '%s\n' 'inbounds: []' 'outbounds: []' > "$xray_config_path"
        remove_mode=0
        initialize_ip_from_netstack() { :; }
        add_socks_to_existing_config() { jq '.inbounds += [{"tag":"nokey-socks-1080","protocol":"socks","port":1080}]' "$patch_jq_source" > "$patch_tmp_out"; }
        restart_xray_service() { :; }
        output_socks_proxy() { :; }
        apply_socks_change
        yq -e '.inbounds[0].protocol == "socks"' "$xray_config_path" >/dev/null
    )
fi

echo "All feature entrypoint tests passed."
