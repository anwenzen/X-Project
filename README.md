# X-Project：VLESS-REALITY + Trojan + Hysteria2 · 443 共用一键部署

用 Docker Compose 部署三个代理协议，通过 **Caddy layer4（四层）SNI 分流**，让 **VLESS-REALITY、Trojan、伪装网站共用同一个 TCP 443**，**Hysteria2 独占 UDP 443**。所有协议都跑在标准 443 端口，主动探测时看到的是真实网站与真证书，**隐蔽性强、更抗封锁**。

| 协议 | 内核 | 入口 | 域名(SNI) | 证书 | 适用场景 |
|------|------|------|-----------|------|----------|
| **VLESS + XTLS-Vision + REALITY** | Xray 1.8.24 | **TCP 443**（Caddy 分流） | `DOMAIN` | 借用自有域名真证书伪装 | 日常主力、抗封锁 |
| **Trojan** | Caddy(caddy-trojan) | **TCP 443**（Caddy 分流） | `SITE_DOMAIN` | Caddy 自动申请 | 备用通道 |
| **Hysteria2** | hysteria v2.10.0 | **UDP 443** | `DOMAIN` | 复用 Caddy 证书（热重载） | 晚高峰、弱网、流媒体 |

> TCP 443 与 UDP 443 端口号相同但协议不同，互不冲突。TCP 443 上再由 Caddy 按 SNI 分流给 REALITY / Trojan / 网站。

---

## 目录

- [一、架构原理](#一架构原理)
- [二、目录结构](#二目录结构)
- [三、前置条件](#三前置条件)
- [四、部署步骤](#四部署步骤)
- [五、.env 配置项详解](#五env-配置项详解)
- [六、客户端连接参数](#六客户端连接参数)
- [七、工作原理详解](#七工作原理详解)
- [八、常用运维命令](#八常用运维命令)
- [九、故障排查（踩坑记录）](#九故障排查踩坑记录)
- [十、换机器部署](#十换机器部署)

---

## 一、架构原理

```
                          ┌─────────────────────────────────────────────────┐
   TCP 443 ─────────────► │  x-caddy (layer4 SNI 分流，只读 ClientHello 不解密) │
                          │                                                   │
                          │   SNI = DOMAIN      → x-xray:5443  (VLESS-REALITY) │
                          │   其它 SNI          → 127.0.0.1:4443 (Caddy 本地)   │
                          │        ├─ Host=SITE_DOMAIN → Trojan + 文件站(/srv) │
                          │        └─ Host=DOMAIN      → 文件站(REALITY 回落)  │
                          └───────────────┬─────────────────────────────────┘
                                          │ Caddy 统一 ACME(LE) 申请/续期证书
                                          │ 存于 ./data/caddy/certificates/...
                                          ▼ (只读挂载 /caddy-certs，自动热重载)
   UDP 443 ─────────────► ┌───────────┐
                          │ x-hysteria│  直接读取 Caddy 的 DOMAIN 证书文件
                          │  QUIC     │
                          └───────────┘
   TCP 80  ─────────────► x-caddy (ACME HTTP-01 验证 + HTTP→HTTPS 跳转)
```

四个容器（`docker compose` 管理）：

| 容器 | 镜像 | 监听 | 职责 |
|------|------|------|------|
| `x-config-init` | `alpine:3.20` | — | **一次性**容器：用 `.env` 渲染 xray/hysteria/caddy 三份配置到 `./data`，完成即退出 |
| `x-caddy` | `caddy-l4-trojan:latest`（自建） | 80, 443/tcp（对外）; 4443（内部） | layer4 SNI 分流 + Trojan + 伪装网站 + ACME 证书自动申请续期 |
| `x-xray` | `ghcr.io/xtls/xray-core:1.8.24` | 5443（仅内网） | VLESS + XTLS-Vision + REALITY，由 Caddy 分流转入 |
| `x-hysteria` | `tobyxdd/hysteria:v2.10.0` | 443/udp（对外） | Hysteria2，只读挂载 Caddy 证书目录直接读取 |

**关键设计**：
- **共用 443**：Caddy 的 `layer4` 只读取 TLS ClientHello 里的 SNI（不解密），按域名把整条 TCP 连接**原样转发**给后端，REALITY 的特殊握手仍由 Xray 处理。
- **REALITY 借用自有域名**：`REALITY_DEST` 指向本机 Caddy 网站（`x-caddy:4443`），SNI 即 `DOMAIN`。被主动探测时会看到 Caddy 提供的**真实网站 + 真证书**，比借用第三方站点更隐蔽。
- **证书零中转**：Caddy 申请证书后，Hysteria2 直接只读挂载证书目录读取；续期后 Caddy 原地更新文件，Hysteria2 **自动热重载、无需重启**（不用 cert-sync sidecar）。

---

## 二、目录结构

```
X-Project/
├── docker-compose.yml                # 服务编排（4 个服务，443 共用架构）
├── caddy.Dockerfile                  # 构建 caddy-l4-trojan 定制镜像（caddy 2.11.4 + layer4 + trojan）
├── .env.example                      # 环境变量模板
├── .env                              # 实际环境变量（gen.sh 生成，含密钥，已被 .gitignore 忽略）
├── gen.sh                            # 一键生成 UUID / REALITY 密钥 / Trojan & Hysteria 密码
├── config/
│   ├── caddy/caddy.json.template     # Caddy layer4 分流 + trojan + 网站 + 证书（JSON 模板）
│   ├── site/index.html               # 伪装站首页（DOMAIN / SITE_DOMAIN 被访问时展示）
│   ├── xray/config.json.template     # VLESS-REALITY 模板（内网 5443）
│   └── hysteria/config.yaml.template # Hysteria2 模板（直接读 Caddy 证书）
├── scripts/
│   └── render-config.sh              # 渲染 xray/hysteria/caddy 配置（在 alpine 容器内运行）
└── data/                             # 运行时持久化（证书/渲染配置/日志，容器外，.gitignore）
    ├── caddy/                        #   Caddy 渲染配置 + 证书存储
    ├── xray/                         #   渲染后的 xray 配置 + access/error 日志
    └── hysteria/                     #   渲染后的 hysteria 配置
```

---

## 三、前置条件

1. 一台有公网 IP 的 Linux 服务器，已装 **Docker** 与 **Docker Compose 插件**。
   - 内存建议 ≥ 1G；**编译 Caddy 较吃内存，小内存机器建议先加 2G swap**（见故障排查）。
2. **两个域名**（必须不同），A 记录都解析到服务器公网 IP：

   | 变量 | 用途 | 示例 |
   |------|------|------|
   | `DOMAIN` | REALITY 的 SNI + Hysteria2 证书 | `a.example.com` |
   | `SITE_DOMAIN` | Trojan + 伪装网站 | `b.example.com` |

   > 为什么要两个域名：layer4 靠**不同的 SNI** 来区分「这条连接该给 REALITY 还是给 Trojan/网站」。两个域名指向同一台机器即可。
3. 放行防火墙 / 云安全组端口：**TCP 80、TCP 443、UDP 443**。
   - TCP 80：ACME 证书验证（HTTP-01）+ HTTP 跳 HTTPS
   - TCP 443：VLESS-REALITY / Trojan / 网站（Caddy 分流）
   - UDP 443：Hysteria2（**云安全组常默认不放行 UDP，务必检查**）

---

## 四、部署步骤

```bash
# 1) 克隆本仓库到服务器后进入目录
git clone git@github.com:anwenzen/X-Project.git
cd X-Project

# 2) 构建定制 Caddy 镜像（含 layer4 + trojan 插件，首次约 2~4 分钟）
docker build -t caddy-l4-trojan:latest -f caddy.Dockerfile .

# 3) 一键生成 UUID / REALITY 密钥 / Trojan 密码 / Hysteria 密码（自动写入 .env）
chmod +x gen.sh scripts/*.sh
./gen.sh

# 4) 编辑 .env，把下面三项改成你自己的（其余已由 gen.sh 填好）：
#      DOMAIN=a.example.com
#      SITE_DOMAIN=b.example.com     # 必须与 DOMAIN 不同
#      ACME_EMAIL=you@example.com
vim .env

# 5) 启动全部服务
docker compose up -d

# 6) 观察证书申请与启动
docker compose logs -f caddy hysteria
```

看到 `caddy` 日志出现证书申请成功、`hysteria` 输出 `server up and running` 即部署成功。

> **首次全新部署**时，Caddy 申请证书需要几十秒；这期间 Hysteria2 可能因读不到证书而重启几轮，待证书就绪后会自动稳定，属正常现象。

验证服务：
```bash
docker compose ps                                   # 四个容器应为 Up（config-init 为 Exited 0，正常）
# REALITY 伪装层：对 443 做 TLS 握手应返回 DOMAIN 的真证书
echo | openssl s_client -connect 127.0.0.1:443 -servername <DOMAIN> 2>/dev/null | openssl x509 -noout -subject
# 网站：应返回 200
curl -sI https://<SITE_DOMAIN> | head -1
```

---

## 五、.env 配置项详解

| 变量 | 说明 | 来源 |
|------|------|------|
| `DOMAIN` | 主域名。REALITY 的 SNI + Hysteria2 的证书域名 | **手动填** |
| `SITE_DOMAIN` | 站点域名。Trojan + 伪装网站（须与 `DOMAIN` 不同） | **手动填** |
| `ACME_EMAIL` | ACME 证书申请邮箱（Let's Encrypt 到期提醒） | **手动填** |
| `VLESS_UUID` | VLESS 客户端 UUID | gen.sh |
| `REALITY_DEST` | REALITY 回落目标，固定 `x-caddy:4443`（本机 Caddy 网站） | 预设 |
| `REALITY_PRIVATE_KEY` | REALITY x25519 私钥（服务端用） | gen.sh |
| `REALITY_PUBLIC_KEY` | REALITY x25519 公钥（**给客户端**） | gen.sh |
| `REALITY_SHORT_ID` | REALITY shortId（16 位十六进制） | gen.sh |
| `TROJAN_PASSWORD` | Trojan 连接密码 | gen.sh |
| `HYSTERIA_PASSWORD` | Hysteria2 认证密码 | gen.sh |
| `HYSTERIA_OBFS_PASSWORD` | Hysteria2 Salamander 混淆密码（留空则禁用混淆） | gen.sh |
| `HYSTERIA_UP_MBPS` / `HYSTERIA_DOWN_MBPS` | 服务端带宽上限（QUIC 拥塞控制参考值） | 预设 1000 |
| `MASQUERADE_UPSTREAM` | Hysteria2 被主动探测时反代的伪装网站 | 预设 |

> REALITY 的 SNI **不再单独配置**，直接复用 `DOMAIN`（渲染时自动写入 xray 配置）。

---

## 六、客户端连接参数

部署后 `cat .env` 获取密钥。下面 `<...>` 用你的实际值替换。

### 1. VLESS-REALITY（TCP 443）

| 项 | 值 |
|----|----|
| 地址 | 服务器 IP 或 `DOMAIN` |
| 端口 | `443` |
| 协议 | VLESS |
| UUID | `<VLESS_UUID>` |
| 流控 flow | `xtls-rprx-vision` |
| 传输 | TCP |
| 安全 | reality |
| SNI / peer | **`<DOMAIN>`** |
| Fingerprint | `chrome` |
| PublicKey (pbk) | `<REALITY_PUBLIC_KEY>` |
| ShortId (sid) | `<REALITY_SHORT_ID>` |

### 2. Trojan（TCP 443）

| 项 | 值 |
|----|----|
| 地址 | **`<SITE_DOMAIN>`**（走 TLS，需用域名） |
| 端口 | `443` |
| 协议 | Trojan |
| 密码 | `<TROJAN_PASSWORD>` |
| SNI | `<SITE_DOMAIN>` |

### 3. Hysteria2（UDP 443）

| 项 | 值 |
|----|----|
| 地址 | **`<DOMAIN>`**（证书校验，须用域名，不能用 IP） |
| 端口 | `443`（UDP） |
| 密码 | `<HYSTERIA_PASSWORD>` |
| 混淆 obfs | `salamander` |
| 混淆密码 | `<HYSTERIA_OBFS_PASSWORD>` |
| SNI | `<DOMAIN>` |
| 上传/下载带宽 | **留空**（走 BBR 自适应，切勿设过大值） |

### Clash Verge Rev 示例

```yaml
proxies:
  - name: "VLESS-REALITY"
    type: vless
    server: a.example.com          # DOMAIN 或服务器 IP
    port: 443
    uuid: <VLESS_UUID>
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: a.example.com      # = DOMAIN
    client-fingerprint: chrome
    reality-opts:
      public-key: <REALITY_PUBLIC_KEY>
      short-id: <REALITY_SHORT_ID>

  - name: "Trojan"
    type: trojan
    server: b.example.com          # = SITE_DOMAIN
    port: 443
    password: <TROJAN_PASSWORD>
    sni: b.example.com
    udp: true

  - name: "Hysteria2"
    type: hysteria2
    server: a.example.com          # = DOMAIN，必须用域名
    port: 443
    password: <HYSTERIA_PASSWORD>
    sni: a.example.com
    obfs: salamander
    obfs-password: <HYSTERIA_OBFS_PASSWORD>
    # up/down 留空走 BBR 自适应；或设小值如 up: "20 Mbps" down: "100 Mbps"
```

---

## 七、工作原理详解

### 7.1 TCP 443 的 SNI 分流

Caddy 用 `caddy-l4` 插件在 443 做四层代理，只读 ClientHello 的 SNI，不解密：

| ClientHello SNI | 转发到 | 后续处理 |
|-----------------|--------|----------|
| `DOMAIN` | `x-xray:5443` | Xray 处理 VLESS-REALITY 握手 |
| 其它（含 `SITE_DOMAIN`） | `127.0.0.1:4443` | Caddy 本地 HTTP 服务（带 trojan wrapper）|

到了本地 4443 后，Caddy 再按 HTTP Host 分：
- `Host = SITE_DOMAIN`：先过 Trojan（`caddy-trojan`，解 Trojan-over-TLS），非 Trojan 流量落到文件站 `/srv`
- `Host = DOMAIN`：文件站 `/srv`（这正是 **REALITY 回落**时探测者看到的真实网站）

### 7.2 REALITY 的「借用」与回落

- REALITY 客户端用正确的 `pbk`/`sid`/UUID 握手 → Xray 认证通过，走代理。
- 未认证的**主动探测**（如浏览器直接访问 `https://DOMAIN`）→ Xray 把连接回落给 `REALITY_DEST=x-caddy:4443`，Caddy 用 `DOMAIN` 的真证书 + 真网站响应。探测者看到的是一个正常运营的网站，无法分辨这是代理入口。

### 7.3 证书生命周期

1. Caddy 通过 ACME（Let's Encrypt）为 `DOMAIN` 和 `SITE_DOMAIN` 申请证书，存 `./data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/<域名>/`。
2. Hysteria2 只读挂载 `./data/caddy` → 容器 `/caddy-certs`，配置直接指向 `DOMAIN` 的 `.crt`/`.key`。
3. Caddy 自动续期 → 原地更新证书文件 → Hysteria2 **自动热重载**，无需人工干预。

> ⚠️ 证书路径写死了 ACME CA 目录名 `acme-v02.api.letsencrypt.org-directory`（Let's Encrypt）。`caddy.json.template` 已锁定只用 LE，路径稳定。若你改用其它 CA，需同步改 `config/hysteria/config.yaml.template` 里的路径。

---

## 八、常用运维命令

```bash
cd X-Project

docker compose ps                       # 服务状态
docker compose logs -f caddy            # Caddy 分流 / 证书日志
docker compose logs -f xray             # Xray 日志（access/error 也在 data/xray/）
docker logs x-hysteria --tail 30        # Hysteria2 日志
docker compose restart hysteria         # 重启单个服务
docker compose down                     # 停止（证书/配置保留在 ./data）
docker compose up -d                    # 启动

# 改了 .env 后：config-init 用 env_file，必须重建才会重新渲染/注入（restart 无效）
docker compose up -d --force-recreate --no-deps config-init
docker compose up -d --force-recreate --no-deps xray hysteria caddy

# 开 Xray debug 抓连接（排障后记得改回 warning 并重启 x-xray）
sed -i 's/"loglevel": "warning"/"loglevel": "debug"/' data/xray/config.json && docker restart x-xray
```

---

## 九、故障排查（踩坑记录）

按项目实际踩过的坑整理，遇到问题先看这里：

1. **Xray 版本固定 `1.8.24`**：26.x 等过新版本与部分客户端（如 Shadowrocket）内置的 REALITY 实现握手不稳。**不要随意升级或换 `latest`**。
2. **REALITY 的 dest 不要用 Akamai CDN 站点**（如 `www.microsoft.com`）：会导致服务端把所有客户端判为 `invalid connection`。本项目用自有域名回落，已规避。
3. **Hysteria2 客户端带宽必须留空 / 设小值**：设过大会触发 Brutal 拥塞控制「硬发」，在移动网络上瞬间打爆链路造成大量丢包，表现为「**连得上、传不动**」（日志 `accepting stream failed: timeout`）。留空走 BBR 最稳。
4. **VLESS 连不上、服务端日志 `server name mismatch`**：客户端 SNI 填错（不是 `DOMAIN`），或手机上残留旧节点。确认客户端 SNI/peer = `DOMAIN`，并删掉旧节点。
5. **VLESS 连不上、服务端日志 `authentication failed`**：`pbk`/`sid` 与服务端不匹配，或客户端与服务端时间偏差过大（REALITY 有时间戳校验）。核对密钥、开启手机「自动设置时间」。
6. **改了 `.env` 不生效**：`config-init` 用 `env_file`，`docker restart` 不会重新注入/渲染，必须 `docker compose up -d --force-recreate` 重建相关容器。
7. **UDP 443 手机连不上**：优先检查**云安全组**是否放行了 UDP 443（本地 `ufw`/`iptables` 放行不代表云控制台放行）。
8. **编译 Caddy 时其它容器被 OOM Kill**（小内存机器）：加 swap：
   ```bash
   fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
   echo '/swapfile none swap sw 0 0' >> /etc/fstab
   ```
9. **首次部署 Hysteria2 反复重启**：证书还没申请好，属正常，等 Caddy 拿到证书后自动稳定。

---

## 十、换机器部署

1. 新机器 `git clone git@github.com:anwenzen/X-Project.git`（仓库不含 `.env`）。
2. 按「[四、部署步骤](#四部署步骤)」构建镜像、`./gen.sh`、填 `.env`（或从旧机器拷贝 `.env` 以保持 UUID/密钥不变）。
3. 把 `DOMAIN` 和 `SITE_DOMAIN` 的 DNS 解析改到新机器 IP。
4. `docker compose up -d`，Caddy 会自动申请证书。

> 想连证书一起迁移（免重新申请）：把旧机器的 `./data/caddy` 一并复制过去即可。

---

## 附：镜像版本

| 组件 | 镜像 | 版本 |
|------|------|------|
| Caddy（自建） | `caddy-l4-trojan:latest` | 基于 `caddy:2.11.4` + `caddy-l4` + `caddy-trojan` |
| Xray | `ghcr.io/xtls/xray-core` | `1.8.24` |
| Hysteria2 | `tobyxdd/hysteria` | `v2.10.0` |
| 渲染/工具 | `alpine` | `3.20` |

> 版本均已锁定，确保可稳定复现（历史上 Xray 版本漂移导致过握手不兼容）。
