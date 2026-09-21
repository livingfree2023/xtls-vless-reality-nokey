#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2317,SC2030,SC2031  # mock globals/functions read indirectly by sourced nokey.sh code; subshell-write/read pairs are intentional
set -euo pipefail

# *_url vars below are assigned inside generate_share_links (sourced script).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/nokey.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Test 1: netstack=4 resolves IP after detection values exist
netstack=""
ip=""
IPv4="198.51.100.10"
IPv6="2001:db8::10"
port="12345"
domain="example.com"
caddy_mode=0
initialize_variables >/dev/null 2>&1 || fail "initialize_variables auto mode"
[[ "$netstack" == "4" ]] || fail "auto netstack should prefer IPv4"
[[ "$ip" == "$IPv4" ]] || fail "auto netstack should assign IPv4 ip"
pass "auto netstack IP assignment"

# Test 2: explicit netstack=6 assigns IPv6 IP
netstack="6"
ip=""
IPv4="198.51.100.11"
IPv6="2001:db8::11"
port="12346"
domain="example.com"
caddy_mode=0
initialize_variables >/dev/null 2>&1 || fail "initialize_variables netstack=6"
[[ "$ip" == "$IPv6" ]] || fail "netstack=6 should assign IPv6 ip"
pass "explicit netstack=6 IP assignment"

# Test 3: public key extraction from xray x25519 output
keys_sample=$'PrivateKey: PRIVATE_VALUE\nPublicKey: PUBLIC_VALUE'
extracted="$(extract_public_key_from_x25519_output "$keys_sample")"
[[ "$extracted" == "PUBLIC_VALUE" ]] || fail "public key extraction should return PUBLIC_VALUE"
pass "public key extraction"

# Test 4: key extraction supports spaced labels used by some xray builds
keys_sample_spaced=$'Private key: PRIVATE_SPACED\nPublic key: PUBLIC_SPACED'
extracted_private="$(extract_private_key_from_x25519_output "$keys_sample_spaced")"
extracted_public="$(extract_public_key_from_x25519_output "$keys_sample_spaced")"
[[ "$extracted_private" == "PRIVATE_SPACED" ]] || fail "private key extraction should support 'Private key:' format"
[[ "$extracted_public" == "PUBLIC_SPACED" ]] || fail "public key extraction should support 'Public key:' format"
pass "spaced label key extraction"

# Test 5: architecture mapping helper
[[ "$(resolve_arch_binary_name x86_64)" == "xray_amd64" ]] || fail "x86_64 should map to xray_amd64"
[[ "$(resolve_arch_binary_name amd64)" == "xray_amd64" ]] || fail "amd64 should map to xray_amd64"
[[ "$(resolve_arch_binary_name aarch64)" == "xray_arm64" ]] || fail "aarch64 should map to xray_arm64"
[[ "$(resolve_arch_binary_name arm64)" == "xray_arm64" ]] || fail "arm64 should map to xray_arm64"
if resolve_arch_binary_name mips >/dev/null 2>&1; then
  fail "unsupported architecture should fail"
fi
pass "architecture mapping helper"

# Test 6: OS family helper
ID="alpine"
ID_LIKE=""
[[ "$(resolve_os_family)" == "alpine" ]] || fail "ID=alpine should map to alpine"
ID="debian"
ID_LIKE="debian"
[[ "$(resolve_os_family)" == "debian/systemd-compatible" ]] || fail "debian-like should map to debian/systemd-compatible"
pass "os family helper"

service_policy_dir="$(mktemp -d)"
cat > "$service_policy_dir/openrc" <<'EOF'
#!/sbin/openrc-run
command="/usr/local/bin/example"
command_background="yes"
EOF
configure_openrc_crash_restart "$service_policy_dir/openrc"
configure_openrc_crash_restart "$service_policy_dir/openrc"
[[ "$(grep -c '^supervisor=supervise-daemon$' "$service_policy_dir/openrc")" -eq 1 ]] || fail "OpenRC service should use supervise-daemon"
[[ "$(grep -c '^respawn_delay=5$' "$service_policy_dir/openrc")" -eq 1 ]] || fail "OpenRC service should delay crash respawns"
[[ "$(grep -c '^respawn_max=0$' "$service_policy_dir/openrc")" -eq 1 ]] || fail "OpenRC service should keep respawning after crashes"
if grep -q '^command_background=' "$service_policy_dir/openrc"; then
  fail "OpenRC supervised service should remain in the foreground"
fi

cat > "$service_policy_dir/systemd" <<'EOF'
[Service]
ExecStart=/usr/local/bin/example
Restart=no
RestartSec=30s

[Install]
WantedBy=multi-user.target
EOF
configure_systemd_crash_restart "$service_policy_dir/systemd"
configure_systemd_crash_restart "$service_policy_dir/systemd"
[[ "$(grep -c '^Restart=on-failure$' "$service_policy_dir/systemd")" -eq 1 ]] || fail "systemd service should restart after crashes"
[[ "$(grep -c '^RestartSec=5s$' "$service_policy_dir/systemd")" -eq 1 ]] || fail "systemd service should delay crash restarts"
[[ "$(sed -n '/^\[Service\]$/,/^\[Install\]$/p' "$service_policy_dir/systemd" | grep -c '^Restart=on-failure$')" -eq 1 ]] || fail "systemd restart policy should be in the Service section"
rm -rf "$service_policy_dir"
pass "service crash restart policies"

# Test 7: dry-run output includes expected download and service lines
ID="alpine"
ID_LIKE=""
dry_run_out="$(dry_run_preview 2>&1 || true)"
echo "$dry_run_out" | grep -Eq 'releases/latest/download/xray_(amd64|arm64) -> /usr/local/bin/xray' || fail "dry-run should include xray download path"
[[ "$dry_run_out" == *"releases/latest/download/geoip.dat -> /usr/local/share/xray/geoip.dat"* ]] || fail "dry-run should include geoip.dat download path"
[[ "$dry_run_out" == *"releases/latest/download/geosite.dat -> /usr/local/share/xray/geosite.dat"* ]] || fail "dry-run should include geosite.dat download path"
[[ "$dry_run_out" == *"/etc/init.d/xray"* ]] || fail "dry-run alpine should include OpenRC path"
pass "dry-run preview output"

# Test 8: BBR guard/message exists for readonly environments
enable_bbr_source="$(declare -f enable_bbr)"
[[ "$enable_bbr_source" == *'[[ ! -w /etc/sysctl.conf ]]'* ]] || fail "enable_bbr should check writable sysctl.conf"
[[ "$enable_bbr_source" == *'/etc/sysctl.conf is not writable'* ]] || fail "enable_bbr should expose clear skip message"
pass "bbr readonly guard present"

# Test 8b: enable_bbr verifies live kernel state instead of trusting sysctl -p exit code
sysctl_apply_cmd="sysctl -p >> \"\$LOG_FILE\" 2>&1 || true"
[[ "$enable_bbr_source" == *'cat /proc/sys/net/ipv4/tcp_congestion_control'* ]] || fail "enable_bbr should read back the live tcp_congestion_control value"
[[ "$enable_bbr_source" == *'BBR not active'* ]] || fail "enable_bbr should warn when BBR did not take effect"
[[ "$enable_bbr_source" == *"$sysctl_apply_cmd"* ]] || fail "enable_bbr should not abort when sysctl -p reports failure"
pass "bbr live-state verification present"

# Test 9: initialize_ip_from_netstack auto-detects IPv4 when IPv4/IPv6 empty
if (
  ip=""
  IPv4=""
  IPv6=""
  netstack=""
  detect_network_interfaces() {
      IPv4="203.0.113.10"
  }
  initialize_ip_from_netstack >/dev/null 2>&1
  [[ -n "$ip" ]]
  [[ "$ip" == "203.0.113.10" ]]
); then
  pass "netstack fallback detection"
else
  fail "initialize_ip_from_netstack should trigger detection when IPv4/IPv6 empty"
fi

# Test 10: netstack=6 yields non-empty ip when IPv6 is present (defensive detection)
netstack="6"
ip=""
IPv4=""
IPv6="2001:db8::20"
port="12348"
domain="example.com"
caddy_mode=0
initialize_variables >/dev/null 2>&1 || fail "initialize_variables netstack=6 with IPv6"
[[ -n "$ip" ]] || fail "ip should be non-empty when netstack=6 and IPv6 is present"
[[ "$ip" == "$IPv6" ]] || fail "ip should match IPv6"
pass "netstack=6 IP validation after detection"

# Test 11: parse_args rejects invalid --port/--netstack/unknown flag (non-zero exit)
if (parse_args --port=abc >/dev/null 2>&1); then
  fail "invalid --port should exit non-zero"
fi
if (parse_args --netstack=9 >/dev/null 2>&1); then
  fail "invalid --netstack should exit non-zero"
fi
if (parse_args --unknown-flag >/dev/null 2>&1); then
  fail "unknown flag should exit non-zero"
fi
pass "parse_args rejects invalid input"

# Test 12: parse_args accepts valid --port
port=""
arg_port_set=0
parse_args --port=8443
[[ "$port" == "8443" ]] || fail "--port=8443 should set port=8443"
pass "parse_args valid --port"

arg_count=0
menu_mode=0
parse_args --menu
[[ "$menu_mode" -eq 1 ]] || fail "--menu should set menu_mode=1"
pass "parse_args --menu"

# Test 13: parse_args --remove sets remove_mode without early exit
remove_mode=0
parse_args --remove
[[ "$remove_mode" -eq 1 ]] || fail "--remove should set remove_mode=1"
pass "parse_args --remove flag"

# Test 14: IPv6 vless share URL brackets the address
share_dir="$(mktemp -d)"
if (
  cd "$share_dir" || exit 1
  sing_box_mode=0
  netstack="6"
  ip="2001:db8::1"
  port="443"
  domain="example.com"
  uuid="test-uuid"
  fingerprint="chrome"
  public_key="test-pbk"
  shortid="abcd"
  current_hostname="testhost"
  mldsa_enabled=0
  generate_share_links >/dev/null 2>&1
  [[ "$vless_reality_url_short" == *"@[2001:db8::1]:443"* ]]
); then
  pass "IPv6 share URL bracketing"
else
  fail "IPv6 share URL should bracket the address"
fi
rm -rf "$share_dir"

# Test 15: mldsa URL uses &pqv= before # fragment, never &# 
share_dir="$(mktemp -d)"
if (
  cd "$share_dir" || exit 1
  sing_box_mode=0
  netstack="4"
  ip="198.51.100.10"
  port="443"
  domain="example.com"
  uuid="test-uuid"
  fingerprint="chrome"
  public_key="test-pbk"
  shortid="abcd"
  current_hostname="testhost"
  mldsa_enabled=1
  mldsa65Verify="VERIFYVALUE"
  generate_share_links >/dev/null 2>&1
  [[ "$vless_reality_mldsa_url" == *"&pqv=VERIFYVALUE#testhost" ]] \
    && [[ "$vless_reality_mldsa_url" != *"&#"* ]]
); then
  pass "mldsa share URL fragment"
else
  fail "mldsa URL should use &pqv= then #, never &#"
fi
rm -rf "$share_dir"

# Test 16: URL_FILE stays ANSI-free even on a TTY (colors active)
if command -v script >/dev/null 2>&1 && command -v mktemp >/dev/null 2>&1; then
  pty_dir="$(mktemp -d)"
  tmp_script="$(mktemp)"
  cat > "$tmp_script" <<'EOF'
cd "$1" || exit 1
source "$2" || exit 1
sing_box_mode=0
netstack=4
ip='198.51.100.10'
port='12345'
domain='example.com'
uuid='test-uuid'
fingerprint='chrome'
public_key='test-pbk'
shortid='abcd'
current_hostname='testhost'
mldsa_enabled=0
generate_share_links >/dev/null 2>&1
EOF
  script -qec "bash '$tmp_script' '$pty_dir' '$REPO_ROOT/nokey.sh'" /dev/null >/dev/null 2>&1 \
    || script -qc "bash '$tmp_script' '$pty_dir' '$REPO_ROOT/nokey.sh'" /dev/null >/dev/null 2>&1 \
    || true
  if [[ -s "$pty_dir/nokey.url" ]] && ! LC_ALL=C grep -qF "$(printf '\033')" "$pty_dir/nokey.url"; then
    pass "URL_FILE stays ANSI-free on a TTY"
  else
    fail "URL_FILE must not contain ANSI escapes even on a TTY"
  fi
  rm -rf "$pty_dir" "$tmp_script"
else
  pass "URL_FILE plainness skipped (script/mktemp unavailable)"
fi

# Test 17: is_port_reusable returns 0 when nothing is listening (free port)
if (
  ss() { return 0; }  # mock: no listeners
  is_port_reusable 443 xray "$SERVICE_NAME" "$SERVICE_NAME_ALPINE"
); then
  pass "port reusable when free"
else
  fail "free port should be reported reusable"
fi

# Test 18: is_port_reusable returns 1 when another process owns the port
if (
  ss() { echo "LISTEN 0 128 0.0.0.0:443 users:((\"nginx\"))"; }
  ! is_port_reusable 443 xray "$SERVICE_NAME" "$SERVICE_NAME_ALPINE"
); then
  pass "port not reusable when owned by another process"
else
  fail "foreign-owned port must not be reusable"
fi

# Test 19: is_port_reusable returns 0 when xray already owns the port
if (
  ss() { echo "LISTEN 0 128 0.0.0.0:443 users:((\"xray\"))"; }
  is_port_reusable 443 xray "$SERVICE_NAME" "$SERVICE_NAME_ALPINE"
); then
  pass "port reusable when owned by xray"
else
  fail "xray-owned port should be reusable"
fi

# Test 20: initialize_variables prefers 443 when it is reusable
if (
  is_port_reusable() { return 0; }  # mock: 443 deemed reusable
  netstack=""
  ip=""
  IPv4="198.51.100.30"
  IPv6="2001:db8::30"
  port=""
  domain="example.com"
  caddy_mode=0
  initialize_variables >/dev/null 2>&1
  [[ "$port" == "443" ]]
); then
  pass "443 preferred when reusable"
else
  fail "port should be 443 when reusable"
fi

# Test 21: initialize_variables falls back to a random port >= 10000 when 443 is taken
if (
  is_port_reusable() { return 1; }  # mock: 443 occupied by another process
  netstack=""
  ip=""
  IPv4="198.51.100.31"
  IPv6="2001:db8::31"
  port=""
  domain="example.com"
  caddy_mode=0
  initialize_variables >/dev/null 2>&1
  [[ "$port" != "443" && "$port" -ge 10000 ]]
); then
  pass "random fallback when 443 occupied"
else
  fail "port should be random >= 10000 when 443 is taken"
fi

# Test 22: probe_reality_target accepts a candidate whose curl probe reports h2
# and records TLS-handshake latency into probe_latency_ms
if (
  curl() { printf '2|0.045\n'; }  # mock: %{http_version}|%{time_appconnect} -> h2, 45ms
  probe_reality_target www.cloudflare.com
  [[ "$probe_latency_ms" == "45" ]]
); then
  pass "probe accepts h2 target with latency"
else
  fail "h2-negotiating target should be accepted and latency recorded"
fi

# Test 23: probe_reality_target rejects a candidate whose curl probe fails
if (
  curl() { return 1; }  # mock: connection/TLS failure
  probe_reality_target www.cloudflare.com
); then
  fail "failed probe must not be accepted"
else
  pass "probe rejects failed target"
fi

# Test 24: pick_default_domain picks the first feasible candidate, skipping failures
if (
  probe_reality_target() {
    [[ "$1" == "www.amazon.com" ]] && return 0
    return 1
  }
  domain=""
  pick_default_domain >/dev/null 2>&1
  [[ "$domain" == "www.amazon.com" ]]
); then
  pass "picker selects first feasible candidate"
else
  fail "picker should select first feasible candidate"
fi

# Test 25: pick_default_domain falls back to DEFAULT_DOMAIN when nothing is feasible
if (
  probe_reality_target() { return 1; }
  domain=""
  pick_default_domain >/dev/null 2>&1
  [[ "$domain" == "$DEFAULT_DOMAIN" ]]
); then
  pass "picker falls back to default domain"
else
  fail "picker should fall back to DEFAULT_DOMAIN when scan finds nothing"
fi

# Test 26: detect_network_interfaces falls back to ip.sb when the cloudflare v6 probe is empty
if (
  unset IPv4 IPv6
  curl() {
    if [[ "$1" == "-4s" ]]; then
      printf 'ip=203.0.113.10\n'
    elif [[ "$*" == *"ip.sb"* ]]; then
      printf '2001:db8::10\n'
    else
      printf ''  # cloudflare v6 trace probe returns empty -> triggers ip.sb fallback
    fi
  }
  detect_network_interfaces >/dev/null 2>&1
  [[ "$IPv4" == "203.0.113.10" && "$IPv6" == "2001:db8::10" ]]
); then
  pass "ip.sb fallback detection"
else
  fail "IPv6 should fall back to ip.sb when cloudflare v6 probe is empty"
fi

# Test 27: dual-stack box emits IPv6 share URL + clash entry when netstack=4
share_dir="$(mktemp -d)"
if (
  cd "$share_dir" || exit 1
  sing_box_mode=0
  netstack="4"
  ip="198.51.100.10"
  IPv6="2001:db8::10"
  port="443"
  domain="example.com"
  uuid="test-uuid"
  fingerprint="chrome"
  public_key="test-pbk"
  shortid="abcd"
  current_hostname="testhost"
  mldsa_enabled=0
  generate_ipv6_variants >/dev/null 2>&1
  [[ -f "$URL_FILE" ]] \
    && grep -q "vless://test-uuid@\[2001:db8::10\]:443" "$URL_FILE" \
    && grep -q "#testhost-ipv6" "$URL_FILE" \
    && grep -q -- "- name: testhost-ipv6" "$URL_FILE" \
    && grep -q "server: 2001:db8::10" "$URL_FILE" \
    && grep -q "support-x25519mlkem768: true" "$URL_FILE"
); then
  pass "dual-stack IPv6 variants"
else
  fail "netstack=4 with IPv6 detected should emit IPv6 share URL and clash entry"
fi
rm -rf "$share_dir"

# Test 28: IPv6 variants skipped when netstack=6 (primary is already IPv6)
share_dir="$(mktemp -d)"
if (
  cd "$share_dir" || exit 1
  sing_box_mode=0
  netstack="6"
  ip="[2001:db8::10]"
  IPv6="2001:db8::10"
  port="443"
  domain="example.com"
  uuid="test-uuid"
  fingerprint="chrome"
  public_key="test-pbk"
  shortid="abcd"
  current_hostname="testhost"
  mldsa_enabled=0
  generate_ipv6_variants >/dev/null 2>&1
  [[ ! -f "$URL_FILE" ]]
); then
  pass "IPv6 variants skipped on netstack=6"
else
  fail "netstack=6 should not emit duplicate IPv6 variants"
fi
rm -rf "$share_dir"

# Test 29: parse_args --add-limiter sets add_limiter_mode (standalone)
if (
  arg_count=0
  add_limiter_mode=0
  parse_args --add-limiter
  [[ "$add_limiter_mode" -eq 1 ]]
); then
  pass "parse_args --add-limiter"
else
  fail "--add-limiter should set add_limiter_mode=1"
fi

# Test 30: parse_args --change-sni sets change_sni_mode (standalone)
if (
  arg_count=0
  change_sni_mode=0
  parse_args --change-sni
  [[ "$change_sni_mode" -eq 1 ]]
); then
  pass "parse_args --change-sni"
else
  fail "--change-sni should set change_sni_mode=1"
fi

# Test 31: parse_args rejects --add-limiter combined with another flag
if (
  arg_count=0
  parse_args --add-limiter --port=8443 >/dev/null 2>&1
); then
  fail "--add-limiter with another flag should be rejected"
else
  pass "--add-limiter rejects other flags"
fi

# Test 32: parse_args rejects --add-limiter and --change-sni together
if (
  arg_count=0
  parse_args --add-limiter --change-sni >/dev/null 2>&1
); then
  fail "--add-limiter --change-sni together should be rejected"
else
  pass "patch modes reject each other"
fi

# Test 33: add_limiter_to_existing_config injects limitFallback objects with
# randomized values in the documented 85%-115% band (106250-143750 / 212500-287500)
if command -v jq >/dev/null 2>&1; then
  patch_dir="$(mktemp -d)"
  cat > "$patch_dir/config.json" <<'JSON'
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {"clients": [{"id": "test-uuid"}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.amazon.com:443",
        "xver": 0,
        "serverNames": ["www.amazon.com"],
        "privateKey": "PRIV",
        "shortIds": ["abcd"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
JSON
  if (
    xray_config_path="$patch_dir/config.json"
    patch_jq_source=""
    patch_cleanup=""
    resolve_jq_config_source
    patch_tmp_out="$(mktemp)"
    add_limiter_to_existing_config
    up="$(jq -r '.inbounds[0].streamSettings.realitySettings.limitFallbackUpload.bytesPerSec' "$patch_tmp_out")"
    up_burst="$(jq -r '.inbounds[0].streamSettings.realitySettings.limitFallbackUpload.burstBytesPerSec' "$patch_tmp_out")"
    down="$(jq -r '.inbounds[0].streamSettings.realitySettings.limitFallbackDownload.bytesPerSec' "$patch_tmp_out")"
    [[ "$up" -ge 106250 && "$up" -le 143750 ]]
    [[ "$up_burst" -ge 212500 && "$up_burst" -le 287500 ]]
    [[ "$down" -ge 106250 && "$down" -le 143750 ]]
  ); then
    pass "add-limiter injects fallback limiters"
  else
    fail "add_limiter_to_existing_config should add limitFallbackUpload/limitFallbackDownload"
  fi
  rm -rf "$patch_dir"
else
  pass "add-limiter jq test skipped (jq unavailable)"
fi

# Test 34: change_sni_in_existing_config swaps dest host + serverNames[0],
# preserving the existing dest port
if command -v jq >/dev/null 2>&1; then
  patch_dir="$(mktemp -d)"
  cat > "$patch_dir/config.json" <<'JSON'
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {"clients": [{"id": "test-uuid"}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.amazon.com:8443",
        "xver": 0,
        "serverNames": ["www.amazon.com"],
        "privateKey": "PRIV",
        "shortIds": ["abcd"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
JSON
  if (
    xray_config_path="$patch_dir/config.json"
    patch_jq_source=""
    patch_cleanup=""
    resolve_jq_config_source
    patch_tmp_out="$(mktemp)"
    pick_default_domain() { domain="www.nvidia.com"; }  # mock: fixed pick, no probe
    change_sni_in_existing_config
    dest="$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$patch_tmp_out")"
    server="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$patch_tmp_out")"
    [[ "$dest" == "www.nvidia.com:8443" ]]
    [[ "$server" == "www.nvidia.com" ]]
  ); then
    pass "change-sni swaps host + serverName, keeps port"
  else
    fail "change_sni_in_existing_config should swap dest host and serverNames[0] while preserving port"
  fi
  rm -rf "$patch_dir"
else
  pass "change-sni jq test skipped (jq unavailable)"
fi

# Test 35: resolve_jq_config_source strips JSONC comments into a parseable temp copy
if command -v jq >/dev/null 2>&1; then
  patch_dir="$(mktemp -d)"
  cat > "$patch_dir/config.json" <<'JSON'
{
  // comment line
  "inbounds": []
}
JSON
  if (
    xray_config_path="$patch_dir/config.json"
    patch_jq_source=""
    patch_cleanup=""
    resolve_jq_config_source
    [[ -n "$patch_jq_source" && "$patch_jq_source" != "$xray_config_path" ]]
    jq empty "$patch_jq_source"
    rm -f "$patch_cleanup"
  ); then
    pass "resolve_jq_config_source strips JSONC"
  else
    fail "resolve_jq_config_source should produce a parseable stripped copy for JSONC configs"
  fi
  rm -rf "$patch_dir"
else
  pass "jsonc resolution test skipped (jq unavailable)"
fi

# Test 36: parse_args accepts --addsocks as an Xray feature flag
if (
  arg_count=0
  addsocks_mode=0
  parse_args --addsocks
  [[ "$addsocks_mode" -eq 1 ]]
); then
  pass "parse_args --addsocks"
else
  fail "--addsocks should set addsocks_mode=1"
fi

if (
  arg_count=0
  addsocks_mode=0
  parse_args --addsocks --netstack=6 >/dev/null 2>&1
); then
  fail "--addsocks with another flag should be rejected"
else
  pass "--addsocks rejects other flags"
fi

# Test 37: SOCKS generation creates random URL-safe credentials and valid Xray JSON
if command -v jq >/dev/null 2>&1; then
  if (
    port=443
    netstack=6
    socks_port=""
    socks_username=""
    socks_password=""
    is_tcp_port_unused() { return 0; }
    prepare_socks_inbound
    [[ "$socks_port" -ge 10000 && "$socks_port" -le 60000 ]]
    [[ "$socks_port" != "$port" ]]
    [[ "$socks_username" =~ ^nokey[0-9a-f]{8}$ ]]
    [[ "$socks_password" =~ ^[0-9a-f]{24}$ ]]
    jq -e '.protocol == "socks" and .settings.auth == "password" and (.settings.users | length == 1)' <<< "$socks_inbound_json" >/dev/null
    [[ "$(jq -r '.listen' <<< "$socks_inbound_json")" == "::" ]]
  ); then
    pass "SOCKS inbound generation"
  else
    fail "prepare_socks_inbound should create valid random SOCKS settings"
  fi

  # Test 38: patching appends the SOCKS inbound without changing existing inbounds
  socks_patch_dir="$(mktemp -d)"
  cat > "$socks_patch_dir/config.json" <<'JSON'
{
  "inbounds": [{"tag": "existing", "port": 443, "protocol": "vless"}],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
JSON
  if (
    port=""
    patch_jq_source="$socks_patch_dir/config.json"
    patch_tmp_out="$socks_patch_dir/patched.json"
    socks_port=""
    is_tcp_port_unused() { return 0; }
    add_socks_to_existing_config
    [[ "$(jq -r '.inbounds[0].tag' "$patch_tmp_out")" == "existing" ]]
    [[ "$(jq -r '.inbounds[0].port' "$patch_tmp_out")" == "443" ]]
    [[ "$(jq -r '.inbounds[1].protocol' "$patch_tmp_out")" == "socks" ]]
    [[ "$(jq -r '.outbounds[0].tag' "$patch_tmp_out")" == "direct" ]]
  ); then
    pass "--addsocks preserves existing config entries"
  else
    fail "add_socks_to_existing_config should only append one inbound"
  fi
  rm -rf "$socks_patch_dir"
else
  pass "SOCKS jq tests skipped (jq unavailable)"
fi

# Test 39: SOCKS output includes the proxy URL and ipinfo curl command in nokey.url
socks_output_dir="$(mktemp -d)"
if (
  cd "$socks_output_dir" || exit 1
  ip="2001:db8::50"
  socks_port=23456
  socks_username="nokeyuser"
  socks_password="secret"
  output_socks_proxy >/dev/null
  grep -qF "socks5h://nokeyuser:secret@[2001:db8::50]:23456" "$URL_FILE"
  grep -qF "curl --proxy 'socks5h://nokeyuser:secret@[2001:db8::50]:23456' https://ipinfo.io" "$URL_FILE"
); then
  pass "SOCKS proxy output"
else
  fail "output_socks_proxy should write the proxy and ipinfo curl command"
fi
rm -rf "$socks_output_dir"

# Test 40: the standalone patch path supports non-REALITY Xray configs
if command -v jq >/dev/null 2>&1; then
  socks_mode_dir="$(mktemp -d)"
  cat > "$socks_mode_dir/config.json" <<'JSON'
{
  "inbounds": [{"tag": "api", "port": 8080, "protocol": "dokodemo-door"}],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}]
}
JSON
  if (
    xray_config_path="$socks_mode_dir/config.json"
    addsocks_mode=1
    add_limiter_mode=0
    change_sni_mode=0
    patch_jq_source=""
    patch_cleanup=""
    patch_tmp_out=""
    port=""
    socks_port=""
    is_tcp_port_unused() { return 0; }
    restart_xray_service() { :; }
    initialize_ip_from_netstack() { ip="198.51.100.80"; }
    output_socks_proxy() { :; }
    patch_existing_xray_config >/dev/null
    [[ "$(jq -r '.inbounds[0].tag' "$xray_config_path")" == "api" ]]
    [[ "$(jq -r '.inbounds[1].protocol' "$xray_config_path")" == "socks" ]]
  ); then
    pass "standalone --addsocks supports generic Xray config"
  else
    fail "standalone --addsocks should not require a REALITY inbound"
  fi
  rm -rf "$socks_mode_dir"
else
  pass "standalone SOCKS patch test skipped (jq unavailable)"
fi

# Test 41: a fresh Xray config includes the generated SOCKS inbound
if command -v jq >/dev/null 2>&1; then
  socks_build_dir="$(mktemp -d)"
  if (
    xray_config_path="$socks_build_dir/config.json"
    port=443
    domain="example.com"
    reality_dest_port=443
    uuid="test-uuid"
    private_key="test-private-key"
    shortid="abcd1234"
    mldsa_enabled=0
    mldsa65Seed=""
    socks_port=""
    is_tcp_port_unused() { return 0; }
    prepare_socks_inbound
    build_xray_config >/dev/null
    jq -e '.inbounds | length == 2' "$xray_config_path" >/dev/null
    [[ "$(jq -r '.inbounds[0].protocol' "$xray_config_path")" == "vless" ]]
    [[ "$(jq -r '.inbounds[0].streamSettings.realitySettings.minClientVer' "$xray_config_path")" == "0.0.0" ]]
    [[ "$(jq -r '.inbounds[1].protocol' "$xray_config_path")" == "socks" ]]
  ); then
    pass "fresh Xray config includes SOCKS inbound"
  else
    fail "build_xray_config should emit valid JSON with VLESS and SOCKS inbounds"
  fi
  rm -rf "$socks_build_dir"
else
  pass "fresh SOCKS config test skipped (jq unavailable)"
fi

# Test 42: --singbox and --singbox-only select distinct installation modes
if (
  arg_count=0
  sing_box_mode=0
  sing_box_only=0
  parse_args --singbox
  [[ "$sing_box_mode" -eq 1 && "$sing_box_only" -eq 0 ]]
); then
  pass "--singbox selects combined mode"
else
  fail "--singbox should install Sing-box alongside Xray"
fi

if (
  arg_count=0
  sing_box_mode=0
  sing_box_only=0
  parse_args --singbox-only
  [[ "$sing_box_mode" -eq 1 && "$sing_box_only" -eq 1 ]]
); then
  pass "--singbox-only selects standalone mode"
else
  fail "--singbox-only should skip Xray"
fi

# Test 43: dry-run reports both services for --singbox, but not for --singbox-only
if (
  ID="alpine"
  ID_LIKE=""
  realm_mode=0
  realm_only=0
  sing_box_mode=1
  sing_box_only=0
  preview="$(dry_run_preview 2>&1)"
  [[ "$preview" == *"=== Sing-box"* ]]
  [[ "$preview" == *"=== Xray"* ]]
); then
  pass "--singbox dry-run includes Xray and Sing-box"
else
  fail "--singbox dry-run should include both services"
fi

if (
  ID="alpine"
  ID_LIKE=""
  realm_mode=0
  realm_only=0
  sing_box_mode=1
  sing_box_only=1
  preview="$(dry_run_preview 2>&1)"
  [[ "$preview" == *"=== Sing-box"* ]]
  [[ "$preview" != *"=== Xray"* ]]
); then
  pass "--singbox-only dry-run excludes Xray"
else
  fail "--singbox-only dry-run should exclude Xray"
fi

echo "All tests passed."
