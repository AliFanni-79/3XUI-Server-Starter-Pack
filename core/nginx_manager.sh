#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Nginx Manager: Conflict Resolver & Inspector
# Handles: pre-configuration check, update/completion mode and granular conflict
# resolution. Delegates to nginx_inspector.py when python3 is available and
# falls back to a simpler interactive flow otherwise.
# ==============================================================================

_NGX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$_NGX_DIR/lib.sh"

BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NGINX_BACKUP_DIR="/etc/nginx/backup_${BACKUP_TIMESTAMP}"

# Collect existing site configs (excluding our own generated file).
_list_existing_configs() {
    find /etc/nginx/conf.d /etc/nginx/sites-enabled \( -type f -o -type l \) \
        \( -name '*.conf' -o -name 'default' \) ! -name 'xui_proxy.conf' -print0 2>/dev/null || true
}

_remove_dangling_symlinks() {
    find /etc/nginx/sites-enabled /etc/nginx/conf.d -xtype l -delete 2>/dev/null || true
}

_backup_all() { # _backup_all file...
    mkdir -p "$NGINX_BACKUP_DIR"
    local cfg
    for cfg in "$@"; do
        mv "$cfg" "$NGINX_BACKUP_DIR/" 2>/dev/null || true
    done
    _remove_dangling_symlinks
}

inspect_and_resolve_nginx() {
    local DOMAIN="${1:-localhost}"
    local INBOUND_PORT="${2:-443}"
    local PANEL_PORT="${3:-2083}"
    local SUB_PORT="${4:-2096}"
    local BOT_PORT="${5:-0}"

    if ! command -v nginx >/dev/null 2>&1; then
        ui_info "Nginx is not installed yet; it will be installed fresh."
        return 0
    fi

    # Delegate to the advanced Python inspector if available
    if command -v python3 >/dev/null 2>&1 && [[ -f "$_NGX_DIR/nginx_inspector.py" ]]; then
        python3 "$_NGX_DIR/nginx_inspector.py" "$DOMAIN" "$INBOUND_PORT" "$PANEL_PORT" "$SUB_PORT" "$BOT_PORT"
        return $?
    fi

    ui_section "Nginx configuration & conflict inspector"

    local -a EXISTING_CONFIGS=()
    local f
    while IFS= read -r -d '' f; do EXISTING_CONFIGS+=("$f"); done < <(_list_existing_configs)

    if [[ ${#EXISTING_CONFIGS[@]} -eq 0 ]]; then
        ui_ok "No existing conflicting Nginx site configurations found."
        return 0
    fi

    ui_warn "Detected ${#EXISTING_CONFIGS[@]} existing Nginx configuration(s):"
    for f in "${EXISTING_CONFIGS[@]}"; do ui_dim "$f"; done

    local NGINX_CHOICE
    choose NGINX_CHOICE "How would you like to handle existing Nginx configurations?" 1 \
        "Overwrite all - back up to $NGINX_BACKUP_DIR and install the gateway" \
        "Keep all      - preserve existing sites and report port conflicts" \
        "Keep selected - review each configuration file"

    case "$NGINX_CHOICE" in
        1)
            _backup_all "${EXISTING_CONFIGS[@]}"
            ui_ok "Previous configurations backed up to $NGINX_BACKUP_DIR"
            ;;
        2)
            ui_info "Keeping all existing configurations."
            check_port_conflicts "$INBOUND_PORT" "$PANEL_PORT" "$SUB_PORT" "$BOT_PORT"
            ;;
        3)
            mkdir -p "$NGINX_BACKUP_DIR"
            local keep
            for f in "${EXISTING_CONFIGS[@]}"; do
                echo
                ui_info "File: $f"
                grep -E 'server_name|listen' "$f" 2>/dev/null | sed 's/^[ \t]*/      /' || ui_dim "(no listen/server_name directives)"
                if confirm keep "Keep this configuration file?" N; then
                    ui_ok "Kept $f"
                else
                    mv "$f" "$NGINX_BACKUP_DIR/"
                    ui_warn "Moved to backup: $f"
                fi
            done
            _remove_dangling_symlinks
            check_port_conflicts "$INBOUND_PORT" "$PANEL_PORT" "$SUB_PORT" "$BOT_PORT"
            ;;
    esac
}

check_port_conflicts() {
    local BOT_PORT="${4:-0}"
    ui_info "Checking for port collisions with existing Nginx rules..."
    local -a ports=("$1" "$2" "$3")
    [[ -n "$BOT_PORT" && "$BOT_PORT" != "0" ]] && ports+=("$BOT_PORT")

    local port occupied found=0
    for port in "${ports[@]}"; do
        occupied=$(grep -rEn "listen[[:space:]]+([0-9.:]+:)?${port}([^0-9]|$)" /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null | grep -v 'xui_proxy.conf' || true)
        if [[ -n "$occupied" ]]; then
            found=1
            ui_warn "Port $port is already used by an existing configuration:"
            while IFS= read -r line; do ui_dim "$line"; done <<<"$occupied"
        fi
    done
    if [[ $found -eq 1 ]]; then
        ui_dim "You may need to pick a different public port for this gateway."
    else
        ui_ok "No port collisions detected."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    inspect_and_resolve_nginx "$@"
fi
