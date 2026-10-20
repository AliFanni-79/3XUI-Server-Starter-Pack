#!/usr/bin/env bash
set -e

# ==============================================================================
# 3X-UI Manager: Installation & Database Settings Configurator
# Ensures: Sanaei 3X-UI installation, WAL mode, Sub link reverse proxy, Port shifting
# ==============================================================================

install_and_configure_xui() {
    local DOMAIN="$1"
    local SUB_PUBLIC_PORT="${2:-2096}"
    local PANEL_PUBLIC_PORT="${3:-2083}"
    local PANEL_INTERNAL_PORT="${4:-20830}"
    local SUB_INTERNAL_PORT="${5:-20960}"

    echo ""
    echo "=========================================================="
    echo "           3X-UI Panel Installation & Verification        "
    echo "=========================================================="

    if [[ ! -d /usr/local/x-ui || ! -f /etc/x-ui/x-ui.db ]]; then
        echo "[*] 3X-UI panel not found. Installing latest MHSanaei 3X-UI..."
        bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
        sleep 2
    else
        echo "[+] Found existing 3X-UI panel installation."
    fi

    echo "[*] Configuring database settings for Nginx reverse proxy..."

    if [[ -f /etc/x-ui/x-ui.db ]]; then
        # 1. Enable SQLite WAL mode (prevents concurrent write-lock freezes)
        sqlite3 /etc/x-ui/x-ui.db "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true

        # 2. Configure Sub Link Reverse Proxy parameters
        # When clients fetch subscriptions, 3X-UI uses subDomain + subPort
        sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '${DOMAIN}' WHERE key = 'subDomain';"
        sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '${SUB_PUBLIC_PORT}' WHERE key = 'subPort';"

        # 3. Shift internal panel port if it conflicts with Nginx public panel port
        local CURRENT_WEB_PORT
        CURRENT_WEB_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webPort';" 2>/dev/null || echo "2053")
        if [[ "$CURRENT_WEB_PORT" == "$PANEL_PUBLIC_PORT" ]]; then
            echo "[*] Shifting internal 3X-UI webPort from $CURRENT_WEB_PORT to $PANEL_INTERNAL_PORT..."
            sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '${PANEL_INTERNAL_PORT}' WHERE key = 'webPort';"
        fi

        # 4. Shift internal sub port if it conflicts with Nginx public sub port
        local CURRENT_SUB_PORT
        CURRENT_SUB_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'subPort';" 2>/dev/null || echo "2096")
        if [[ "$CURRENT_SUB_PORT" == "$SUB_PUBLIC_PORT" ]]; then
            echo "[*] Shifting internal 3X-UI subPort from $CURRENT_SUB_PORT to $SUB_INTERNAL_PORT..."
            sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '${SUB_INTERNAL_PORT}' WHERE key = 'subPort';"
        fi

        # 5. Bind internal listen interfaces to 127.0.0.1
        sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '127.0.0.1' WHERE key = 'webListen';" 2>/dev/null || true
        sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '127.0.0.1' WHERE key = 'subListen';" 2>/dev/null || true

        # Reset systemd failure counter and restart x-ui to apply DB adjustments
        systemctl reset-failed x-ui 2>/dev/null || true
        systemctl restart x-ui 2>/dev/null || true
        echo "[+] 3X-UI database configured and service active."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_and_configure_xui "$@"
fi
