# X-Project: VLESS-REALITY + Trojan + Hysteria2 · Shared-443 One-Click Deploy

Deploy three proxy protocols with Docker Compose. Using **Caddy layer4 (L4) SNI routing**, **VLESS-REALITY, Trojan, and the decoy website share a single TCP 443**, while **Hysteria2 owns UDP 443**. Every protocol runs on the standard 443 port; an active probe only ever sees a real website with a real certificate — **strong stealth, better censorship resistance**.

| Protocol | Core | Entry | Domain (SNI) | Certificate | Use case |
|----------|------|-------|--------------|-------------|----------|
| **VLESS + XTLS-Vision + REALITY** | Xray 26.6.27 | **TCP 443** (Caddy routing) | `DOMAIN` | Borrows your own domain's real cert for camouflage | Daily driver, censorship resistance |
| **Trojan** | Caddy (caddy-trojan) | **TCP 443** (Caddy routing) | `SITE_DOMAIN` | Auto-issued by Caddy | Backup channel |
| **Hysteria2** | hysteria v2.10.0 | **UDP 443** | `DOMAIN` | Reuses Caddy's cert (hot reload) | Peak hours, weak networks, streaming |

> TCP 443 and UDP 443 share the same port number but different protocols, so they don't conflict. On TCP 443, Caddy further routes by SNI to REALITY / Trojan / website.

---

## Table of Contents

- [1. Architecture](#1-architecture)
- [2. Directory Layout](#2-directory-layout)
- [3. Prerequisites](#3-prerequisites)
- [4. Deployment Steps](#4-deployment-steps)
- [5. .env Reference](#5-env-reference)
- [6. Client Connection Parameters](#6-client-connection-parameters)
- [7. How It Works](#7-how-it-works)
- [8. Common Ops Commands](#8-common-ops-commands)
- [9. Troubleshooting (Lessons Learned)](#9-troubleshooting-lessons-learned)
- [10. Migrating to a New Machine](#10-migrating-to-a-new-machine)

---

## 1. Architecture

```
                          ┌─────────────────────────────────────────────────┐
   TCP 443 ─────────────► │  x-caddy (layer4 SNI routing, reads ClientHello   │
                          │           SNI only, no decryption)                │
                          │                                                   │
                          │   SNI = DOMAIN      → x-xray:5443  (VLESS-REALITY) │
                          │   other SNI         → 127.0.0.1:4443 (Caddy local) │
                          │        ├─ Host=SITE_DOMAIN → Trojan + file site    │
                          │        └─ Host=DOMAIN      → file site (REALITY    │
                          │                              fallback)             │
                          └───────────────┬─────────────────────────────────┘
                                          │ Caddy handles ACME(LE) issuance/renewal
                                          │ stored under ./data/caddy/certificates/...
                                          ▼ (read-only mount /caddy-certs, auto hot reload)
   UDP 443 ─────────────► ┌───────────┐
                          │ x-hysteria│  reads Caddy's DOMAIN cert files directly
                          │  QUIC     │
                          └───────────┘
   TCP 80  ─────────────► x-caddy (ACME HTTP-01 validation + HTTP→HTTPS redirect)
```

Four containers (managed by `docker compose`):

| Container | Image | Listens | Role |
|-----------|-------|---------|------|
| `x-config-init` | `alpine:3.20` | — | **One-shot** container: renders the xray/hysteria/caddy configs from `.env` into `./data`, then exits |
| `x-caddy` | `caddy-l4-trojan:latest` (self-built) | 80, 443/tcp (public); 4443 (internal) | layer4 SNI routing + Trojan + decoy website + automatic ACME issuance/renewal |
| `x-xray` | `ghcr.io/xtls/xray-core:26.6.27` | 5443 (internal only) | VLESS + XTLS-Vision + REALITY, fed by Caddy routing |
| `x-hysteria` | `tobyxdd/hysteria:v2.10.0` | 443/udp (public) | Hysteria2, reads Caddy's cert directory via read-only mount |

**Key design points:**
- **Shared 443**: Caddy's `layer4` reads only the SNI from the TLS ClientHello (no decryption) and forwards the entire TCP connection **as-is** to the backend based on the domain; REALITY's special handshake is still handled by Xray.
- **REALITY borrows your own domain**: `REALITY_DEST` points to the local Caddy website (`x-caddy:4443`) and the SNI is `DOMAIN`. Under active probing, the observer sees the **real website + real certificate** served by Caddy — stealthier than borrowing a third-party site.
- **Zero-relay certificates**: after Caddy issues certs, Hysteria2 reads them directly via a read-only mount of the cert directory; on renewal Caddy updates the files in place and Hysteria2 **hot-reloads automatically, no restart needed** (no cert-sync sidecar).

---

## 2. Directory Layout

```
X-Project/
├── docker-compose.yml                # Service orchestration (4 services, shared-443 architecture)
├── caddy.Dockerfile                  # Builds the custom caddy-l4-trojan image (caddy 2.11.4 + layer4 + trojan)
├── .env.example                      # Environment variable template
├── .env                              # Actual env vars (generated by gen.sh, contains secrets, gitignored)
├── gen.sh                            # One-click generator for UUID / REALITY keys / Trojan & Hysteria passwords
├── config/
│   ├── caddy/caddy.json.template     # Caddy layer4 routing + trojan + website + certs (JSON template)
│   ├── site/index.html               # Decoy site homepage (shown when DOMAIN / SITE_DOMAIN is visited)
│   ├── xray/config.json.template     # VLESS-REALITY template (internal 5443)
│   └── hysteria/config.yaml.template # Hysteria2 template (reads Caddy certs directly)
├── scripts/
│   └── render-config.sh              # Renders the xray/hysteria/caddy configs (runs inside an alpine container)
└── data/                             # Runtime persistence (certs/rendered configs/logs, outside containers, gitignored)
    ├── caddy/                        #   Caddy rendered config + cert storage
    ├── xray/                         #   Rendered xray config (logs go to stdout, no longer written to disk)
    └── hysteria/                     #   Rendered hysteria config
```

---

## 3. Prerequisites

1. A Linux server with a public IP, with **Docker** and the **Docker Compose plugin** installed.
   - RAM ≥ 1G recommended; **compiling Caddy is memory-hungry, so on low-memory machines add 2G of swap first** (see Troubleshooting).
2. **Two domains** (must be different), both with A records pointing to the server's public IP:

   | Variable | Purpose | Example |
   |----------|---------|---------|
   | `DOMAIN` | REALITY's SNI + Hysteria2 cert | `a.example.com` |
   | `SITE_DOMAIN` | Trojan + decoy website | `b.example.com` |

   > Why two domains: layer4 uses **different SNIs** to decide "does this connection go to REALITY or to Trojan/website". Both domains just need to point to the same machine.
3. Open the firewall / cloud security group ports: **TCP 80, TCP 443, UDP 443**.
   - TCP 80: ACME cert validation (HTTP-01) + HTTP→HTTPS redirect
   - TCP 443: VLESS-REALITY / Trojan / website (Caddy routing)
   - UDP 443: Hysteria2 (**cloud security groups often block UDP by default — be sure to check**)

---

## 4. Deployment Steps

```bash
# 1) Clone this repo onto the server and enter the directory
git clone git@github.com:anwenzen/X-Project.git
cd X-Project

# 2) Build the custom Caddy image (with layer4 + trojan plugins; ~2-4 min on first build)
docker build -t caddy-l4-trojan:latest -f caddy.Dockerfile .

# 3) One-click generate UUID / REALITY keys / Trojan password / Hysteria password (auto-written to .env)
chmod +x gen.sh scripts/*.sh
./gen.sh

# 4) Edit .env and set the following three to your own values (the rest is filled by gen.sh):
#      DOMAIN=a.example.com
#      SITE_DOMAIN=b.example.com     # must differ from DOMAIN
#      ACME_EMAIL=you@example.com
vim .env

# 5) Start all services
docker compose up -d

# 6) Watch cert issuance and startup
docker compose logs -f caddy hysteria
```

When the `caddy` log shows a successful cert issuance and `hysteria` prints `server up and running`, deployment succeeded.

> On a **brand-new first deploy**, Caddy needs a few tens of seconds to obtain a certificate; during that window Hysteria2 may restart a few times because it can't read the cert yet. It stabilizes automatically once the cert is ready — this is normal.

Verify the services:
```bash
docker compose ps                                   # Four containers should be Up (config-init being Exited 0 is normal)
# REALITY camouflage layer: a TLS handshake to 443 should return DOMAIN's real cert
echo | openssl s_client -connect 127.0.0.1:443 -servername <DOMAIN> 2>/dev/null | openssl x509 -noout -subject
# Website: should return 200
curl -sI https://<SITE_DOMAIN> | head -1
```

---

## 5. .env Reference

| Variable | Description | Source |
|----------|-------------|--------|
| `DOMAIN` | Primary domain. REALITY's SNI + Hysteria2's cert domain | **Set manually** |
| `SITE_DOMAIN` | Site domain. Trojan + decoy website (must differ from `DOMAIN`) | **Set manually** |
| `ACME_EMAIL` | Email for ACME cert issuance (Let's Encrypt expiry reminders) | **Set manually** |
| `VLESS_UUID` | VLESS client UUID | gen.sh |
| `REALITY_DEST` | REALITY fallback target, fixed at `x-caddy:4443` (local Caddy website) | Preset |
| `REALITY_PRIVATE_KEY` | REALITY x25519 private key (server side) | gen.sh |
| `REALITY_PUBLIC_KEY` | REALITY x25519 public key (**for the client**) | gen.sh |
| `REALITY_SHORT_ID` | REALITY shortId (16 hex chars) | gen.sh |
| `TROJAN_PASSWORD` | Trojan connection password | gen.sh |
| `HYSTERIA_PASSWORD` | Hysteria2 auth password | gen.sh |
| `HYSTERIA_OBFS_PASSWORD` | Hysteria2 Salamander obfuscation password (leave empty to disable obfs) | gen.sh |
| `HYSTERIA_UP_MBPS` / `HYSTERIA_DOWN_MBPS` | Server bandwidth ceiling (QUIC congestion-control reference) | Preset 1000 |
| `MASQUERADE_UPSTREAM` | Website Hysteria2 reverse-proxies to when actively probed | Preset |

> REALITY's SNI is **no longer configured separately** — it reuses `DOMAIN` (written into the xray config at render time).

---

## 6. Client Connection Parameters

After deploying, run `cat .env` to get the secrets. Replace `<...>` below with your actual values.

### 1. VLESS-REALITY (TCP 443)

| Field | Value |
|-------|-------|
| Address | Server IP or `DOMAIN` |
| Port | `443` |
| Protocol | VLESS |
| UUID | `<VLESS_UUID>` |
| Flow | `xtls-rprx-vision` |
| Transport | TCP |
| Security | reality |
| SNI / peer | **`<DOMAIN>`** |
| Fingerprint | `chrome` |
| PublicKey (pbk) | `<REALITY_PUBLIC_KEY>` |
| ShortId (sid) | `<REALITY_SHORT_ID>` |

### 2. Trojan (TCP 443)

| Field | Value |
|-------|-------|
| Address | **`<SITE_DOMAIN>`** (uses TLS, must be a domain) |
| Port | `443` |
| Protocol | Trojan |
| Password | `<TROJAN_PASSWORD>` |
| SNI | `<SITE_DOMAIN>` |

### 3. Hysteria2 (UDP 443)

| Field | Value |
|-------|-------|
| Address | **`<DOMAIN>`** (cert validation requires a domain, not an IP) |
| Port | `443` (UDP) |
| Password | `<HYSTERIA_PASSWORD>` |
| obfs | `salamander` |
| obfs password | `<HYSTERIA_OBFS_PASSWORD>` |
| SNI | `<DOMAIN>` |
| Up/Down bandwidth | **Leave empty** (let BBR self-adapt; never set too high) |

### Clash Verge Rev Example

```yaml
proxies:
  - name: "VLESS-REALITY"
    type: vless
    server: a.example.com          # DOMAIN or server IP
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
    server: a.example.com          # = DOMAIN, must be a domain
    port: 443
    password: <HYSTERIA_PASSWORD>
    sni: a.example.com
    obfs: salamander
    obfs-password: <HYSTERIA_OBFS_PASSWORD>
    # Leave up/down empty for BBR self-adaptation; or set small values like up: "20 Mbps" down: "100 Mbps"
```

---

## 7. How It Works

### 7.1 SNI routing on TCP 443

Caddy uses the `caddy-l4` plugin to do L4 proxying on 443, reading only the ClientHello SNI without decryption:

| ClientHello SNI | Forwarded to | Subsequent handling |
|-----------------|--------------|---------------------|
| `DOMAIN` | `x-xray:5443` | Xray handles the VLESS-REALITY handshake |
| Others (incl. `SITE_DOMAIN`) | `127.0.0.1:4443` | Caddy's local HTTP service (with trojan wrapper) |

Once at local 4443, Caddy splits further by HTTP Host:
- `Host = SITE_DOMAIN`: first pass through Trojan (`caddy-trojan`, decodes Trojan-over-TLS); non-Trojan traffic falls to the file site `/srv`
- `Host = DOMAIN`: file site `/srv` (this is exactly the real website a prober sees during **REALITY fallback**)

### 7.2 REALITY "borrowing" and fallback

- A REALITY client handshakes with the correct `pbk`/`sid`/UUID → Xray authenticates and proxies.
- An unauthenticated **active probe** (e.g. a browser hitting `https://DOMAIN` directly) → Xray falls the connection back to `REALITY_DEST=x-caddy:4443`, and Caddy responds with `DOMAIN`'s real cert + real website. The prober sees a normally operating website and cannot tell this is a proxy entry point.

### 7.3 Certificate lifecycle

1. Caddy issues certs for `DOMAIN` and `SITE_DOMAIN` via ACME (Let's Encrypt), stored under `./data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/<domain>/`.
2. Hysteria2 read-only mounts `./data/caddy` → container `/caddy-certs`, and its config points directly to `DOMAIN`'s `.crt`/`.key`.
3. Caddy auto-renews → updates the cert files in place → Hysteria2 **hot-reloads automatically**, no manual intervention.

> ⚠️ The cert path hard-codes the ACME CA directory name `acme-v02.api.letsencrypt.org-directory` (Let's Encrypt). `caddy.json.template` is locked to LE only, so the path is stable. If you switch to another CA, also update the path in `config/hysteria/config.yaml.template`.

---

## 8. Common Ops Commands

```bash
cd X-Project

docker compose ps                       # Service status
docker compose logs -f caddy            # Caddy routing / cert logs
docker compose logs -f xray             # Xray logs (from 26.6.27, goes to stdout; no longer writes data/xray/*.log)
docker logs x-hysteria --tail 30        # Hysteria2 logs
docker compose restart hysteria         # Restart a single service
docker compose down                     # Stop (certs/configs kept in ./data)
docker compose up -d                    # Start

# After editing .env: config-init uses env_file, so you must recreate to re-render/re-inject (restart won't do it)
docker compose up -d --force-recreate --no-deps config-init
docker compose up -d --force-recreate --no-deps xray hysteria caddy

# Enable Xray debug to capture connections (remember to switch back to warning and restart x-xray afterward)
sed -i 's/"loglevel": "warning"/"loglevel": "debug"/' data/xray/config.json && docker restart x-xray
```

---

## 9. Troubleshooting (Lessons Learned)

Organized from pitfalls actually hit on this project — check here first when something breaks:

1. **Xray version**: currently pinned to `26.6.27`. Testing showed `26.7.11` handshakes unreliably with some clients' built-in REALITY implementations (e.g. Shadowrocket); `24.x / 25.x / 26.6.27` and earlier are all fine. **Always validate on a test port before upgrading, and don't just switch to `latest`** (a bisection confirmed `26.6.27` is the latest stably usable version).
2. **Don't use an Akamai CDN site as the REALITY dest** (e.g. `www.microsoft.com`): it causes the server to flag all clients as `invalid connection`. This project uses its own domain for fallback, avoiding the issue.
3. **Hysteria2 client bandwidth must be empty / set small**: setting it too high triggers the Brutal congestion control's "hard send", which instantly saturates the link and causes heavy packet loss on mobile networks — the symptom is "**connects but can't transfer**" (log `accepting stream failed: timeout`). Leaving it empty (BBR) is the most stable.
4. **VLESS won't connect, server log `server name mismatch`**: the client SNI is wrong (not `DOMAIN`), or a stale node lingers on the phone. Confirm client SNI/peer = `DOMAIN` and delete old nodes.
5. **VLESS won't connect, server log `authentication failed`**: `pbk`/`sid` don't match the server, or the client-server clock skew is too large (REALITY has timestamp validation). Double-check the keys and enable "set time automatically" on the phone.
6. **`.env` changes not taking effect**: `config-init` uses `env_file`; `docker restart` won't re-inject/re-render — you must `docker compose up -d --force-recreate` to recreate the relevant containers.
7. **Phone can't connect over UDP 443**: first check whether the **cloud security group** allows UDP 443 (a local `ufw`/`iptables` allow doesn't mean the cloud console allows it).
8. **Other containers OOM-killed while compiling Caddy** (low-memory machines): add swap:
   ```bash
   fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
   echo '/swapfile none swap sw 0 0' >> /etc/fstab
   ```
9. **Hysteria2 restarts repeatedly on first deploy**: the cert isn't issued yet — this is normal; it stabilizes once Caddy obtains the cert.
10. **Newer Xray images (from 24.x) run as the non-root user `65532`**: if the config specifies `access`/`error` log file paths (e.g. `/etc/xray/access.log`), the container restarts repeatedly because it can't write to `/etc/xray/` (log `open /etc/xray/access.log: permission denied`). This project's template has been changed to **not write log files — logs go to stdout** (view with `docker logs x-xray`), so `data/xray` can stay root-owned and needs no special chown. **Do not** add `access`/`error` file paths back into the config.

---

## 10. Migrating to a New Machine

1. On the new machine, `git clone git@github.com:anwenzen/X-Project.git` (the repo does not include `.env`).
2. Follow "[4. Deployment Steps](#4-deployment-steps)" to build the image, run `./gen.sh`, and fill in `.env` (or copy `.env` from the old machine to keep the same UUID/keys).
3. Point the DNS of `DOMAIN` and `SITE_DOMAIN` to the new machine's IP.
4. `docker compose up -d`; Caddy will obtain certificates automatically.

> To migrate the certs too (avoiding re-issuance): just copy the old machine's `./data/caddy` over as well.

---

## Appendix: Image Versions

| Component | Image | Version |
|-----------|-------|---------|
| Caddy (self-built) | `caddy-l4-trojan:latest` | Based on `caddy:2.11.4` + `caddy-l4` + `caddy-trojan` |
| Xray | `ghcr.io/xtls/xray-core` | `26.6.27` |
| Hysteria2 | `tobyxdd/hysteria` | `v2.10.0` |
| Render/tools | `alpine` | `3.20` |

> All versions are pinned to ensure reproducibility (historically, Xray version drift caused handshake incompatibilities).
