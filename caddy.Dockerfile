# ============================================================================
#  caddy-l4-trojan  —  定制 Caddy 镜像
#  在官方 Caddy 基础上编译进两个插件：
#    - caddy-l4     ：layer4(四层) 能力，实现 TCP 443 的 SNI 分流
#    - caddy-trojan ：Trojan 协议支持（listener_wrapper + http handler），
#                      与 file_server 组合实现「密码验证失败即回落到伪装网站」
#
#  构建： docker build -t caddy-l4-trojan:latest -f caddy.Dockerfile .
# ============================================================================
FROM caddy:2.11.4-builder AS builder
RUN xcaddy build \
    --with github.com/mholt/caddy-l4 \
    --with github.com/imgk/caddy-trojan

FROM caddy:2.11.4-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
