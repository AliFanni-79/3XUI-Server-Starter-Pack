#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Bot Manager: 3XUI-Shop-Bot Optional Installer & Sync Integration
# Repo: https://github.com/AliFanni-79/3XUI-Shop-Bot
#
# Usage: bot_manager.sh DOMAIN [PANEL_INTERNAL_PORT] [install|integrate] [BOT_PUBLIC_PORT] [BOT_INTERNAL_PORT] [BOT_DIR]
# ==============================================================================

_BOT_DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$_BOT_DIR_SELF/lib.sh"

manage_shop_bot() {
    local DOMAIN="$1"
    local PANEL_INTERNAL_PORT="${2:-20830}"   # kept for CLI compatibility
    local ACTION="${3:-}"
    local BOT_PUBLIC_PORT="${4:-}"
    local BOT_INTERNAL_PORT="${5:-}"
    local BOT_DIR="${6:-/root/3XUI-Shop-Bot}"
    [[ -n "$BOT_DIR" ]] || BOT_DIR="/root/3XUI-Shop-Bot"
    : "$PANEL_INTERNAL_PORT"

    ui_section "3XUI-Shop-Bot"
    ui_dim "Automated Telegram store for 3X-UI"
    ui_dim "Repo: https://github.com/AliFanni-79/3XUI-Shop-Bot"

    local INSTALL_BOT=false
    if [[ "$ACTION" == "install" || "$ACTION" == "integrate" ]]; then
        INSTALL_BOT=true
    elif confirm INSTALL_BOT "Install 3XUI-Shop-Bot on this server?" N; then
        INSTALL_BOT=true
    fi

    if [[ "$INSTALL_BOT" != "true" ]]; then
        ui_info "Skipping 3XUI-Shop-Bot installation."
        return 0
    fi

    # Standalone invocation: ask for ports and persist them for the sync engine.
    if [[ -z "$BOT_PUBLIC_PORT" || -z "$BOT_INTERNAL_PORT" ]]; then
        ask BOT_PUBLIC_PORT   "Telegram bot WebUI public port" 8443 is_port "Port must be between 1 and 65535."
        ask BOT_INTERNAL_PORT "Telegram bot local port"        8080 is_port "Port must be between 1 and 65535."
        if [[ -f /etc/x-ui/nginx_proxy.json ]]; then
            XUI_BP="$BOT_PUBLIC_PORT" XUI_BI="$BOT_INTERNAL_PORT" python3 - <<'PY' || ui_warn "Could not update /etc/x-ui/nginx_proxy.json"
import json, os
p = "/etc/x-ui/nginx_proxy.json"
with open(p, "r", encoding="utf-8") as f:
    data = json.load(f)
data["bot_public_port"] = int(os.environ["XUI_BP"])
data["bot_internal_port"] = int(os.environ["XUI_BI"])
data["skip_bot_proxy"] = False
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
        fi
    fi

    if [[ "$ACTION" == "integrate" ]]; then
        ui_ok "Existing bot detected at $BOT_DIR; skipping installation."
        [[ -d "$BOT_DIR" ]] || { ui_warn "Bot directory not found; skipping the sync hook."; return 0; }
    else
    command -v git >/dev/null 2>&1 || die "git is required to install the bot."

    if [[ ! -d "$BOT_DIR" ]]; then
        ui_run "Cloning 3XUI-Shop-Bot" git clone --depth 1 https://github.com/AliFanni-79/3XUI-Shop-Bot.git "$BOT_DIR" \
            || die "Could not clone the bot repository."
    else
        ui_ok "Found existing 3XUI-Shop-Bot at $BOT_DIR"
    fi

    if [[ -f "$BOT_DIR/install.sh" ]]; then
        chmod +x "$BOT_DIR/install.sh"
        ui_info "Launching the bot's own installer (interactive)..."
        (cd "$BOT_DIR" && bash install.sh) || ui_warn "The bot installer exited with an error."
    else
        ui_warn "install.sh not found in $BOT_DIR; please check the repository."
    fi
    fi

    # Gateway integration hook: lets the bot trigger xui-sync after provisioning inbounds/users.
    local HOOK_FILE="$BOT_DIR/nginx_sync_hook.py"
    cat > "$HOOK_FILE" <<'EOF'
# Nginx Gateway Sync Hook for 3XUI-Shop-Bot
import os
import shutil
import subprocess
import sys

def trigger_gateway_sync():
    """Trigger Nginx Gateway sync if available, or print recommendation."""
    xui_sync = shutil.which("xui-sync") or "/usr/local/bin/xui-sync"
    if os.path.exists(xui_sync):
        try:
            subprocess.run([xui_sync, "sync", "--force"], check=False)
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
    sys.exit(0 if trigger_gateway_sync() else 1)
EOF
    chmod +x "$HOOK_FILE"
    ui_ok "Gateway sync hook created at $HOOK_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_shop_bot "$@"
fi
