#!/bin/bash
# shellcheck disable=SC2034,SC2154
set -euo pipefail

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


. /etc/os-release
manager=""
install_dependencies jq

# 生成 X25519 密钥对
if command -v wg >/dev/null 2>&1; then
  PRIV_KEY=$(wg genkey)
  PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)
elif command -v openssl >/dev/null 2>&1; then
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  openssl genpkey -algorithm X25519 -out "$TMP_DIR/priv.der" -outform DER 2>/dev/null
  PRIV_KEY=$(tail -c 32 "$TMP_DIR/priv.der" | base64 | tr -d '\n')

  openssl pkey -inform DER -in "$TMP_DIR/priv.der" -pubout -outform DER -out "$TMP_DIR/pub.der" 2>/dev/null
  PUB_KEY=$(tail -c 32 "$TMP_DIR/pub.der" | base64 | tr -d '\n')
else
  echo "错误: 系统中必须安装 'wg' 或 'openssl' 用于生成密钥对。" >&2
  exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 构造 Cloudflare WARP 注册请求体
PAYLOAD=$(cat <<EOF
{
  "key": "${PUB_KEY}",
  "install_id": "",
  "fcm_token": "",
  "tos": "${NOW}",
  "model": "PC",
  "type": "Android",
  "locale": "en_US"
}
EOF
)

# 调用 Cloudflare 官方客户端注册 API
RESP=$(curl -sS -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
  -H "Content-Type: application/json" \
  -H "User-Agent: okhttp/3.12.1" \
  -d "$PAYLOAD")

# 校验 API 响应：只要包含 id 和 config 即代表成功
CHECK_ID=$(echo "$RESP" | jq -r '.id // empty' 2>/dev/null)
if [ -z "$CHECK_ID" ]; then
  echo "注册失败，Cloudflare 返回信息：" >&2
  echo "$RESP" >&2
  exit 1
fi

# 提取字段（兼容顶层或 result 嵌套结构）
ADDR_V4=$(echo "$RESP" | jq -r '.config.interface.addresses.v4 // .result.config.interface.addresses.v4')
PEER_PUB=$(echo "$RESP" | jq -r '.config.peers[0].public_key // .result.config.peers[0].public_key')
PEER_EP=$(echo "$RESP" | jq -r '.config.peers[0].endpoint.host // .result.config.peers[0].endpoint.host')
CLIENT_ID=$(echo "$RESP" | jq -r '.config.client_id // .result.config.client_id // empty')

# 解析 reserved 字节 (3 字节)
RESERVED_JSON="null"
if [ -n "$CLIENT_ID" ]; then
  # 将 base64 client_id 解码为 3 个十进制整数
  HEX=$(echo "$CLIENT_ID" | base64 -d 2>/dev/null | od -An -tuC || true)
  if [ -n "$HEX" ]; then
    RESERVED_JSON=$(echo "$HEX" | awk '{print "["$1","$2","$3"]"}')
  fi
fi

# Endpoint 处理：默认使用官方优选 Anycast IP 保证连通性
if [ -z "$PEER_EP" ] || [ "$PEER_EP" = "null" ]; then
  PEER_EP="162.159.192.1:2408"
elif [[ "$PEER_EP" != *":"* ]]; then
  PEER_EP="${PEER_EP}:2408"
fi

if [[ -f "/usr/local/etc/nokey/nokey.json" ]]; then
  XRAY_CONFIG="/usr/local/etc/nokey/nokey.json"
elif [[ -f "/usr/local/etc/xray/config.json" ]]; then
  XRAY_CONFIG="/usr/local/etc/xray/config.json"
else
  XRAY_CONFIG="/usr/local/etc/nokey/nokey.json"
fi

# 构造标准 Xray-core outbound JSON（WARP WireGuard 出口）
WARP_OUT_JSON=$(jq -n \
  --arg priv "$PRIV_KEY" \
  --arg v4 "${ADDR_V4}/32" \
  --arg peer_pub "$PEER_PUB" \
  --arg peer_ep "$PEER_EP" \
  --argjson reserved "$RESERVED_JSON" \
  '{
    tag: "warp-out",
    protocol: "wireguard",
    settings: ({
      secretKey: $priv,
      address: [$v4],
      peers: [
        {
          publicKey: $peer_pub,
          endpoint: $peer_ep,
          keepAlive: 25
        }
      ],
      mtu: 1280
    } + (if $reserved != null then {reserved: $reserved} else {} end))
  }')

echo "$WARP_OUT_JSON"

# 检查 Xray 配置文件是否存在
if [ ! -f "$XRAY_CONFIG" ]; then
  echo "错误: 找不到 Xray 配置文件 $XRAY_CONFIG，无法写入。" >&2
  echo "提示: 请先通过 nokey 安装/生成配置后再运行本脚本。" >&2
  exit 1
fi

if ! jq empty "$XRAY_CONFIG" >/dev/null 2>&1; then
  echo "错误: Xray 配置文件 $XRAY_CONFIG 不是有效的 JSON。" >&2
  exit 1
fi

# 构造要注入的 inbound（WARP SOCKS 入口）和两条 WARP 路由规则
WARP_INBOUND_JSON=$(jq -n '{
  tag: "warp-in-socks",
  listen: "127.0.0.1",
  port: 40000,
  protocol: "socks",
  settings: { auth: "noauth", udp: true }
}')

WARP_RULE_INBOUND_JSON=$(jq -n '{
  type: "field",
  inboundTag: ["warp-in-socks"],
  outboundTag: "warp-out"
}')

WARP_RULE_DOMAIN_JSON=$(jq -n '{
  type: "field",
  domain: ["geosite:google", "geosite:youtube", "geosite:category-forums"],
  outboundTag: "warp-out"
}')

# 将 warp-out / warp-in-socks 合并进配置（幂等：更新或创建 outbound/inbound）。
# 路由规则仅在对应配置缺失时才追加，绝不覆盖/删除/并存用户已自定义的路由：
#   1) 已有 inboundTag 含 warp-in-socks 的规则 → 不再追加默认入口规则
#   2) 已有 domain 规则走向 warp-out → 不再追加默认域名规则
PATCHED_JSON=$(jq \
  --argjson outbound "$WARP_OUT_JSON" \
  --argjson inbound "$WARP_INBOUND_JSON" \
  --argjson rule_inbound "$WARP_RULE_INBOUND_JSON" \
  --argjson rule_domain "$WARP_RULE_DOMAIN_JSON" \
  '
    .outbounds = ((.outbounds // []) | map(select(.tag != "warp-out")) | . + [$outbound])
    | .inbounds = ((.inbounds // []) | map(select(.tag != "warp-in-socks")) | . + [$inbound])
    | .routing.rules = ((.routing.rules // []) + (
        (if any(.routing.rules[]?; (.inboundTag? // []) | index("warp-in-socks")) then [] else [$rule_inbound] end) +
        (if any(.routing.rules[]?; (.domain? != null) and (.outboundTag? == "warp-out")) then [] else [$rule_domain] end)
      ))
  ' "$XRAY_CONFIG")

# 校验合并结果仍为合法 JSON
if ! jq empty >/dev/null 2>&1 <<<"$PATCHED_JSON"; then
  echo "错误: 合并后的配置不是有效的 JSON，已中止，未修改原文件。" >&2
  exit 1
fi

# 原子写入（临时文件 + mv），保留原权限
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT
printf '%s\n' "$PATCHED_JSON" > "$TMP_FILE"
chmod 644 "$TMP_FILE"
mv "$TMP_FILE" "$XRAY_CONFIG"

echo "已更新 $XRAY_CONFIG (warp-out / warp-in-socks / 路由规则)。" >&2

# 重启 Xray 服务以应用新配置（区分 systemd / OpenRC-Alpine）
ID=""
ID_LIKE=""
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
fi
if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
  echo "正在重启 nokey (OpenRC) ..." >&2
  if ! rc-service nokey restart >/dev/null 2>&1 && ! rc-service xray restart >/dev/null 2>&1; then
    echo "错误: 重启 nokey 服务失败。" >&2
    exit 1
  fi
else
  echo "正在重启 nokey (systemd) ..." >&2
  if ! systemctl restart nokey.service >/dev/null 2>&1 && ! systemctl restart xray.service >/dev/null 2>&1; then
    echo "错误: 重启 nokey 服务失败。" >&2
    exit 1
  fi
fi
echo "nokey 服务已重启。" >&2
