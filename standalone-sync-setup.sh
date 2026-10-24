#!/usr/bin/env bash
set -e

# ==============================================================================
# 3XUI-Server-Starter-Pack: Standalone Sync Setup
# For servers that ALREADY have 3X-UI and/or Shop-Bot installed
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: Must be run as root.${NC}"
   exit 1
fi

# Reconnect stdin to controlling terminal if available (for interactive prompts)
if [[ -e /dev/tty ]]; then
    exec < /dev/tty 2>/dev/null || true
fi

prompt_read() {
    local prompt_msg="$1"
    local var_name="$2"
    local default_val="$3"
    local input_val=""

    printf "%b" "$prompt_msg"
    if [[ -e /dev/tty ]]; then
        read -r input_val </dev/tty || true
    else
        read -r input_val || true
    fi

    if [[ -z "$input_val" && -n "$default_val" ]]; then
        input_val="$default_val"
    fi
    eval "$var_name=\"\$input_val\""
}

REPO_URL="${XUI_GATEWAY_REPO:-https://github.com/AliFanni-79/3XUI-Server-Starter-Pack.git}"
TARGET_DIR="/root/3XUI-Server-Starter-Pack"

# Self-bootstrap if executed directly via curl / pipe
if [[ ! -d "$SCRIPT_DIR/core" ]]; then
    echo "[*] Bootstrapping 3XUI-Server-Starter-Pack repository..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y git curl >/dev/null 2>&1 || true
    rm -rf "$TARGET_DIR"
    if ! git clone -q "$REPO_URL" "$TARGET_DIR"; then
        echo "[-] Failed to clone repository from ${REPO_URL}"
        echo "[!] If using a custom fork or branch, run: export XUI_GATEWAY_REPO=https://github.com/your/repo.git"
        exit 1
    fi
    exec < /dev/tty 2>/dev/null || true
    exec bash "$TARGET_DIR/standalone-sync-setup.sh" "$@"
fi

echo "=========================================================="
echo "  3XUI-Server-Starter-Pack: Standalone Sync Installation  "
echo " (For servers with existing 3X-UI and/or Shop-Bot)       "
echo "=========================================================="

apt-get update -y
apt-get install -y nginx python3 sqlite3 certbot python3-certbot-nginx curl

prompt_read "Enter your Domain Name (e.g. vpn.example.com): " DOMAIN
while [[ -z "$DOMAIN" ]]; do
    echo -e "${RED}Domain name cannot be empty.${NC}"
    prompt_read "Enter your Domain Name: " DOMAIN
done

prompt_read "Enter Inbounds Public Gateway Port [default: 443]: " INBOUNDS_PORT "443"
prompt_read "Enter 3X-UI Web Panel Public Port [default: 2083]: " PANEL_PUBLIC_PORT "2083"
prompt_read "Enter 3X-UI Subscription Public Port [default: 2096]: " SUB_PUBLIC_PORT "2096"
prompt_read "Enter Telegram Bot WebUI Public Port [default: 8443]: " BOT_PUBLIC_PORT "8443"
prompt_read "Enter Telegram Bot Local Port [default: 8080]: " BOT_INTERNAL_PORT "8080"
prompt_read "Enter 3X-UI Subscription URL Root Path [default: /sub/]: " SUB_PATH "/sub/"
[[ "$SUB_PATH" != /* ]] && SUB_PATH="/$SUB_PATH"
[[ "$SUB_PATH" != */ ]] && SUB_PATH="$SUB_PATH/"

# SSL Detection
DEFAULT_LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
DEFAULT_LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
CUSTOM_ROOT_CERT="/root/cert/${DOMAIN}/fullchain.pem"
CUSTOM_ROOT_KEY="/root/cert/${DOMAIN}/privkey.pem"

SSL_CERT=""
SSL_KEY=""
if [[ -f "$CUSTOM_ROOT_CERT" && -f "$CUSTOM_ROOT_KEY" ]]; then
    SSL_CERT="$CUSTOM_ROOT_CERT"
    SSL_KEY="$CUSTOM_ROOT_KEY"
elif [[ -f "$DEFAULT_LE_CERT" && -f "$DEFAULT_LE_KEY" ]]; then
    SSL_CERT="$DEFAULT_LE_CERT"
    SSL_KEY="$DEFAULT_LE_KEY"
else
    echo "No certificate automatically detected."
    prompt_read "Issue Let's Encrypt certificate now? (y/N): " ISSUE_SSL "N"
    if [[ "$ISSUE_SSL" =~ ^[Yy]$ ]]; then
        systemctl stop nginx 2>/dev/null || true
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
        SSL_CERT="$DEFAULT_LE_CERT"
        SSL_KEY="$DEFAULT_LE_KEY"
        systemctl start nginx 2>/dev/null || true
    else
        prompt_read "Enter path to fullchain.pem: " SSL_CERT
        prompt_read "Enter path to privkey.pem: " SSL_KEY
    fi
fi

# Resolve Nginx Conflicts & Pre-checks
if [[ -f "$SCRIPT_DIR/core/nginx_manager.sh" ]]; then
    bash "$SCRIPT_DIR/core/nginx_manager.sh" "$DOMAIN" "$INBOUNDS_PORT" "$PANEL_PUBLIC_PORT" "$SUB_PUBLIC_PORT" "$BOT_PUBLIC_PORT"
fi

# Configure SQLite WAL & 3X-UI settings
if [[ -f /etc/x-ui/x-ui.db ]]; then
    sqlite3 /etc/x-ui/x-ui.db "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true
    sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '${DOMAIN}' WHERE key = 'subDomain';"
    sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '${SUB_PUBLIC_PORT}' WHERE key = 'subPort';"
    
    # Shift internal ports if colliding
    CURR_WEB=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webPort';" 2>/dev/null || echo "2053")
    if [[ "$CURR_WEB" == "$PANEL_PUBLIC_PORT" ]]; then
        sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '20830' WHERE key = 'webPort';"
        systemctl restart x-ui 2>/dev/null || true
    fi
fi

# Deploy Config & Scripts
mkdir -p /etc/x-ui
python3 -c "
import json, os
path = '/etc/x-ui/nginx_proxy.json'
data = {}
if os.path.isfile(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        pass
data.update({
    'domain': '${DOMAIN}',
    'ssl_cert': '${SSL_CERT}',
    'ssl_key': '${SSL_KEY}',
    'inbounds_port': int('${INBOUNDS_PORT}'),
    'panel_public_port': int('${PANEL_PUBLIC_PORT}'),
    'panel_internal_port': 20830,
    'sub_public_port': int('${SUB_PUBLIC_PORT}'),
    'sub_internal_port': 20960,
    'bot_public_port': int('${BOT_PUBLIC_PORT}'),
    'bot_internal_port': int('${BOT_INTERNAL_PORT}'),
    'sub_path': '${SUB_PATH}',
    'db_path': '/etc/x-ui/x-ui.db',
    'nginx_conf_path': '/etc/nginx/conf.d/xui_proxy.conf'
})
data.setdefault('root_location_rule', 'return 444;')
data.setdefault('skip_panel_proxy', False)
data.setdefault('skip_sub_proxy', False)
data.setdefault('skip_inbound_ids', [])
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
"

cp "$SCRIPT_DIR/core/sync_engine.py" /usr/local/bin/xui-nginx-sync.py
chmod +x /usr/local/bin/xui-nginx-sync.py

cp "$SCRIPT_DIR/bin/xui-sync" /usr/local/bin/xui-sync
chmod +x /usr/local/bin/xui-sync

cp "$SCRIPT_DIR/systemd/xui-nginx-sync.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/xui-nginx-sync.path" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now xui-nginx-sync.path

# Initial sync
/usr/local/bin/xui-sync
systemctl enable --now nginx
systemctl reload nginx

echo ""
echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}    Standalone Nginx Gateway Synchronization Enabled!     ${NC}"
echo -e "${GREEN}  Run 'xui-sync status' to verify all active endpoints.   ${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo ""

prompt_read "Would you like to support this project and star it on GitHub? (y/N): " STAR_CHOICE "N"
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
