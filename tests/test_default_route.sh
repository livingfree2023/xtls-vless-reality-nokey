#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
cd "$fixture_dir"
# shellcheck source=/dev/null
source "$REPO_ROOT/nokey.sh"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

for family in 4 6; do
  default_route_choice="$family"
  egress_ipv4_available=1
  egress_ipv6_available=1
  build_default_route_settings
  [[ "$dns_query_strategy" == UseIP ]] || fail "dual-stack DNS must retain A and AAAA"
  jq -e --argjson ipv6 "$([[ "$family" == 6 ]] && echo true || echo false)" '
    .protocol == "freedom" and .tag == "direct" and
    .streamSettings.sockopt.domainStrategy == "UseIP" and
    .streamSettings.sockopt.happyEyeballs.prioritizeIPv6 == $ipv6 and
    .streamSettings.sockopt.happyEyeballs.tryDelayMs == 250 and
    .streamSettings.sockopt.happyEyeballs.interleave == 1
  ' <<< "$default_outbound_json" >/dev/null || fail "preference should configure Happy Eyeballs"
  if [[ "$family" == 4 ]]; then
    jq -e '.[0] | contains(":") | not' <<< "$dns_servers_json" >/dev/null || fail "IPv4 preference resolver ordering"
  else
    jq -e '.[0] | contains(":")' <<< "$dns_servers_json" >/dev/null || fail "IPv6 preference resolver ordering"
  fi
done
pass "dual-stack preference and DNS ordering"

for family in 4 6; do
  default_route_choice="$family"
  egress_ipv4_available=0
  egress_ipv6_available=0
  if [[ "$family" == 4 ]]; then egress_ipv4_available=1; else egress_ipv6_available=1; fi
  build_default_route_settings
  [[ "$dns_query_strategy" == "UseIPv$family" ]] || fail "single-stack query strategy"
  if [[ "$family" == 4 ]]; then
    jq -e 'all(.[]; . == "localhost" or (contains(":") | not))' <<< "$dns_servers_json" >/dev/null || fail "single-stack must use reachable resolver family"
  else
    jq -e 'all(.[]; . == "localhost" or contains(":"))' <<< "$dns_servers_json" >/dev/null || fail "single-stack must use reachable resolver family"
  fi
done
pass "single-stack DNS configuration"

cat > existing.json <<'JSON'
{
  "log": {"loglevel":"warning"},
  "inbounds": [{"tag":"existing","protocol":"vless","settings":{"clients":[{"id":"SENTINEL-UUID"}]} }],
  "outbounds": [
    {"tag":"force_ipv4","protocol":"freedom","streamSettings":{"sockopt":{"domainStrategy":"ForceIPv4"}}},
    {"tag":"force_ipv6","protocol":"freedom","streamSettings":{"sockopt":{"domainStrategy":"ForceIPv6"}}},
    {"tag":"warp_out","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":40000}]}},
    {"tag":"block","protocol":"blackhole"}
  ],
  "dns":{"hosts":{"private.example":"127.0.0.1"},"disableCache":true,"queryStrategy":"UseIPv4","servers":[{"address":"9.9.9.9","domains":["domain:example.org"],"skipFallback":true}]},
  "routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","domain":["example.org"],"outboundTag":"force_ipv6"}]}
}
JSON
patch_jq_source="$fixture_dir/existing.json"
patch_tmp_out="$fixture_dir/patched.json"
default_route_choice=6
egress_ipv4_available=1
egress_ipv6_available=1
build_default_route_settings
apply_default_route_patch
jq -e '.outbounds[0].tag == "direct" and .dns.queryStrategy == "UseIP" and (.outbounds | length == 5)' "$patch_tmp_out" >/dev/null || fail "new default must be first"
[[ "$(jq -c '.inbounds,.routing,.dns.hosts,.dns.disableCache' existing.json)" == "$(jq -c '.inbounds,.routing,.dns.hosts,.dns.disableCache' patched.json)" ]] || fail "credentials and custom policy must survive"
[[ "$(jq -c '.outbounds' existing.json)" == "$(jq -c '.outbounds[1:]' patched.json)" ]] || fail "explicit force/WARP/block outbounds must survive"
jq -e 'any(.dns.servers[]; type == "object" and .address == "9.9.9.9" and .domains == ["domain:example.org"] and .skipFallback)' patched.json >/dev/null || fail "split DNS rules must survive"
pass "default route patch preserves credentials and explicit routing"

# Applying preference twice must not duplicate managed outbounds or resolvers.
cp patched.json twice-source.json
patch_jq_source="$fixture_dir/twice-source.json"
patch_tmp_out="$fixture_dir/twice.json"
apply_default_route_patch
[[ "$(jq '.outbounds | length' twice.json)" -eq 5 ]] || fail "default route must be idempotent"
jq -e '[.outbounds[].tag] | length == (unique | length)' twice.json >/dev/null || fail "outbound tags must stay unique"
pass "repeated preference patch is idempotent"

# Legacy Freedom resolution must not preempt the new socket preference.
printf '%s\n' '{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"ForceIPv4","userLevel":2}}]}' > legacy-direct.json
patch_jq_source="$fixture_dir/legacy-direct.json"
patch_tmp_out="$fixture_dir/legacy-updated.json"
apply_default_route_patch
jq -e '.outbounds[0].settings.domainStrategy == "AsIs" and .outbounds[0].settings.userLevel == 2 and .outbounds[0].streamSettings.sockopt.happyEyeballs.prioritizeIPv6' "$patch_tmp_out" >/dev/null || fail "legacy Freedom resolution overrides socket preference"
pass "legacy Freedom resolution normalized without losing settings"

# A custom upstream proxy cannot be silently bypassed by setting a direct default.
printf '%s\n' '{"outbounds":[{"tag":"custom-proxy","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":1234}]}}]}' > custom.json
patch_jq_source="$fixture_dir/custom.json"
patch_tmp_out="$fixture_dir/refused.json"
if apply_default_route_patch >/dev/null 2>&1; then fail "custom default proxy must require explicit configuration"; fi
pass "custom proxy default is protected"

for bad in --default-route=9 --default-route= --default-route=ipv6; do
  if (arg_count=0; parse_args "$bad") >/dev/null 2>&1; then fail "invalid default route value accepted"; fi
done
(arg_count=0; parse_args --default-route=6; [[ "$default_route_mode" -eq 1 && "$default_route_choice" == 6 ]]) || fail "unattended preference flag"
pass "default route argument validation"
# Transaction checks use isolated state transitions; external Xray parsing is
# verified by the opt-in integration script against the actual runtime.
(
  xray_config_path="$fixture_dir/transaction.json"
  printf '%s\n' '{"original":true}' > "$xray_config_path"
  printf '%s\n' '{"updated":true}' > "$fixture_dir/staged.json"
  validation_status=23
  xray() { return "$validation_status"; }
  restart_xray_service() { printf 'restart\n' >> "$fixture_dir/restarts"; }
  if commit_xray_config "$fixture_dir/staged.json" >/dev/null; then fail "invalid config accepted"; fi
  [[ "$(cat "$xray_config_path")" == '{"original":true}' ]] || fail "validation failure changed original"
  [[ ! -e "$fixture_dir/restarts" ]] || fail "validation failure restarted service"
  [[ ! -e "$fixture_dir/staged.json" ]] || fail "rejected config stage leaked"
)
pass "validation failure leaves original service and config untouched"

(
  xray_config_path="$fixture_dir/transaction.json"
  printf '%s\n' '{"original":true}' > "$xray_config_path"
  printf '%s\n' '{"updated":true}' > "$fixture_dir/staged.json"
  xray() { return 0; }
  restart_xray_service() { grep -q updated "$xray_config_path"; }
  commit_xray_config "$fixture_dir/staged.json" >/dev/null
  grep -q updated "$xray_config_path" || fail "successful commit did not apply"
  [[ "$(cat "$last_config_backup")" == '{"original":true}' ]] || fail "backup differs from original"
  [[ "$(LC_ALL=C ls -l "$last_config_backup")" == -rw-------* ]] || fail "backup is not private"
)
pass "validated config commit preserves private backup"

for recovery in success failure; do
  (
    xray_config_path="$fixture_dir/transaction.json"
    printf '%s\n' '{"original":true}' > "$xray_config_path"
    printf '%s\n' '{"updated":true}' > "$fixture_dir/staged.json"
    printf '0\n' > "$fixture_dir/restart-count"
    xray() { return 0; }
    restart_xray_service() {
      local calls
      calls="$(cat "$fixture_dir/restart-count")"
      calls=$((calls + 1))
      printf '%s\n' "$calls" > "$fixture_dir/restart-count"
      [[ "$calls" -gt 1 && "$recovery" == success ]] || return 1
      grep -q original "$xray_config_path"
    }
    if commit_xray_config "$fixture_dir/staged.json" >/dev/null; then fail "failed application returned success"; fi
    [[ "$(cat "$xray_config_path")" == '{"original":true}' ]] || fail "failed apply did not restore config"
    [[ "$(cat "$fixture_dir/restart-count")" -eq 2 ]] || fail "recovery was not attempted once"
    [[ -f "$last_config_backup" ]] || fail "recovery lost backup"
    grep -q "config_rollback status=$([[ "$recovery" == success ]] && echo success || echo failed)" "$LOG_FILE" || fail "rollback status missing"
  )
done
pass "restart failures restore original config and report recovery status"
# Real terminal input: cancellation and unavailable choices must not initialize files.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$REPO_ROOT/nokey.sh" "$fixture_dir" <<'PYMENU'
import errno, os, pty, select, sys, time
from pathlib import Path
root, directory = sys.argv[1], Path(sys.argv[2])
wrapper = directory / "menu-wrapper.sh"
wrapper.write_text('''source "$1"
egress_ipv4_available=1
egress_ipv6_available="$3"
xray_config_path="$2/config.json"
main --default-route
printf 'MENU_EXIT=%s\n' "$?"
''')
for ipv6, inputs in (("1", [b"0\n"]), ("0", [b"2\n", b"0\n"])):
    run_dir = directory / ("menu-" + ipv6)
    run_dir.mkdir()
    (run_dir / "nokey.log").write_text("preserve-log\n")
    (run_dir / "nokey.url").write_text("preserve-url\n")
    pid, master = pty.fork()
    if pid == 0:
        os.chdir(run_dir)
        os.execv("/bin/bash", ["bash", str(wrapper), root, str(run_dir), ipv6])
    output = bytearray()
    sent = 0
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            if not select.select([master], [], [], .2)[0]:
                continue
            try:
                chunk = os.read(master, 4096)
            except OSError as exc:
                if exc.errno == errno.EIO: break
                raise
            if not chunk: break
            output.extend(chunk)
            prompts = output.count(b"Select: ")
            if prompts > sent and sent < len(inputs):
                os.write(master, inputs[sent]); sent += 1
        else:
            os.kill(pid, 9)
            raise AssertionError("menu test timed out")
    finally:
        os.close(master)
        _, status = os.waitpid(pid, 0)
    assert status == 0 and b"MENU_EXIT=0" in output, "menu cancellation failed"
    assert (run_dir / "nokey.log").read_text() == "preserve-log\n", "cancel changed log"
    assert (run_dir / "nokey.url").read_text() == "preserve-url\n", "cancel changed URLs"
    if ipv6 == "0":
        assert b"Invalid or unavailable" in output, "unavailable family was accepted"
PYMENU
  pass "real terminal cancellation and unavailable choices preserve files"
fi
printf 'All default route tests passed.\n'  
