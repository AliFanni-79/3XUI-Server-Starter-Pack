#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 3XUI-Server-Starter-Pack: Master Orchestrator & Installer
# Integrates: MHSanaei 3X-UI + Nginx Path Gateway + ECH/REALITY + 3XUI-Shop-Bot
#
# Unattended use: pre-set answers via environment, e.g.
#   XUI_DOMAIN=vpn.example.com XUI_HAS_BOT=n bash install.sh
# ==============================================================================

REPO_URL="${XUI_GATEWAY_REPO:-https://github.com/AliFanni-79/3XUI-Server-Starter-Pack.git}"
TARGET_DIR="/root/3XUI-Server-Starter-Pack"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

# --- Self-bootstrap when executed via `curl | bash` / `bash <(curl ...)` -------
if [[ ! -f "$SCRIPT_DIR/core/lib.sh" ]]; then
    echo "[*] Bootstrapping 3XUI-Server-Starter-Pack repository..."
    if [[ $EUID -ne 0 ]]; then echo "Error: This installer must be run as root." >&2; exit 1; fi
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y git curl >/dev/null 2>&1 || true
    rm -rf "$TARGET_DIR"
    if ! git clone -q --depth 1 "$REPO_URL" "$TARGET_DIR"; then
        echo "[-] Failed to clone repository from ${REPO_URL}" >&2
        echo "[!] For a custom fork run: export XUI_GATEWAY_REPO=https://github.com/your/repo.git" >&2
        exit 1
    fi
    exec bash "$TARGET_DIR/install.sh" "$@"
fi

# shellcheck source=core/lib.sh
source "$SCRIPT_DIR/core/lib.sh"
# shellcheck source=core/deploy.sh
source "$SCRIPT_DIR/core/deploy.sh"

trap 'ui_err "Installer aborted on line $LINENO. See $XUI_LOG for details."' ERR

require_root
require_apt
capture_old_xui_ports
ui_banner "3X-UI + Nginx Gateway + Shop-Bot Setup"

TOTAL=7

# 1. Dependencies
ui_step 1 $TOTAL "System dependencies"
install_dependencies

# 2. Configuration
ui_step 2 $TOTAL "Configuration"
collect_gateway_config "Install 3XUI-Shop-Bot on this server?"

# 3. SSL
ui_step 3 $TOTAL "SSL certificate"
configure_ssl

# 4. Nginx conflict resolution
ui_step 4 $TOTAL "Nginx pre-flight checks"
bash "$SCRIPT_DIR/core/nginx_manager.sh" "$DOMAIN" "$INBOUNDS_PORT" "$PANEL_PUBLIC_PORT" "$SUB_PUBLIC_PORT" "$BOT_CHECK_PORT"

# 5. 3X-UI
ui_step 5 $TOTAL "3X-UI panel"
bash "$SCRIPT_DIR/core/xui_manager.sh" "$DOMAIN" "$SUB_PUBLIC_PORT" "$PANEL_PUBLIC_PORT" 20830 20960

# 6. Shop-Bot (optional)
ui_step 6 $TOTAL "Shop-Bot"
if [[ "$BOT_EXISTING" == "true" ]]; then
    ui_ok "3XUI-Shop-Bot is already installed - skipping installation."
    bash "$SCRIPT_DIR/core/bot_manager.sh" "$DOMAIN" 20830 "integrate" "$BOT_PUBLIC_PORT" "$BOT_INTERNAL_PORT" "$BOT_DIR_DETECTED" \
        || ui_warn "Could not add the gateway sync hook to the existing bot."
elif [[ "$HAS_BOT" == "true" ]]; then
    bash "$SCRIPT_DIR/core/bot_manager.sh" "$DOMAIN" 20830 "install" "$BOT_PUBLIC_PORT" "$BOT_INTERNAL_PORT" \
        || ui_warn "Shop-Bot installation reported a problem; the gateway will still be configured."
else
    ui_info "Skipping 3XUI-Shop-Bot installation."
fi

# 7. Sync engine + start
ui_step 7 $TOTAL "Gateway sync engine"
write_proxy_config
deploy_sync_engine "$SCRIPT_DIR"
finalize_gateway
post_install_cleanup

SUMMARY=(
    "Inbounds gateway : https://${DOMAIN}:${INBOUNDS_PORT}/"
    "3X-UI web panel  : https://${DOMAIN}:${PANEL_PUBLIC_PORT}/"
    "Subscription URL : https://${DOMAIN}:${SUB_PUBLIC_PORT}${SUB_PATH}"
)
[[ "$HAS_BOT" == "true" && "$BOT_PROXY_MODE" != "skip" ]] && SUMMARY+=("Telegram bot UI  : https://${DOMAIN}:${BOT_PUBLIC_PORT}/")
SUMMARY+=(
    "Stealth root (/) : closes connection (return 444)"
    ""
    "Manage with      : xui-sync status | doctor | hosts | log"
)
ui_box "Installation complete" "${SUMMARY[@]}"

offer_github_star
