#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

scripts=(nokey.sh nokey-common.sh realm.sh singbox.sh xray-socks.sh xray-warp.sh bbr.sh warp-helper.sh acme-cert.sh hysteria2.sh)
for script in "${scripts[@]}"; do
    [[ -x "$REPO_ROOT/$script" ]] || { echo "FAIL: $script is not executable"; exit 1; }
    bash -n "$REPO_ROOT/$script"
done

grep -q 'install_dependencies jq' "$REPO_ROOT/xray-socks.sh"
grep -q 'install_dependencies jq' "$REPO_ROOT/xray-warp.sh"

realm_output="$(bash "$REPO_ROOT/realm.sh" --remote=1.2.3.4:443 --dry-run)"
[[ "$realm_output" == *"Realm dry-run"* ]]

singbox_output="$(bash "$REPO_ROOT/singbox.sh" --dry-run)"
[[ "$singbox_output" == *"Sing-box dry-run"* ]]

bbr_output="$(bash "$REPO_ROOT/bbr.sh" --dry-run)"
[[ "$bbr_output" == *"BBR dry-run"* ]]

acme_output="$(bash "$REPO_ROOT/acme-cert.sh" --domain=example.com --dry-run)"
[[ "$acme_output" == *"ACME dry-run"* ]]

hysteria_output="$(bash "$REPO_ROOT/hysteria2.sh" --domain=example.com --dry-run)"
[[ "$hysteria_output" == *"Hysteria2 dry-run"* ]]
[[ "$hysteria_output" == *"Port:"* ]]
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
grep -q 'Mihomo/Clash config' "$REPO_ROOT/singbox.sh"

[[ -x "$REPO_ROOT/hysteria2.rc" ]]
grep -q 'ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml' "$REPO_ROOT/hysteria2.service"
awk '/configure_openrc_crash_restart/{found=1} found && /chmod 755/{ok=1} END{exit !ok}' "$REPO_ROOT/hysteria2.sh"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
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

echo "All feature entrypoint tests passed."
