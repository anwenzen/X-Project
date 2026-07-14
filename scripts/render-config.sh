#!/bin/sh
# ============================================================================
#  render-config.sh —— 一次性渲染 Xray 与 Hysteria2 配置
#    读取环境变量，替换模板占位符，输出到共享卷；完成后退出
#    在工具齐全的 alpine 容器中运行，不依赖代理镜像内的 shell 工具
# ============================================================================
set -e

echo "[render] 开始渲染配置..."

# ---------- Xray ----------
sed \
  -e "s|\${VLESS_UUID}|${VLESS_UUID}|g" \
  -e "s|\${REALITY_DEST}|${REALITY_DEST}|g" \
  -e "s|\${DOMAIN}|${DOMAIN}|g" \
  -e "s|\${REALITY_PRIVATE_KEY}|${REALITY_PRIVATE_KEY}|g" \
  -e "s|\${REALITY_SHORT_ID}|${REALITY_SHORT_ID}|g" \
  /tpl/xray.json > /out/xray/config.json
echo "[render] 已生成 /out/xray/config.json"

# ---------- Hysteria2 ----------
sed \
  -e "s|\${DOMAIN}|${DOMAIN}|g" \
  -e "s|\${HYSTERIA_PASSWORD}|${HYSTERIA_PASSWORD}|g" \
  -e "s|\${HYSTERIA_OBFS_PASSWORD}|${HYSTERIA_OBFS_PASSWORD}|g" \
  -e "s|\${HYSTERIA_UP_MBPS}|${HYSTERIA_UP_MBPS}|g" \
  -e "s|\${HYSTERIA_DOWN_MBPS}|${HYSTERIA_DOWN_MBPS}|g" \
  -e "s|\${MASQUERADE_UPSTREAM}|${MASQUERADE_UPSTREAM}|g" \
  /tpl/hysteria.yaml > /out/hysteria/config.yaml

# 若混淆密码为空或仍是占位符，移除 obfs 段（从 "obfs:" 到 "bandwidth:" 之前）
if [ -z "${HYSTERIA_OBFS_PASSWORD}" ] || [ "${HYSTERIA_OBFS_PASSWORD}" = "REPLACE_WITH_OBFS_PASSWORD" ]; then
  echo "[render] 未设置混淆密码，禁用 obfs"
  sed -i '/^obfs:/,/^bandwidth:/{/^bandwidth:/!d}' /out/hysteria/config.yaml
fi
echo "[render] 已生成 /out/hysteria/config.yaml"

# ---------- Caddy (layer4 SNI 分流 + trojan + 网站 + 证书) ----------
sed \
  -e "s|\${DOMAIN}|${DOMAIN}|g" \
  -e "s|\${SITE_DOMAIN}|${SITE_DOMAIN}|g" \
  -e "s|\${TROJAN_PASSWORD}|${TROJAN_PASSWORD}|g" \
  -e "s|\${ACME_EMAIL}|${ACME_EMAIL}|g" \
  /tpl/caddy.json > /out/caddy/caddy.json
echo "[render] 已生成 /out/caddy/caddy.json"

echo "[render] 渲染完成。"
