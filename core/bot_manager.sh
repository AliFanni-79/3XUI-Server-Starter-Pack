#!/usr/bin/env bash
set -e

# ==============================================================================
# Bot Manager: 3XUI-Shop-Bot Optional Installer & Sync Integration
# Repo: https://github.com/AliFanni-79/3XUI-Shop-Bot
# ==============================================================================

manage_shop_bot() {
    local DOMAIN="$1"
    local PANEL_INTERNAL_PORT="${2:-20830}"
    local BOT_DIR="/root/3XUI-Shop-Bot"

    echo ""
    echo "=========================================================="
    echo "           3XUI-Shop-Bot Installation (Optional)          "
    echo "=========================================================="
    echo "3XUI-Shop-Bot is an automated Telegram store for 3X-UI."
    echo "Repo: https://github.com/AliFanni-79/3XUI-Shop-Bot"
    echo ""
    read -rp "Do you want to install 3XUI-Shop-Bot on this server? (y/N): " INSTALL_BOT

    if [[ ! "$INSTALL_BOT" =~ ^[Yy]$ ]]; then
        echo "[*] Skipping 3XUI-Shop-Bot installation."
        return 0
    fi

    echo "[*] Installing 3XUI-Shop-Bot using official installer..."

    if [[ ! -d "$BOT_DIR" ]]; then
        git clone https://github.com/AliFanni-79/3XUI-Shop-Bot.git "$BOT_DIR"
    else
        echo "[+] Found existing 3XUI-Shop-Bot directory at $BOT_DIR."
    fi

    # Run the official installer
    if [[ -f "$BOT_DIR/install.sh" ]]; then
        chmod +x "$BOT_DIR/install.sh"
        echo "[*] Launching 3XUI-Shop-Bot install.sh..."
        (cd "$BOT_DIR" && bash install.sh)
    else
        echo "[!] install.sh not found in $BOT_DIR. Please check the repository."
    fi

    # Add Gateway Integration Hook / Helper
    # This allows the bot to trigger xui-sync whenever new inbounds or users are provisioned
    local HOOK_FILE="$BOT_DIR/nginx_sync_hook.py"
    cat << 'EOF' > "$HOOK_FILE"
# Nginx Gateway Sync Hook for 3XUI-Shop-Bot
import os
import shutil
import subprocess
import sys

def trigger_gateway_sync():
    """Trigger Nginx Gateway sync if available, or print recommendation."""
    xui_sync = shutil.which("xui-sync") or "/usr/local/bin/xui-sync"
    if shutil.which("xui-sync") or os.path.exists("/usr/local/bin/xui-sync"):
        try:
            subprocess.run([xui_sync], check=False)
            return True
        except Exception as e:
            print(f"[!] xui-sync execution failed: {e}")
            return False
    else:
        print("\n[Notice] xui-sync is not installed on this server.")
        print("To enable automatic Nginx port 443 path routing & TLS for your bot links,")
        print("install the Nginx Gateway: https://github.com/AliFanni-79/3XUI-Server-Starter-Pack\n")
        return False

if __name__ == "__main__":
    trigger_gateway_sync()
EOF
    chmod +x "$HOOK_FILE"
    echo "[+] Gateway sync hook created at $HOOK_FILE."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_shop_bot "$@"
fi
