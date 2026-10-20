#!/usr/bin/env bash
set -e

# ==============================================================================
# 3XUI-Server-Starter-Pack: Master Orchestrator & Installer
# Integrates: MHSanaei 3X-UI + Nginx Path Gateway + ECH/REALITY + 3XUI-Shop-Bot
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This installer must be run as root.${NC}"
   exit 1
fi

REPO_URL="${XUI_GATEWAY_REPO:-https://github.com/AliFanni-79/3XUI-Server-Starter-Pack.git}"
TARGET_DIR="/root/3XUI-Server-Starter-Pack"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"

# Self-bootstrap if executed directly via curl / pipe
if [[ ! -d "$SCRIPT_DIR/core" ]]; then
    echo -e "${BLUE}[*] Bootstrapping 3XUI-Server-Starter-Pack repository...${NC}"
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y git curl >/dev/null 2>&1 || true
    rm -rf "$TARGET_DIR"
    if ! git clone -q "$REPO_URL" "$TARGET_DIR"; then
        echo -e "${RED}[-] Failed to clone repository from ${REPO_URL}${NC}"
        echo -e "${YELLOW}[!] If using a custom fork or branch, run: export XUI_GATEWAY_REPO=https://github.com/your/repo.git${NC}"
        exit 1
    fi
    exec bash "$TARGET_DIR/install.sh" "$@"
fi

echo -e "${CYAN}"
echo "=========================================================="
echo "    __  ______  __    _   __      _            "
echo "   / / / / __ \/ /   / | / /___ _(_)___  _  __ "
echo "  / /_/ / / / / /   /  |/ / __ \`/ / __ \| |/_/ "
echo " / __  / /_/ / /___/ /|  / /_/ / / / / />  <   "
echo "/_/ /_/\____/_____/_/ |_/\__, /_/_/ /_/_/|_|   "
echo "                        /____/                 "
echo "        3X-UI + Nginx Gateway + Shop-Bot Setup "
echo "=========================================================="
echo -e "${NC}"

# 1. Install System Dependencies
echo -e "${BLUE}[*] Updating package repositories & installing dependencies...${NC}"
apt-get update -y
apt-get install -y nginx python3 python3-pip sqlite3 certbot python3-certbot-nginx curl git rsync

# 2. Gather Configuration
echo ""
echo -e "${YELLOW}--- Gateway Network Configuration ---${NC}"
read -rp "Enter your Domain Name (e.g. vpn.example.com): " DOMAIN
while [[ -z "$DOMAIN" ]]; do
    echo -e "${RED}Domain name cannot be empty.${NC}"
    read -rp "Enter your Domain Name: " DOMAIN
done

read -rp "Enter Inbounds Public Gateway Port [default: 443]: " INBOUNDS_PORT
INBOUNDS_PORT=${INBOUNDS_PORT:-443}

read -rp "Enter 3X-UI Web Panel Public Port [default: 2083]: " PANEL_PUBLIC_PORT
PANEL_PUBLIC_PORT=${PANEL_PUBLIC_PORT:-2083}

read -rp "Enter 3X-UI Subscription Public Port [default: 2096]: " SUB_PUBLIC_PORT
SUB_PUBLIC_PORT=${SUB_PUBLIC_PORT:-2096}

read -rp "Enter Telegram Bot WebUI Public Port [default: 8443]: " BOT_PUBLIC_PORT
BOT_PUBLIC_PORT=${BOT_PUBLIC_PORT:-8443}

read -rp "Enter Telegram Bot Local Port [default: 8080]: " BOT_INTERNAL_PORT
BOT_INTERNAL_PORT=${BOT_INTERNAL_PORT:-8080}

read -rp "Enter 3X-UI Subscription URL Root Path [default: /sub/]: " SUB_PATH
SUB_PATH=${SUB_PATH:-/sub/}
[[ "$SUB_PATH" != /* ]] && SUB_PATH="/$SUB_PATH"
[[ "$SUB_PATH" != */ ]] && SUB_PATH="$SUB_PATH/"

# 3. SSL Certificate Setup
echo ""
echo -e "${YELLOW}--- SSL Certificate Configuration ---${NC}"
DEFAULT_LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
DEFAULT_LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
CUSTOM_ROOT_CERT="/root/cert/${DOMAIN}/fullchain.pem"
CUSTOM_ROOT_KEY="/root/cert/${DOMAIN}/privkey.pem"

SSL_CERT=""
SSL_KEY=""

if [[ -f "$CUSTOM_ROOT_CERT" && -f "$CUSTOM_ROOT_KEY" ]]; then
    SSL_CERT="$CUSTOM_ROOT_CERT"
    SSL_KEY="$CUSTOM_ROOT_KEY"
    echo -e "${GREEN}[+] Detected SSL certificate in /root/cert/${DOMAIN}.${NC}"
elif [[ -f "$DEFAULT_LE_CERT" && -f "$DEFAULT_LE_KEY" ]]; then
    SSL_CERT="$DEFAULT_LE_CERT"
    SSL_KEY="$DEFAULT_LE_KEY"
    echo -e "${GREEN}[+] Detected Let's Encrypt certificate in /etc/letsencrypt/live/${DOMAIN}.${NC}"
else
    echo "No existing certificate found for $DOMAIN."
    read -rp "Issue a free Let's Encrypt SSL certificate automatically now? (y/N): " ISSUE_SSL
    if [[ "$ISSUE_SSL" =~ ^[Yy]$ ]]; then
        systemctl stop nginx 2>/dev/null || true
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
        SSL_CERT="$DEFAULT_LE_CERT"
        SSL_KEY="$DEFAULT_LE_KEY"
        systemctl start nginx 2>/dev/null || true
    else
        read -rp "Enter full path to your fullchain.pem: " SSL_CERT
        read -rp "Enter full path to your privkey.pem: " SSL_KEY
    fi
fi

# 4. Resolve Preconfigured Nginx Conflicts
chmod +x "$SCRIPT_DIR/core/nginx_manager.sh"
bash "$SCRIPT_DIR/core/nginx_manager.sh" "$INBOUNDS_PORT" "$PANEL_PUBLIC_PORT" "$SUB_PUBLIC_PORT"

# 5. Install / Verify 3X-UI Panel
chmod +x "$SCRIPT_DIR/core/xui_manager.sh"
bash "$SCRIPT_DIR/core/xui_manager.sh" "$DOMAIN" "$SUB_PUBLIC_PORT" "$PANEL_PUBLIC_PORT" 20830 20960

# 6. Install / Integrate 3XUI-Shop-Bot (Optional)
chmod +x "$SCRIPT_DIR/core/bot_manager.sh"
bash "$SCRIPT_DIR/core/bot_manager.sh" "$DOMAIN" 20830

# 7. Deploy Nginx Gateway Sync Engine
echo -e "${BLUE}[*] Deploying synchronization engine and systemd watcher...${NC}"
mkdir -p /etc/x-ui
cat << EOF > /etc/x-ui/nginx_proxy.json
{
  "domain": "${DOMAIN}",
  "ssl_cert": "${SSL_CERT}",
  "ssl_key": "${SSL_KEY}",
  "inbounds_port": ${INBOUNDS_PORT},
  "panel_public_port": ${PANEL_PUBLIC_PORT},
  "panel_internal_port": 20830,
  "sub_public_port": ${SUB_PUBLIC_PORT},
  "sub_internal_port": 20960,
  "bot_public_port": ${BOT_PUBLIC_PORT},
  "bot_internal_port": ${BOT_INTERNAL_PORT},
  "sub_path": "${SUB_PATH}",
  "db_path": "/etc/x-ui/x-ui.db",
  "nginx_conf_path": "/etc/nginx/conf.d/xui_proxy.conf"
}
EOF

# Install sync script
cp "$SCRIPT_DIR/core/sync_engine.py" /usr/local/bin/xui-nginx-sync.py
chmod +x /usr/local/bin/xui-nginx-sync.py

# Install CLI tool
cp "$SCRIPT_DIR/bin/xui-sync" /usr/local/bin/xui-sync
chmod +x /usr/local/bin/xui-sync

# Install systemd path and service
cp "$SCRIPT_DIR/systemd/xui-nginx-sync.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/xui-nginx-sync.path" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now xui-nginx-sync.path

# 8. Run Initial Sync & Restart Nginx
echo -e "${BLUE}[*] Running initial synchronization...${NC}"
/usr/local/bin/xui-sync

systemctl enable nginx
systemctl restart nginx

echo ""
echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}     3XUI-SERVER-STARTER-PACK INSTALLATION COMPLETED!     ${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo " - Inbounds Gateway   : https://${DOMAIN}:${INBOUNDS_PORT}/"
echo " - 3X-UI Web Panel    : https://${DOMAIN}:${PANEL_PUBLIC_PORT}/ (Direct proxy, no leak)"
echo " - Subscription URL   : https://${DOMAIN}:${SUB_PUBLIC_PORT}${SUB_PATH}"
echo " - Telegram Bot WebUI : https://${DOMAIN}:${BOT_PUBLIC_PORT}/"
echo " - Stealth Root (/)   : https://${DOMAIN}/ (Closes connection instantly with return 444)"
echo ""
echo "CLI Management Tool   : xui-sync (Run 'xui-sync help' for options)"
echo "=========================================================="
echo ""

read -rp "Would you like to support this project and star it on GitHub? (y/N): " STAR_CHOICE
if [[ "$STAR_CHOICE" =~ ^[Yy]$ ]]; then
    GITHUB_URL="https://github.com/AliFanni-79/3XUI-Server-Starter-Pack"
    echo ""
    echo -e "${YELLOW}⭐ Thank you so much for your support!${NC}"
    echo -e "👉 Opening ${CYAN}${GITHUB_URL}${NC} ..."
    python3 -m webbrowser "$GITHUB_URL" >/dev/null 2>&1 || xdg-open "$GITHUB_URL" >/dev/null 2>&1 || sensible-browser "$GITHUB_URL" >/dev/null 2>&1 || true
    echo -e "If the browser did not open automatically, visit:"
    echo -e "   \e]8;;${GITHUB_URL}\e\\${CYAN}${GITHUB_URL}\e]8;;\e\\"
    echo ""
fi
