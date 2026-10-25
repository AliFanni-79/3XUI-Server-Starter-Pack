#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 3X-UI Manager: Installation & Database Settings Configurator
# Ensures: Sanaei 3X-UI installation, WAL mode, sub-link reverse proxy settings,
#          internal port shifting, loopback binding.
# ==============================================================================

_XUI_MGR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$_XUI_MGR_DIR/lib.sh"

XUI_DB_FILE="/etc/x-ui/x-ui.db"

# Upsert a row in the 3X-UI settings table (the table has no UNIQUE(key)).
# Values are validated by callers; single quotes are doubled defensively.
_xui_set() { # _xui_set KEY VALUE
    local k="${1//\'/\'\'}" v="${2//\'/\'\'}"
    sqlite3 "$XUI_DB_FILE" "UPDATE settings SET value='${v}' WHERE key='${k}';
        INSERT INTO settings (key, value) SELECT '${k}', '${v}' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='${k}');"
}

_xui_get() { sqlite3 "$XUI_DB_FILE" "SELECT value FROM settings WHERE key='${1//\'/\'\'}';" 2>/dev/null || true; }

install_and_configure_xui() {
    local DOMAIN="$1"
    local SUB_PUBLIC_PORT="${2:-2096}"
    local PANEL_PUBLIC_PORT="${3:-2083}"
    local PANEL_INTERNAL_PORT="${4:-20830}"
    local SUB_INTERNAL_PORT="${5:-20960}"

    if [[ ! -f "$XUI_DB_FILE" ]]; then
        ui_info "3X-UI panel not found. Installing latest MHSanaei 3X-UI..."
        # Silence redundant prompts from the upstream installer:
        # SQLite is required by the sync engine, the panel listens on its internal
        # port, and TLS is terminated by Nginx.
        export XUI_NONINTERACTIVE=1 XUI_DB_TYPE="sqlite" XUI_PANEL_PORT="${PANEL_INTERNAL_PORT}" XUI_SSL_MODE="none"
        bash <(curl -fLs https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) \
            || die "The upstream 3X-UI installer failed."
        sleep 2
        [[ -f "$XUI_DB_FILE" ]] || die "3X-UI installed but $XUI_DB_FILE does not exist."
    else
        ui_ok "Found existing 3X-UI installation"
    fi

    ui_info "Configuring database for Nginx reverse proxy"

    # 1. WAL mode prevents concurrent write-lock freezes between x-ui and the sync engine.
    sqlite3 "$XUI_DB_FILE" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true

    # 2. Subscription links are generated from the public domain.
    _xui_set subDomain "$DOMAIN"

    # 3. Internal listeners must not collide with the public Nginx ports.
    local cur_web cur_sub
    cur_web="$(_xui_get webPort)"; cur_web="${cur_web:-2053}"
    cur_sub="$(_xui_get subPort)"; cur_sub="${cur_sub:-2096}"
    if [[ "$cur_web" == "$PANEL_PUBLIC_PORT" ]]; then
        ui_dim "Shifting internal webPort ${cur_web} -> ${PANEL_INTERNAL_PORT}"
        _xui_set webPort "$PANEL_INTERNAL_PORT"
    fi
    if [[ "$cur_sub" == "$SUB_PUBLIC_PORT" ]]; then
        ui_dim "Shifting internal subPort ${cur_sub} -> ${SUB_INTERNAL_PORT}"
        _xui_set subPort "$SUB_INTERNAL_PORT"
    fi

    # 4. Bind internal listeners to loopback only.
    _xui_set webListen "127.0.0.1"
    _xui_set subListen "127.0.0.1"

    # Apply the changes.
    systemctl reset-failed x-ui 2>/dev/null || true
    if systemctl restart x-ui 2>/dev/null; then
        ui_ok "3X-UI configured and restarted"
    else
        ui_warn "Could not restart x-ui automatically; run: systemctl restart x-ui"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_and_configure_xui "$@"
fi
