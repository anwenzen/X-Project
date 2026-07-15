# ============================================================================
#  caddy-l4  —  定制 Caddy 镜像
#  在官方 Caddy 基础上编译进 layer4 插件：
#    - caddy-l4    ：layer4(四层) 能力，实现 TCP 443 的 SNI 分流
#
#  （Trojan 已改由 sing-box 承载，故不再需要 caddy-trojan 插件）
#
#  构建： docker build -t caddy-l4:latest -f caddy.Dockerfile .
# ============================================================================
FROM caddy:2.11.4-builder AS builder
RUN xcaddy build \
    --with github.com/mholt/caddy-l4

FROM caddy:2.11.4-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
