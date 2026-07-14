# X-Project：VLESS-REALITY + Trojan + Hysteria2 · 443 共用一键部署

用 Docker Compose 部署三个代理协议，通过 **Caddy layer4（四层）SNI 分流**让 **VLESS-REALITY、Trojan、伪装网站共用同一个 TCP 443**，Hysteria2 独占 UDP 443。所有协议都跑在标准 443 端口，隐蔽性强、更抗封锁。

| 协议 | 内核 | 入口 | SNI / 域名 | 证书 |
|------|------|------|-----------|------|
| **VLESS + XTLS-Vision + REALITY** | Xray | **TCP 443**（经 Caddy 分流） | `DOMAIN` | 借用自有域名真实证书伪装 |
| **Trojan** | Caddy(caddy-trojan) | **TCP 443**（经 Caddy 分流） | `SITE_DOMAIN` | Caddy 自动申请 |
| **Hysteria2** | 官方 hysteria | **UDP 443** | `DOMAIN` | 复用 Caddy 证书 |

> TCP 443 与 UDP 443 端口号相同但协议不同，互不冲突。TCP 443 上再由 Caddy 按 SNI 分流给 REALITY / Trojan / 网站。

---

## 一、架构说明

```
                         ┌──────────────────────────────────────────────┐
   TCP 443 ────────────► │  Caddy (layer4 SNI 分流，只读 SNI 不解密)      │
                         │    SNI = DOMAIN       → x-xray:5443  (REALITY) │
                         │    其它 SNI           → 127.0.0.1:4443         │
                         │        ├─ SITE_DOMAIN → Trojan + 文件站        │
                         │        └─ DOMAIN      → 回落网站(REALITY dest) │
                         └───────────────┬──────────────────────────────┘
                                         │ Caddy 统一 ACME 申请/续期证书
                                         ▼
   UDP 443 ────────────► ┌───────────┐  复制  ┌──────────────┐
                         │ Hysteria2 │ ◄───── │ ./data/certs  │
                         │  QUIC     │        │ fullchain.pem │
                         └───────────┘        │ privkey.pem   │
                              ▲ cert-sync 周期同步 └────────────┘
```

- **Caddy（定制镜像 `caddy-l4-trojan`）**：监听 443 做 layer4 SNI 分流；同时承载 Trojan、伪装网站，并通过 ACME 为 `DOMAIN` / `SITE_DOMAIN` **自动申请与续期**证书（持久化在 `./data/caddy`）。
- **Xray**：VLESS + XTLS-Vision + REALITY，仅内网监听 `5443`，由 Caddy 分流转入。REALITY 回落到本机 Caddy 网站，**借用自有域名**——被主动探测时会看到真实站点+真证书。
- **cert-sync** sidecar：把 Caddy 申请到的 `DOMAIN` 证书导出为固定文件名 `./data/certs/fullchain.pem` / `privkey.pem`，供 Hysteria2 复用。
- **config-init**：一次性容器，用 `.env` 把 Xray / Hysteria2 / Caddy 的模板渲染成实际配置写入 `./data`。
- 所有敏感参数（域名、UUID、密钥、密码）都在 `.env` 中，**换机器只改 `.env` + DNS 解析**即可。

---

## 二、前置条件

1. 一台有公网 IP 的 Linux 服务器，已安装 **Docker** 与 **Docker Compose 插件**。
2. **两个域名**（必须不同），都把 **A 记录解析到服务器公网 IP**：
   - `DOMAIN`：给 REALITY 的 SNI + Hysteria2 证书
   - `SITE_DOMAIN`：给 Trojan + 伪装网站
   > layer4 靠这两个不同的 SNI 来区分把流量给 REALITY 还是 Trojan/网站，所以**必须是两个域名**。
3. 放行防火墙/安全组端口：**TCP 80、TCP 443、UDP 443**。
   - TCP 80：ACME 证书验证 + HTTP 跳转
   - TCP 443：VLESS-REALITY / Trojan / 网站（Caddy 分流）
   - UDP 443：Hysteria2

---

## 三、部署步骤

```bash
# 1) 上传本项目到服务器后进入目录
cd X-Project

# 2) 构建定制 Caddy 镜像（含 layer4 + trojan 插件，首次约 2~4 分钟）
docker build -t caddy-l4-trojan:latest -f caddy.Dockerfile .

# 3) 一键生成 UUID / REALITY 密钥 / Trojan 密码 / Hysteria 密码
chmod +x gen.sh scripts/*.sh
./gen.sh

# 4) 编辑 .env，务必修改为你自己的域名与邮箱：
#      DOMAIN=your.domain.com          # REALITY + Hysteria2
#      SITE_DOMAIN=site.your.domain.com # Trojan + 网站（与 DOMAIN 不同）
#      REALITY_SERVER_NAME=your.domain.com  # 必须 = DOMAIN
#      ACME_EMAIL=admin@your.domain.com
vim .env

# 5) 启动全部服务
docker compose up -d

# 6) 查看日志，确认 Caddy 申请证书、cert-sync 导出、Hysteria2 启动
docker compose logs -f caddy cert-sync hysteria
```

看到 `cert-sync` 输出 `证书已更新`、`hysteria` 输出 `server up and running` 即部署成功。

> ⚠️ 编译 Caddy 较吃内存，小内存机器（≤1G）建议先加 swap，避免其它容器被 OOM。

---

## 四、客户端连接参数

运行 `cat .env` 获取密钥填入客户端。

### 1. VLESS-REALITY

| 项 | 值 |
|----|----|
| 地址 | 服务器 IP 或任意解析到本机的域名 |
| 端口 | 443 |
| 协议 | VLESS |
| UUID | `.env` 中的 `VLESS_UUID` |
| 流控 flow | `xtls-rprx-vision` |
| 传输 | TCP |
| 安全 | reality |
| SNI | **`DOMAIN`（= `.env` 中 `REALITY_SERVER_NAME`）** |
| Fingerprint | `chrome` |
| PublicKey | `.env` 中的 `REALITY_PUBLIC_KEY` |
| ShortId | `.env` 中的 `REALITY_SHORT_ID` |

### 2. Trojan

| 项 | 值 |
|----|----|
| 地址 | **`SITE_DOMAIN`**（走 TLS，需用域名） |
| 端口 | 443 |
| 协议 | Trojan |
| 密码 | `.env` 中的 `TROJAN_PASSWORD` |
| SNI | `SITE_DOMAIN` |

### 3. Hysteria2

| 项 | 值 |
|----|----|
| 地址 | **`DOMAIN`**（证书校验需要，不能用 IP） |
| 端口 | 443（UDP） |
| 密码 | `.env` 中的 `HYSTERIA_PASSWORD` |
| 混淆 obfs | `salamander` |
| 混淆密码 | `.env` 中的 `HYSTERIA_OBFS_PASSWORD` |
| SNI | `DOMAIN` |

#### Clash Verge Rev 示例（proxies 片段）

```yaml
proxies:
  - name: "VLESS-REALITY"
    type: vless
    server: your.domain.com        # 或服务器 IP
    port: 443
    uuid: <VLESS_UUID>
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: your.domain.com    # = DOMAIN
    client-fingerprint: chrome
    reality-opts:
      public-key: <REALITY_PUBLIC_KEY>
      short-id: <REALITY_SHORT_ID>

  - name: "Trojan"
    type: trojan
    server: site.your.domain.com   # = SITE_DOMAIN
    port: 443
    password: <TROJAN_PASSWORD>
    sni: site.your.domain.com
    udp: true

  - name: "Hysteria2"
    type: hysteria2
    server: your.domain.com        # = DOMAIN，必须用域名
    port: 443
    password: <HYSTERIA_PASSWORD>
    sni: your.domain.com
    obfs: salamander
    obfs-password: <HYSTERIA_OBFS_PASSWORD>
    up: "50 Mbps"
    down: "200 Mbps"
```

> Hysteria2 的 `up/down` 建议留空或设小值走 BBR 自适应；设得过高会触发 Brutal 硬发，在移动网络上易丢包连不上。

---

## 五、常用运维命令

```bash
docker compose ps                  # 查看服务状态
docker compose logs -f xray        # 看 Xray 日志
docker compose logs -f caddy       # 看 Caddy(分流/证书) 日志
docker compose restart hysteria    # 重启某个服务
docker compose down                # 停止（证书/配置保留在 ./data）
docker compose up -d               # 启动
```

---

## 六、换机器部署

1. 把整个目录（**含 `.env`，可不含 `data/`**）复制到新机器。
2. 把 `DOMAIN` 和 `SITE_DOMAIN` 的 DNS 解析都改到新机器 IP。
3. `docker build -t caddy-l4-trojan:latest -f caddy.Dockerfile .` 构建镜像。
4. `docker compose up -d`，Caddy 会在新机器上自动重新申请证书。

> 若想连证书一起迁移（免重新申请），把 `./data/caddy` 一并复制过去即可。

---

## 七、目录结构

```
X-Project/
├── docker-compose.yml                # 服务编排（443 共用架构）
├── caddy.Dockerfile                  # 构建 caddy-l4-trojan 定制镜像
├── .env.example                      # 环境变量模板
├── .env                              # 实际环境变量（gen.sh 生成，勿泄露）
├── gen.sh                            # 一键生成 UUID/密钥/密码
├── config/
│   ├── caddy/caddy.json.template     # Caddy layer4 分流 + trojan + 网站 + 证书模板
│   ├── site/index.html               # 伪装站首页（SITE_DOMAIN 展示）
│   ├── xray/config.json.template     # VLESS-REALITY 模板（内网 5443）
│   └── hysteria/config.yaml.template # Hysteria2 模板
├── scripts/
│   ├── render-config.sh              # 渲染 xray/hysteria/caddy 配置
│   └── cert-sync.sh                  # 导出 Caddy 证书供 Hysteria2 复用
└── data/                             # 运行时持久化（证书/配置/日志，容器外）
```

---

## 八、工作原理要点

- **为什么能共用 443**：Caddy 的 `layer4` 只读取 TLS ClientHello 里的 SNI（不解密），按域名把整条 TCP 连接**原样转发**给后端，REALITY 的特殊握手仍由 Xray 处理。
- **REALITY 借用自有域名**：`REALITY_DEST` 指向本机 Caddy 网站，`REALITY_SERVER_NAME = DOMAIN`。主动探测你的域名会看到 Caddy 提供的真实网站与真证书，比借用第三方站点更隐蔽。
  > 注意：REALITY 的 dest 若借用第三方站点，避免使用 Akamai CDN 类站点（如 `www.microsoft.com`），其对 REALITY 借用握手响应异常会导致连接被判为 invalid。
- **Xray 版本**：镜像固定为 `ghcr.io/xtls/xray-core:1.8.24`，与主流客户端（含 Shadowrocket）的 REALITY 实现兼容性好。
```
