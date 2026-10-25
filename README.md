# 3XUI-Server-Starter-Pack

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Ubuntu](https://img.shields.io/badge/OS-Ubuntu%20%7C%20Debian-orange.svg)](#)
[![Compatibility: 3X--UI](https://img.shields.io/badge/3X--UI-MHSanaei%20v2.x--v3.x-green.svg)](https://github.com/MHSanaei/3x-ui)
[![Telegram Bot: 3XUI--Shop--Bot](https://img.shields.io/badge/Bot-3XUI--Shop--Bot-blueviolet.svg)](https://github.com/AliFanni-79/3XUI-Shop-Bot)

An automated, production-grade reverse proxy gateway and synchronization suite for **MHSanaei's 3X-UI panel**, **3XUI-Shop-Bot**, and **Nginx**.

Multiplexes all inbound proxy connections onto a single public port (`443`), exposes the 3X-UI web panel and subscription links behind clean SSL reverse proxies, handles automated database synchronization, and enforces maximum stealth protection.

---

## Key Features

- **Multi-Protocol & Transport Support**:
  - Protocols: `VLESS`, `VMess`, `Trojan`, `Shadowsocks`.
  - Networks: `WebSocket (ws)`, `HttpUpgrade`, `gRPC`, `XHTTP / SplitHTTP`, and `Raw TCP`.
  - Security Modes: `none` (TLS terminated by Nginx), `tls` (Trojan & TLS guard), and `reality`.
- **ECH (Encrypted Client Hello) Preservation**:
  - Automatically extracts and preserves `ech_config_list` parameters when creating or synchronizing 3X-UI Host records.
- **Full REALITY Support**:
  - Detects REALITY inbounds and automatically creates synchronized entries in the modern 3X-UI `hosts` table with `security: "reality"`, preserving SNI, Fingerprint, Short IDs, and ECH configs.
- **Stealth Camouflage (`return 444;`)**:
  - Accessing `https://yourdomain.com/` directly or probing unknown paths immediately drops the TCP connection without returning any HTTP headers or HTML, mimicking a dead or non-existent server.
- **Secret Path Protection (No 302 Leaks)**:
  - Bare requests to the panel (`:2083/`) or subscriptions (`:2096/`) will **never** issue an HTTP 302 redirect revealing your secret paths. Only users and clients that know the exact secret URL can access them.
- **Subscription Reverse Proxy Integration**:
  - Automatically configures `subDomain`, `subPort`, and `subPath` in 3X-UI's database so all client subscription links output `https://yourdomain.com:2096/sub/...` with TLS enabled.
- **Pre-Configuration Detection & Update Mode**:
  - Automatically checks if 3X-UI and Nginx were already configured together before running the script.
  - If existing working routes are detected (e.g. panel already proxied, or certain inbounds already configured), offers **Update & Completion Mode** to only add missing inbounds and subscription proxies without touching or redoing working rules.
- **Granular Rule-by-Rule Conflict Resolver**:
  - Checks for exact `(domain, port, path)` conflicts before modifying anything:
    - **Root Path (`/`)**: If a website (WordPress, static HTML, or web app) is already configured on port 443 for your domain, prompts whether to keep the website (routing VPN inbounds alongside it) or replace with Stealth Drop (`444`).
    - **Panel (`:2083`) & Subscriptions (`:2096`)**: Detects existing reverse proxy rules and allows keeping them untouched.
    - **Overwrite All**: Backs up old configurations to `/etc/nginx/backup_<timestamp>` and establishes a clean gateway.
- **3XUI-Shop-Bot Integration**:
  - Optionally installs [AliFanni-79/3XUI-Shop-Bot](https://github.com/AliFanni-79/3XUI-Shop-Bot) via its official installer and creates an automated `xui-sync` hook.
- **Lightweight `xui-sync` CLI**:
  - Provides a single-command utility (`xui-sync`) to check status, view the 3X-UI `hosts` table, test Nginx, or force manual synchronization.
- **Automated Zero-Downtime Watcher (`systemd.path`)**:
  - Monitors `/etc/x-ui/x-ui.db`. Whenever an inbound is modified, added, or deleted, Nginx reloads in the background **without restarting 3X-UI**, ensuring zero downtime.
- **High-Throughput Streaming & RAM Safety**:
  - Enables `client_max_body_size 0;` and `proxy_request_buffering off;` on VPN inbounds for unlimited XHTTP/SplitHTTP chunk streaming without RAM or disk buffering. Enables SQLite WAL mode to prevent database locks.

---

## Architecture Overview

```
                          Internet (Clients & Censorship Probes)
                                           │
         ┌───────────────────┬─────────────┴───────┬────────────────────┐
         │ (Port 443)        │ (Port 2083)         │ (Port 2096)        │ (Port 8443)
         ▼                   ▼                     ▼                    ▼
   ┌───────────┐       ┌───────────┐         ┌───────────┐        ┌───────────┐
   │ Inbounds  │       │  3X-UI    │         │  3X-UI    │        │  Shop Bot │
   │  Gateway  │       │ Web Panel │         │   Subs    │        │   WebUI   │
   └─────┬─────┘       └─────┬─────┘         └─────┬─────┘        └─────┬─────┘
         │                   │                     │                    │
 ┌───────┴────────┐          │                     │                    │
 │ Path Routing   │          │                     │                    │
 ├────────────────┤          │                     │                    │
 │ /vless-ws-1    │──► (127.0.0.1:10001)           │                    │
 │ /vless-xhttp-2 │──► (127.0.0.1:10002)           │                    │
 │ /grpc-trojan-3 │──► (127.0.0.1:10003)           │                    │
 │ / (Root)       │──► [return 444; Drop]          │                    │
 └────────────────┘          │                     │                    │
                             ▼                     ▼                    ▼
                      (127.0.0.1:20830)     (127.0.0.1:20960)    (127.0.0.1:8080)
```

---

## Installation

### Option 1: Full Automated Installation (New or Existing Server)

Installs dependencies, configures Nginx, verifies/installs latest 3X-UI, sets up the sync engine, and optionally installs 3XUI-Shop-Bot:

**One-Line Command (Universal - Root or Sudo):**
```bash
sudo bash -c "$(curl -Ls https://raw.githubusercontent.com/AliFanni-79/3XUI-Server-Starter-Pack/master/install.sh)"
```
*(Or if already logged in as root)*:
```bash
bash <(curl -Ls https://raw.githubusercontent.com/AliFanni-79/3XUI-Server-Starter-Pack/master/install.sh)
```

<details>
<summary>Manual Git Clone Alternative</summary>

```bash
git clone https://github.com/AliFanni-79/3XUI-Server-Starter-Pack.git /root/3XUI-Server-Starter-Pack
cd /root/3XUI-Server-Starter-Pack
chmod +x install.sh
./install.sh
```
</details>

---

### Option 2: Standalone Sync Installation (Existing 3X-UI & Bot)

If you **already have 3X-UI and/or 3XUI-Shop-Bot running** and only want to install the Nginx gateway and automated synchronization without touching your existing services:

**One-Line Command (Universal - Root or Sudo):**
```bash
sudo bash -c "$(curl -Ls https://raw.githubusercontent.com/AliFanni-79/3XUI-Server-Starter-Pack/master/standalone-sync-setup.sh)"
```
*(Or if already logged in as root)*:
```bash
bash <(curl -Ls https://raw.githubusercontent.com/AliFanni-79/3XUI-Server-Starter-Pack/master/standalone-sync-setup.sh)
```

<details>
<summary>Manual Git Clone Alternative</summary>

```bash
git clone https://github.com/AliFanni-79/3XUI-Server-Starter-Pack.git /root/3XUI-Server-Starter-Pack
cd /root/3XUI-Server-Starter-Pack
chmod +x standalone-sync-setup.sh
./standalone-sync-setup.sh
```
</details>

---

## CLI Control Tool: `xui-sync`

A lightweight CLI tool is installed to `/usr/local/bin/xui-sync`:

```bash
# Run manual synchronization (always bypasses the debounce window)
xui-sync

# Dashboard: services, public endpoints and listening ports
xui-sync status

# Health checks: config, certificate expiry, WAL mode, services, nginx -t, ports
xui-sync doctor

# Inspect active 3X-UI Hosts table (addresses, ports, ECH, SNI)
xui-sync hosts

# Print the gateway configuration
xui-sync config

# Force synchronization & Nginx reload
xui-sync reload

# Follow live logs of background database watcher
xui-sync log
```

### Unattended installation

Every prompt can be pre-answered with an `XUI_<NAME>` environment variable, which also makes the installers usable without a terminal:

```bash
XUI_DOMAIN=vpn.example.com XUI_INBOUNDS_PORT=443 XUI_HAS_BOT=n \
XUI_ISSUE=y bash install.sh
```

Variables: `XUI_DOMAIN`, `XUI_INBOUNDS_PORT`, `XUI_PANEL_PUBLIC_PORT`, `XUI_SUB_PUBLIC_PORT`, `XUI_SUB_PATH`, `XUI_HAS_BOT`, `XUI_BOT_PUBLIC_PORT`, `XUI_BOT_INTERNAL_PORT`, `XUI_ISSUE` (Let's Encrypt), `XUI_SSL_CERT`, `XUI_SSL_KEY`, `XUI_NGINX_CHOICE` (1-3). Set `NO_COLOR=1` for plain output. Long-running command output is logged to `/var/log/xui-starter-pack.log`.

---

## Repository Structure

```text
3XUI-Server-Starter-Pack/
├── install.sh                  # Interactive master installer & orchestrator
├── standalone-sync-setup.sh    # Standalone gateway installer for existing servers
├── core/
│   ├── lib.sh                  # Shared UI (banner, steps, boxes, spinner) & validated prompts
│   ├── deploy.sh               # Install steps shared by both installers
│   ├── sync_engine.py          # Unified Python sync engine (ECH, REALITY, Hosts, Inbounds, Nginx)
│   ├── nginx_inspector.py      # Pre-configuration detector & granular (domain, port, path) resolver
│   ├── nginx_manager.sh        # Nginx conflict resolver wrapper
│   ├── xui_manager.sh          # Installs/verifies 3X-UI, sets WAL mode & subDomain reverse proxy
│   └── bot_manager.sh          # Optional 3XUI-Shop-Bot installer & integration hook
├── bin/
│   └── xui-sync                # Lightweight CLI utility (/usr/local/bin/xui-sync)
├── systemd/
│   ├── xui-nginx-sync.service  # Oneshot synchronization service
│   └── xui-nginx-sync.path     # Real-time /etc/x-ui/x-ui.db file watcher
└── README.md                   # Documentation
```

---

## Verification & Testing

1. **Verify Services**:
   ```bash
   xui-sync status
   ```
2. **Test Stealth Root Drop**:
   ```bash
   curl -I https://yourdomain.com/
   ```
   *Expected output*: `curl: (52) Empty reply from server` (Zero bytes returned).
3. **Verify 3X-UI Panel Access**:
   Open `https://yourdomain.com:2083/your-secret-base-path/`.
4. **Verify Subscription Links**:
   Subscription links generated in 3X-UI or Shop-Bot will automatically point to `https://yourdomain.com:2096/sub/...`.

---

## License

This project is open-source and licensed under the [MIT License](LICENSE).
