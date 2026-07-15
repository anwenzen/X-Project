#!/usr/bin/env bash
# ============================================================================
#  gen.sh —— 一键生成所需密钥/UUID/密码并写入 .env
#
#  生成内容：
#    - VLESS UUID
#    - REALITY 密钥对（私钥/公钥）
#    - REALITY shortId
#    - Trojan 密码
#    - Hysteria2 认证密码 & 混淆密码
#
#  依赖：docker（用一次性容器调用 sing-box 生成密钥，无需本机安装 sing-box）
#  用法：
#    ./gen.sh            # 首次：从 .env.example 生成 .env 并填入随机密钥
#    ./gen.sh --force    # 覆盖已有 .env 中的密钥字段
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=".env"
EXAMPLE_FILE=".env.example"
SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:v1.13.14"

# ----- 准备 .env -----
if [ ! -f "$ENV_FILE" ]; then
  cp "$EXAMPLE_FILE" "$ENV_FILE"
  echo "[gen] 已从 $EXAMPLE_FILE 创建 $ENV_FILE"
fi

# ----- 生成 UUID -----
echo "[gen] 生成 VLESS UUID..."
VLESS_UUID=$(docker run --rm "$SINGBOX_IMAGE" generate uuid)

# ----- 生成 REALITY 密钥对 -----
echo "[gen] 生成 REALITY 密钥对..."
REALITY_OUT=$(docker run --rm "$SINGBOX_IMAGE" generate reality-keypair)
# 兼容不同版本输出格式（PrivateKey: / Private key: 等）
REALITY_PRIVATE_KEY=$(echo "$REALITY_OUT" | grep -iE "private" | awk -F: '{print $2}' | tr -d ' ')
REALITY_PUBLIC_KEY=$(echo "$REALITY_OUT"  | grep -iE "public"  | awk -F: '{print $2}' | tr -d ' ')

# ----- 生成 shortId（8 字节 = 16 位十六进制）-----
REALITY_SHORT_ID=$(openssl rand -hex 8)

# ----- 生成 Hysteria2 密码 -----
HYSTERIA_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
HYSTERIA_OBFS_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)

# ----- 生成 Trojan 密码 -----
TROJAN_PASSWORD=$(openssl rand -hex 16)

# ----- 写回 .env（就地替换对应行）-----
set_kv() {
  key="$1"; val="$2"
  # 转义 val 中的 & 和 | 以适配 sed
  esc=$(printf '%s' "$val" | sed -e 's/[&|]/\\&/g')
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i.bak -E "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

set_kv "VLESS_UUID"             "$VLESS_UUID"
set_kv "REALITY_PRIVATE_KEY"    "$REALITY_PRIVATE_KEY"
set_kv "REALITY_PUBLIC_KEY"     "$REALITY_PUBLIC_KEY"
set_kv "REALITY_SHORT_ID"       "$REALITY_SHORT_ID"
set_kv "TROJAN_PASSWORD"        "$TROJAN_PASSWORD"
set_kv "HYSTERIA_PASSWORD"      "$HYSTERIA_PASSWORD"
set_kv "HYSTERIA_OBFS_PASSWORD" "$HYSTERIA_OBFS_PASSWORD"

rm -f "${ENV_FILE}.bak"

echo ""
echo "==================== 生成结果 ===================="
echo "VLESS UUID          : $VLESS_UUID"
echo "REALITY 私钥(服务端) : $REALITY_PRIVATE_KEY"
echo "REALITY 公钥(客户端) : $REALITY_PUBLIC_KEY"
echo "REALITY shortId      : $REALITY_SHORT_ID"
echo "Trojan 密码          : $TROJAN_PASSWORD"
echo "Hysteria2 密码       : $HYSTERIA_PASSWORD"
echo "Hysteria2 混淆密码    : $HYSTERIA_OBFS_PASSWORD"
echo "=================================================="
echo ""
echo "[gen] 已写入 $ENV_FILE"
echo "[gen] 请务必手动修改 .env 中的 DOMAIN / SITE_DOMAIN / ACME_EMAIL，然后执行： docker compose up -d"
