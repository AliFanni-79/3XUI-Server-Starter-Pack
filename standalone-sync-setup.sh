#!/usr/bin/env bash
set -e

# ==============================================================================
# XUI-Nginx-Gateway: Standalone Sync Setup
# For servers that ALREADY have 3X-UI and/or Shop-Bot installed
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
   echo "Error: Must be run as root."
   exit 1
fi

echo "=========================================================="
echo "    XUI-Nginx-Gateway: Standalone Sync Installation       "
echo " (For servers with existing 3X-UI and/or Shop-Bot)       "
echo "=========================================================="

apt-get update -y
apt-get install -y nginx python3 sqlite3 certbot python3-certbot-nginx curl

read -rp "Enter your Domain Name (e.g. vpn.example.com): " DOMAIN
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
    read -rp "Issue Let's Encrypt certificate now? (y/N): " ISSUE_SSL
    if [[ "$ISSUE_SSL" =~ ^[Yy]$ ]]; then
        systemctl stop nginx 2>/dev/null || true
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
        SSL_CERT="$DEFAULT_LE_CERT"
        SSL_KEY="$DEFAULT_LE_KEY"
        systemctl start nginx 2>/dev/null || true
    else
        read -rp "Enter path to fullchain.pem: " SSL_CERT
        read -rp "Enter path to privkey.pem: " SSL_KEY
    fi
fi

# Resolve Nginx Conflicts
if [[ -f "$SCRIPT_DIR/core/nginx_manager.sh" ]]; then
    bash "$SCRIPT_DIR/core/nginx_manager.sh" "$INBOUNDS_PORT" "$PANEL_PUBLIC_PORT" "$SUB_PUBLIC_PORT"
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
echo "=========================================================="
echo "    Standalone Nginx Gateway Synchronization Enabled!     "
echo "  Run 'xui-sync status' to verify all active endpoints.   "
echo "=========================================================="
