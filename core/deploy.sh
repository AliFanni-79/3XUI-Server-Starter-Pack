#!/usr/bin/env bash
# ==============================================================================
# deploy.sh - Install/configure steps shared by install.sh and
#             standalone-sync-setup.sh. Requires core/lib.sh to be sourced.
# ==============================================================================

[[ -n "${_XUI_DEPLOY_LOADED:-}" ]] && return 0
_XUI_DEPLOY_LOADED=1

XUI_DB="/etc/x-ui/x-ui.db"
XUI_CONF="/etc/x-ui/nginx_proxy.json"
XUI_LIB_DIR="/usr/local/lib/xui-starter-pack"
XUI_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Remember which local ports an already-installed 3X-UI panel/sub used BEFORE we
# shift them, so old nginx routes pointing at them can be recognised afterwards.
OLD_PANEL_PORTS=""; OLD_SUB_PORTS=""
capture_old_xui_ports() {
    [[ -f "$XUI_DB" ]] || return 0
    local w s
    w="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || true)"
    s="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort';" 2>/dev/null || true)"
    [[ "$w" =~ ^[0-9]+$ ]] && OLD_PANEL_PORTS="$w"
    [[ "$s" =~ ^[0-9]+$ ]] && OLD_SUB_PORTS="$s"
    OLD_PANEL_PORTS="${OLD_PANEL_PORTS:+$OLD_PANEL_PORTS,}20830"
    OLD_SUB_PORTS="${OLD_SUB_PORTS:+$OLD_SUB_PORTS,}20960"
}

require_root() {
    [[ $EUID -eq 0 ]] || { ui_err "This script must be run as root (try: sudo bash $0)."; exit 1; }
}

require_apt() {
    command -v apt-get >/dev/null 2>&1 || die "Only Debian/Ubuntu (apt) systems are supported."
}

# Install the packages the gateway needs. Sets NGINX_FRESH=true when nginx was
# not installed before this run (so the stock "default" site can be removed).
install_dependencies() {
    NGINX_FRESH=false
    command -v nginx >/dev/null 2>&1 || NGINX_FRESH=true
    export DEBIAN_FRONTEND=noninteractive
    ui_run "Refreshing package index" apt-get update -y || ui_warn "apt-get update failed; continuing with cached index."
    ui_run "Installing nginx, python3, sqlite3, certbot, curl, git" \
        apt-get install -y nginx python3 sqlite3 certbot python3-certbot-nginx curl git rsync \
        || die "Dependency installation failed."
    # A freshly installed nginx ships a stock site that is not user configuration;
    # remove it so it is not reported as a conflict.
    if [[ "$NGINX_FRESH" == "true" ]]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
}

# Prompt for all gateway settings. Sets: DOMAIN INBOUNDS_PORT PANEL_PUBLIC_PORT
# SUB_PUBLIC_PORT SUB_PATH HAS_BOT BOT_PUBLIC_PORT BOT_INTERNAL_PORT
collect_gateway_config() {
    local bot_question="${1:-Install 3XUI-Shop-Bot on this server?}"

    ui_section "Gateway network configuration"
    ask DOMAIN "Domain name (e.g. vpn.example.com)" "" is_domain "Enter a valid fully-qualified domain name."
    DOMAIN="${DOMAIN,,}"
    ask INBOUNDS_PORT    "Inbounds public gateway port" 443  is_port "Port must be a number between 1 and 65535."
    ask PANEL_PUBLIC_PORT "3X-UI web panel public port"  2083 is_port "Port must be a number between 1 and 65535."
    ask SUB_PUBLIC_PORT  "3X-UI subscription public port" 2096 is_port "Port must be a number between 1 and 65535."
    ask SUB_PATH "Subscription URL root path" "/sub/"
    [[ "$SUB_PATH" == /* ]] || SUB_PATH="/$SUB_PATH"
    [[ "$SUB_PATH" == */ ]] || SUB_PATH="$SUB_PATH/"

    echo
    HAS_BOT=false
    BOT_PUBLIC_PORT=8443
    BOT_INTERNAL_PORT=8080
    BOT_EXISTING=false      # xui-bot.service already installed on this server
    BOT_PROXY_MODE=keep     # keep | skip (leave routing alone) | enable (gateway must proxy it)
    BOT_ACTION=""           # cf-switch: remove the Cloudflare tunnel route after success
    BOT_CHECK_PORT=0        # port handed to the nginx conflict inspector (0 = no check)
    BOT_DIR_DETECTED=""

    if detect_existing_bot; then
        handle_existing_bot
    elif confirm HAS_BOT "$bot_question" N; then
        ask BOT_PUBLIC_PORT   "Telegram bot WebUI public port" 8443 is_port "Port must be a number between 1 and 65535."
        ask BOT_INTERNAL_PORT "Telegram bot local port"        8080 is_port "Port must be a number between 1 and 65535."
        BOT_CHECK_PORT="$BOT_PUBLIC_PORT"
    fi

    # Public ports must be unique - nginx cannot bind two server blocks to one port with different roles.
    local -A seen=()
    local entry name port
    for entry in "Inbounds:$INBOUNDS_PORT" "Panel:$PANEL_PUBLIC_PORT" "Subscription:$SUB_PUBLIC_PORT"; do
        name="${entry%%:*}"; port="${entry##*:}"
        [[ -n "${seen[$port]:-}" ]] && die "Port $port is used for both ${seen[$port]} and $name. Choose distinct public ports."
        seen[$port]="$name"
    done
    if [[ "$HAS_BOT" == "true" && "$BOT_PROXY_MODE" != "skip" && -n "${seen[$BOT_PUBLIC_PORT]:-}" ]]; then
        die "Bot port $BOT_PUBLIC_PORT collides with the ${seen[$BOT_PUBLIC_PORT]} port."
    fi
}

# --- Existing Shop-Bot detection ----------------------------------------------
# Sets B_* variables from `legacy_cleanup.py detect-bot`. Returns 0 if installed.
detect_existing_bot() {
    B_installed=false; B_state=""; B_dir=""; B_port=""; B_exposure="local"
    B_nginx_file=""; B_nginx_listen=""; B_nginx_names=""; B_nginx_dedicated=false
    B_cf_config=""; B_cf_unit=""; B_hints=()
    command -v systemctl >/dev/null 2>&1 || return 1
    local result k v
    result="$(python3 "$XUI_CORE_DIR/legacy_cleanup.py" detect-bot 2>/dev/null)" || return 1
    while IFS='=' read -r k v; do
        case "$k" in
            installed) B_installed="$v" ;;     state) B_state="$v" ;;
            dir) B_dir="$v" ;;                 port) B_port="$v" ;;
            exposure) B_exposure="$v" ;;       nginx_file) B_nginx_file="$v" ;;
            nginx_listen) B_nginx_listen="$v" ;; nginx_names) B_nginx_names="$v" ;;
            nginx_dedicated) B_nginx_dedicated="$v" ;;
            cf_config) B_cf_config="$v" ;;     cf_unit) B_cf_unit="$v" ;;
            hint) B_hints+=("$v") ;;
        esac
    done <<<"$result"
    [[ "$B_installed" == "true" ]]
}

# Decide how the already-installed bot is handled; never installs anything.
handle_existing_bot() {
    HAS_BOT=true
    BOT_EXISTING=true
    BOT_DIR_DETECTED="$B_dir"
    ui_ok "3XUI-Shop-Bot is already installed (${B_state}) - no installation needed"
    [[ -n "$B_dir" ]] && ui_dim "Directory: $B_dir"
    local h
    for h in "${B_hints[@]}"; do ui_dim "config  $h"; done

    if [[ -n "$B_port" ]]; then
        BOT_INTERNAL_PORT="$B_port"
        ui_dim "Bot listens on local port $B_port"
    else
        ui_warn "Could not determine the bot's listening port."
        ask BOT_INTERNAL_PORT "Telegram bot local port" 8080 is_port "Port must be a number between 1 and 65535."
    fi

    local reserved=" $INBOUNDS_PORT $PANEL_PUBLIC_PORT $SUB_PUBLIC_PORT "
    local CF_SWITCH EXPOSE

    case "$B_exposure" in
        nginx)
            ui_info "Exposed through Nginx: ${B_nginx_file} (public port ${B_nginx_listen:-?})"
            local domain_ok=false
            if [[ -z "$B_nginx_names" || ",$B_nginx_names," == *",_,"* || ",$B_nginx_names," == *",${DOMAIN},"* ]]; then
                domain_ok=true
            fi
            if [[ "$B_nginx_dedicated" == "true" && "$domain_ok" == "true" ]]; then
                if [[ -n "$B_nginx_listen" && "$reserved" != *" $B_nginx_listen "* ]]; then
                    BOT_PUBLIC_PORT="$B_nginx_listen"
                else
                    ui_warn "Its public port collides with another gateway port; choose a new one."
                    ask BOT_PUBLIC_PORT "Telegram bot WebUI public port" 8443 is_port "Port must be a number between 1 and 65535."
                fi
                BOT_PROXY_MODE=enable
                ui_ok "The route will be migrated into the new gateway on port ${BOT_PUBLIC_PORT}; the old file is retired afterwards."
            else
                BOT_PROXY_MODE=skip
                ui_warn "That nginx file is shared with other sites or another domain; leaving the bot routing untouched."
            fi
            ;;
        cloudflared|cloudflared-remote)
            ui_info "Exposed through a Cloudflare tunnel${B_cf_unit:+ ($B_cf_unit)}"
            if confirm CF_SWITCH "Allow this script to switch the bot from the Cloudflare tunnel to the Nginx gateway?" N; then
                ask BOT_PUBLIC_PORT "Telegram bot WebUI public port" 8443 is_port "Port must be a number between 1 and 65535."
                BOT_PROXY_MODE=enable
                BOT_ACTION=cf-switch
            else
                BOT_PROXY_MODE=skip
                ui_info "Keeping the Cloudflare tunnel; the gateway will not proxy the bot."
            fi
            ;;
        *)
            if [[ "$B_exposure" == "direct" ]]; then
                ui_info "The bot is listening directly on a public interface (no reverse proxy)."
            else
                ui_info "The bot is only reachable locally (no public route found)."
            fi
            if confirm EXPOSE "Allow this script to expose the bot through the Nginx gateway?" Y; then
                ask BOT_PUBLIC_PORT "Telegram bot WebUI public port" 8443 is_port "Port must be a number between 1 and 65535."
                while [[ "$B_exposure" == "direct" && "$BOT_PUBLIC_PORT" == "$BOT_INTERNAL_PORT" ]]; do
                    ui_warn "Nginx cannot bind port $BOT_PUBLIC_PORT while the bot itself listens on it."
                    XUI_BOT_PUBLIC_PORT="" ask BOT_PUBLIC_PORT "Telegram bot WebUI public port" 8444 is_port "Port must be a number between 1 and 65535."
                done
                BOT_PROXY_MODE=enable
            else
                BOT_PROXY_MODE=skip
            fi
            ;;
    esac
    # Bot routes are handled here; keep the generic conflict inspector away from its ports.
    BOT_CHECK_PORT=0
}

# Detect or obtain an SSL certificate. Sets SSL_CERT and SSL_KEY.
configure_ssl() {
    ui_section "SSL certificate"
    local le_cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    local le_key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    local custom_cert="/root/cert/${DOMAIN}/fullchain.pem"
    local custom_key="/root/cert/${DOMAIN}/privkey.pem"
    SSL_CERT=""; SSL_KEY=""

    if [[ -f "$custom_cert" && -f "$custom_key" ]]; then
        SSL_CERT="$custom_cert"; SSL_KEY="$custom_key"
        ui_ok "Detected certificate in /root/cert/${DOMAIN}"
    elif [[ -f "$le_cert" && -f "$le_key" ]]; then
        SSL_CERT="$le_cert"; SSL_KEY="$le_key"
        ui_ok "Detected Let's Encrypt certificate for ${DOMAIN}"
    else
        ui_info "No existing certificate found for ${DOMAIN}."
        local ISSUE
        if confirm ISSUE "Issue a free Let's Encrypt certificate now?" N; then
            local was_active=false
            systemctl is-active --quiet nginx 2>/dev/null && was_active=true
            [[ "$was_active" == "true" ]] && systemctl stop nginx 2>/dev/null || true
            local rc=0
            ui_run "Requesting certificate for ${DOMAIN} (port 80 must be reachable)" \
                certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email || rc=$?
            # Never leave nginx stopped because certbot failed.
            [[ "$was_active" == "true" ]] && systemctl start nginx 2>/dev/null || true
            if [[ $rc -eq 0 && -f "$le_cert" ]]; then
                SSL_CERT="$le_cert"; SSL_KEY="$le_key"
            else
                ui_warn "Certificate issuance failed. Check DNS for ${DOMAIN} and that port 80 is open."
            fi
        fi
        if [[ -z "$SSL_CERT" ]]; then
            ask SSL_CERT "Full path to fullchain.pem" "" is_file "File not found or not readable."
            ask SSL_KEY  "Full path to privkey.pem"   "" is_file "File not found or not readable."
        fi
    fi
}

# Merge gateway settings into /etc/x-ui/nginx_proxy.json. Values travel through
# the environment so nothing user-supplied is ever interpolated into code.
write_proxy_config() {
    mkdir -p /etc/x-ui
    XUI_CFG_PATH="$XUI_CONF" \
    XUI_CFG_DOMAIN="$DOMAIN" XUI_CFG_CERT="$SSL_CERT" XUI_CFG_KEY="$SSL_KEY" \
    XUI_CFG_INBOUNDS="$INBOUNDS_PORT" XUI_CFG_PANEL="$PANEL_PUBLIC_PORT" XUI_CFG_SUB="$SUB_PUBLIC_PORT" \
    XUI_CFG_BOT_PUB="$BOT_PUBLIC_PORT" XUI_CFG_BOT_INT="$BOT_INTERNAL_PORT" \
    XUI_CFG_HAS_BOT="$HAS_BOT" XUI_CFG_SUB_PATH="$SUB_PATH" XUI_CFG_BOT_MODE="${BOT_PROXY_MODE:-keep}" \
    python3 - <<'PY'
import json, os
e = os.environ
path = e["XUI_CFG_PATH"]
data = {}
if os.path.isfile(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
has_bot = e["XUI_CFG_HAS_BOT"] == "true"
data.update({
    "domain": e["XUI_CFG_DOMAIN"],
    "ssl_cert": e["XUI_CFG_CERT"],
    "ssl_key": e["XUI_CFG_KEY"],
    "inbounds_port": int(e["XUI_CFG_INBOUNDS"]),
    "panel_public_port": int(e["XUI_CFG_PANEL"]),
    "panel_internal_port": 20830,
    "sub_public_port": int(e["XUI_CFG_SUB"]),
    "sub_internal_port": 20960,
    "bot_public_port": int(e["XUI_CFG_BOT_PUB"]),
    "bot_internal_port": int(e["XUI_CFG_BOT_INT"]),
    "sub_path": e["XUI_CFG_SUB_PATH"],
    "db_path": "/etc/x-ui/x-ui.db",
    "nginx_conf_path": "/etc/nginx/conf.d/xui_proxy.conf",
})
# Respect a "keep existing bot rule" decision made by the conflict inspector,
# unless the installer explicitly decided (skip / enable) for an existing bot.
bot_mode = e.get("XUI_CFG_BOT_MODE", "keep")
if not has_bot or bot_mode == "skip":
    data["skip_bot_proxy"] = True
elif bot_mode == "enable":
    data["skip_bot_proxy"] = False
else:
    data["skip_bot_proxy"] = bool(data.get("skip_bot_proxy", False))
data.setdefault("root_location_rule", "return 444;")
data.setdefault("skip_panel_proxy", False)
data.setdefault("skip_sub_proxy", False)
data.setdefault("skip_inbound_ids", [])
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
os.chmod(path, 0o600)
PY
}

# Install sync engine, CLI, shared UI library and systemd units.
deploy_sync_engine() {
    local root="$1"
    install -m 0755 "$root/core/sync_engine.py" /usr/local/bin/xui-nginx-sync.py
    install -m 0755 "$root/bin/xui-sync" /usr/local/bin/xui-sync
    install -d -m 0755 "$XUI_LIB_DIR"
    install -m 0644 "$root/core/lib.sh" "$XUI_LIB_DIR/lib.sh"
    install -m 0644 "$root/systemd/xui-nginx-sync.service" /etc/systemd/system/
    install -m 0644 "$root/systemd/xui-nginx-sync.path" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now xui-nginx-sync.path >/dev/null 2>&1 || ui_warn "Could not enable xui-nginx-sync.path watcher."
}

# Run the first sync, validate the nginx config and (re)start nginx.
finalize_gateway() {
    ui_run "Synchronizing 3X-UI database with Nginx" python3 /usr/local/bin/xui-nginx-sync.py --force \
        || die "Initial synchronization failed."
    if ! nginx -t >>"$XUI_LOG" 2>&1; then
        nginx -t 2>&1 | sed 's/^/      /' >&2 || true
        die "Generated nginx configuration is invalid. Existing configs were backed up under /etc/nginx/backup_*."
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
    ui_run "Restarting nginx" systemctl restart nginx || die "nginx failed to start: see 'journalctl -u nginx'."
}

# After a successful install: retire old nginx files that only proxied the
# 3X-UI panel / subscription / bot (backed up, rolled back on failure) and,
# if allowed earlier, move the bot off its Cloudflare tunnel.
post_install_cleanup() {
    ui_section "Cleaning up legacy configuration"
    local -a args=(cleanup --config "$XUI_CONF" --domain "$DOMAIN"
        --panel-ports "$OLD_PANEL_PORTS" --sub-ports "$OLD_SUB_PORTS")
    if [[ "$HAS_BOT" == "true" && "$BOT_PROXY_MODE" != "skip" ]]; then
        args+=(--bot-ports "$BOT_INTERNAL_PORT")
    fi
    python3 "$XUI_CORE_DIR/legacy_cleanup.py" "${args[@]}" || ui_warn "Legacy cleanup reported a problem; previous files were restored."

    if [[ "$BOT_ACTION" == "cf-switch" ]]; then
        # Only drop the tunnel route once the gateway demonstrably serves the bot.
        local code
        code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
            --resolve "${DOMAIN}:${BOT_PUBLIC_PORT}:127.0.0.1" "https://${DOMAIN}:${BOT_PUBLIC_PORT}/" 2>/dev/null || true)"
        if [[ -n "$code" && "$code" != "000" ]]; then
            ui_ok "Gateway answers for the bot on port ${BOT_PUBLIC_PORT} (HTTP ${code})"
            python3 "$XUI_CORE_DIR/legacy_cleanup.py" cf-switch --config "$B_cf_config" --unit "$B_cf_unit" --port "$BOT_INTERNAL_PORT" \
                || ui_warn "Could not update the Cloudflare tunnel configuration."
        else
            ui_warn "The gateway did not answer for the bot; the Cloudflare tunnel was left untouched."
        fi
    fi
}

offer_github_star() {
    local star url="https://github.com/AliFanni-79/3XUI-Server-Starter-Pack"
    echo
    if confirm star "Would you like to star this project on GitHub?" N; then
        ui_ok "Thank you for your support!"
        python3 -m webbrowser "$url" >/dev/null 2>&1 || xdg-open "$url" >/dev/null 2>&1 || true
        printf '    %s\033]8;;%s\033\\%s%s\033]8;;\033\\\n' "$C_CYAN" "$url" "$url" "$C_RESET"
    fi
}
