#!/bin/sh
# ============================================================================
#  render-config.sh —— 一次性渲染 sing-box 与 Caddy 配置
#    读取环境变量，替换模板占位符，输出到共享卷；完成后退出
#    在工具齐全的 alpine 容器中运行，不依赖代理镜像内的 shell 工具
# ============================================================================
set -e

echo "[render] 开始渲染配置..."

# jq 用于按需删除 sing-box 的 obfs 段（JSON 结构删除比 sed 可靠）
echo "[render] 安装 jq ..."
apk add --no-cache jq >/dev/null 2>&1 || true

# ---------- sing-box (VLESS-REALITY + Hysteria2) ----------
sed \
  -e "s|\${VLESS_UUID}|${VLESS_UUID}|g" \
  -e "s|\${DOMAIN}|${DOMAIN}|g" \
  -e "s|\${REALITY_PRIVATE_KEY}|${REALITY_PRIVATE_KEY}|g" \
  -e "s|\${REALITY_SHORT_ID}|${REALITY_SHORT_ID}|g" \
  -e "s|\${HYSTERIA_PASSWORD}|${HYSTERIA_PASSWORD}|g" \
  -e "s|\${HYSTERIA_OBFS_PASSWORD}|${HYSTERIA_OBFS_PASSWORD}|g" \
  -e "s|\${HYSTERIA_UP_MBPS}|${HYSTERIA_UP_MBPS}|g" \
  -e "s|\${HYSTERIA_DOWN_MBPS}|${HYSTERIA_DOWN_MBPS}|g" \
  -e "s|\${MASQUERADE_UPSTREAM}|${MASQUERADE_UPSTREAM}|g" \
  /tpl/singbox.json > /out/singbox/config.json.tmp

# 若混淆密码为空或仍是占位符，删除 hysteria2 的 obfs 段（否则 sing-box 会因空密码报错）
if [ -z "${HYSTERIA_OBFS_PASSWORD}" ] || [ "${HYSTERIA_OBFS_PASSWORD}" = "REPLACE_WITH_OBFS_PASSWORD" ]; then
  echo "[render] 未设置混淆密码，禁用 hysteria2 obfs"
  jq '(.inbounds |= map(if .type == "hysteria2" then del(.obfs) else . end))' \
     /out/singbox/config.json.tmp > /out/singbox/config.json
else
  jq . /out/singbox/config.json.tmp > /out/singbox/config.json
fi
rm -f /out/singbox/config.json.tmp
echo "[render] 已生成 /out/singbox/config.json"

# ---------- Caddy (layer4 SNI 分流 + Trojan + 伪装站 + 证书) ----------
sed \
  -e "s|\${DOMAIN}|${DOMAIN}|g" \
  -e "s|\${SITE_DOMAIN}|${SITE_DOMAIN}|g" \
  -e "s|\${ACME_EMAIL}|${ACME_EMAIL}|g" \
  -e "s|\${TROJAN_PASSWORD}|${TROJAN_PASSWORD}|g" \
  /tpl/caddy.json > /out/caddy/caddy.json
echo "[render] 已生成 /out/caddy/caddy.json"

echo "[render] 渲染完成。"
