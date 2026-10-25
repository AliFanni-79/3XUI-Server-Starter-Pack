#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 3XUI-Server-Starter-Pack: Standalone Sync Setup
# For servers that ALREADY have 3X-UI and/or Shop-Bot installed.
# Supports the same XUI_<VAR> presets as install.sh for unattended use.
# ==============================================================================

REPO_URL="${XUI_GATEWAY_REPO:-https://github.com/AliFanni-79/3XUI-Server-Starter-Pack.git}"
TARGET_DIR="/root/3XUI-Server-Starter-Pack"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

if [[ ! -f "$SCRIPT_DIR/core/lib.sh" ]]; then
    echo "[*] Bootstrapping 3XUI-Server-Starter-Pack repository..."
    if [[ $EUID -ne 0 ]]; then echo "Error: Must be run as root." >&2; exit 1; fi
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y git curl >/dev/null 2>&1 || true
    rm -rf "$TARGET_DIR"
    if ! git clone -q --depth 1 "$REPO_URL" "$TARGET_DIR"; then
        echo "[-] Failed to clone repository from ${REPO_URL}" >&2
        echo "[!] For a custom fork run: export XUI_GATEWAY_REPO=https://github.com/your/repo.git" >&2
        exit 1
    fi
    exec bash "$TARGET_DIR/standalone-sync-setup.sh" "$@"
fi

# shellcheck source=core/lib.sh
source "$SCRIPT_DIR/core/lib.sh"
# shellcheck source=core/deploy.sh
source "$SCRIPT_DIR/core/deploy.sh"

trap 'ui_err "Setup aborted on line $LINENO. See $XUI_LOG for details."' ERR

require_root
require_apt
ui_banner "Standalone Gateway Sync (existing 3X-UI / Shop-Bot)"

TOTAL=5

ui_step 1 $TOTAL "System dependencies"
install_dependencies

ui_step 2 $TOTAL "Configuration"
collect_gateway_config "Is 3XUI-Shop-Bot installed or planned on this server?"

ui_step 3 $TOTAL "SSL certificate"
configure_ssl

ui_step 4 $TOTAL "Nginx pre-flight & 3X-UI settings"
CHECK_BOT_PORT="$BOT_PUBLIC_PORT"
[[ "$HAS_BOT" == "true" ]] || CHECK_BOT_PORT="0"
bash "$SCRIPT_DIR/core/nginx_manager.sh" "$DOMAIN" "$INBOUNDS_PORT" "$PANEL_PUBLIC_PORT" "$SUB_PUBLIC_PORT" "$CHECK_BOT_PORT"

if [[ -f "$XUI_DB" ]]; then
    # xui_manager only configures the database here (it skips installing when x-ui exists).
    bash "$SCRIPT_DIR/core/xui_manager.sh" "$DOMAIN" "$SUB_PUBLIC_PORT" "$PANEL_PUBLIC_PORT" 20830 20960
else
    ui_warn "3X-UI database not found at $XUI_DB; install 3X-UI first or use install.sh."
fi

ui_step 5 $TOTAL "Gateway sync engine"
write_proxy_config
deploy_sync_engine "$SCRIPT_DIR"
finalize_gateway

ui_box "Standalone sync enabled" \
    "Gateway   : https://${DOMAIN}:${INBOUNDS_PORT}/" \
    "Panel     : https://${DOMAIN}:${PANEL_PUBLIC_PORT}/" \
    "Subs      : https://${DOMAIN}:${SUB_PUBLIC_PORT}${SUB_PATH}" \
    "" \
    "Verify with: xui-sync status   (or xui-sync doctor)"

offer_github_star
