#!/bin/sh
# ============================================================================
#  cert-sync：把 Caddy 申请到的真实证书导出到固定路径供 Hysteria2 复用
#
#  Caddy 证书存储结构（v2）：
#    /caddy-data/caddy/certificates/<acme-ca>/<domain>/<domain>.crt
#    /caddy-data/caddy/certificates/<acme-ca>/<domain>/<domain>.key
#  这里递归查找匹配 ${DOMAIN} 的证书，复制为固定文件名 fullchain.pem / privkey.pem
#  每 6 小时同步一次（证书续期后自动跟进）
# ============================================================================

CERT_SRC_ROOT="/caddy-data/caddy/certificates"
DEST="/certs"
INTERVAL=21600   # 6 小时

echo "[cert-sync] 启动，目标域名：${DOMAIN}"

sync_once() {
  # 查找证书文件（.crt = 完整证书链）
  crt=$(find "$CERT_SRC_ROOT" -type f -name "${DOMAIN}.crt" 2>/dev/null | head -n1)
  key=$(find "$CERT_SRC_ROOT" -type f -name "${DOMAIN}.key" 2>/dev/null | head -n1)

  if [ -n "$crt" ] && [ -n "$key" ] && [ -s "$crt" ] && [ -s "$key" ]; then
    # 仅当内容变化时才更新，避免无谓写入
    if ! cmp -s "$crt" "$DEST/fullchain.pem" 2>/dev/null; then
      cp "$crt" "$DEST/fullchain.pem"
      cp "$key" "$DEST/privkey.pem"
      chmod 644 "$DEST/fullchain.pem"
      chmod 600 "$DEST/privkey.pem"
      echo "[cert-sync] $(date '+%F %T') 证书已更新 -> $DEST"
    fi
    return 0
  fi
  return 1
}

# 首次等待 Caddy 申请到证书
echo "[cert-sync] 等待 Caddy 申请证书..."
until sync_once; do
  echo "[cert-sync] 证书尚未就绪，5s 后重试（首次申请可能需要 10~60s）..."
  sleep 5
done

echo "[cert-sync] 首次同步完成，进入周期性检查（每 6 小时）"
while true; do
  sleep "$INTERVAL"
  sync_once
done
