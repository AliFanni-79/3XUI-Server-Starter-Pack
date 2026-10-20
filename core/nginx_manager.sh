#!/usr/bin/env bash
set -e

# ==============================================================================
# Nginx Manager: Conflict Resolver & Inspector
# Handles: Overwrite All, Keep All, and Keep Selected (Rule-by-rule)
# ==============================================================================

BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NGINX_BACKUP_DIR="/etc/nginx/backup_${BACKUP_TIMESTAMP}"

inspect_and_resolve_nginx() {
    local INBOUND_PORT="${1:-443}"
    local PANEL_PORT="${2:-2083}"
    local SUB_PORT="${3:-2096}"

    echo ""
    echo "=========================================================="
    echo "         Nginx Configuration & Conflict Inspector         "
    echo "=========================================================="

    if ! command -v nginx >/dev/null 2>&1; then
        echo "[*] Nginx is not installed. Will be installed freshly."
        return 0
    fi

    local EXISTING_CONFIGS=()
    while IFS= read -r -d $'\0' file; do
        if [[ "$(basename "$file")" != "xui_proxy.conf" ]]; then
            EXISTING_CONFIGS+=("$file")
        fi
    done < <(find /etc/nginx/conf.d /etc/nginx/sites-enabled -type f \( -name "*.conf" -o -name "default" \) -print0 2>/dev/null)

    if [[ ${#EXISTING_CONFIGS[@]} -eq 0 ]]; then
        echo "[*] No existing conflicting Nginx site configurations found."
        return 0
    fi

    echo "[!] Detected ${#EXISTING_CONFIGS[@]} existing Nginx configuration(s):"
    for cfg in "${EXISTING_CONFIGS[@]}"; do
        echo "    - $cfg"
    done
    echo ""
    echo "How would you like to handle existing Nginx configurations?"
    echo "  1) Overwrite All (Backup existing configs to $NGINX_BACKUP_DIR and install gateway)"
    echo "  2) Keep All      (Preserve all existing sites; detect port conflicts)"
    echo "  3) Keep Selected (Review each configuration rule-by-rule)"
    read -rp "Select an option [1-3, default: 1]: " NGINX_CHOICE
    NGINX_CHOICE=${NGINX_CHOICE:-1}

    case "$NGINX_CHOICE" in
        1)
            echo "[*] Creating backup directory at $NGINX_BACKUP_DIR..."
            mkdir -p "$NGINX_BACKUP_DIR"
            for cfg in "${EXISTING_CONFIGS[@]}"; do
                mv "$cfg" "$NGINX_BACKUP_DIR/" 2>/dev/null || true
            done
            # Also clean broken symlinks in sites-enabled
            find /etc/nginx/sites-enabled -xtype l -delete 2>/dev/null || true
            echo "[+] All previous configurations backed up and removed."
            ;;
        2)
            echo "[*] Keeping all existing configurations."
            check_port_conflicts "$INBOUND_PORT" "$PANEL_PORT" "$SUB_PORT"
            ;;
        3)
            echo "[*] Reviewing configurations rule-by-rule..."
            mkdir -p "$NGINX_BACKUP_DIR"
            for cfg in "${EXISTING_CONFIGS[@]}"; do
                echo "----------------------------------------------------------"
                echo "File: $cfg"
                echo "Server Names / Ports detected:"
                grep -E 'server_name|listen' "$cfg" | sed 's/^[ \t]*/   /' || echo "   (No listen/server_name found)"
                echo ""
                read -rp "Keep this configuration file? (y/N): " KEEP_FILE
                if [[ "$KEEP_FILE" =~ ^[Yy]$ ]]; then
                    echo "[+] Kept $cfg"
                else
                    mv "$cfg" "$NGINX_BACKUP_DIR/"
                    echo "[-] Moved to backup: $cfg"
                fi
            done
            find /etc/nginx/sites-enabled -xtype l -delete 2>/dev/null || true
            check_port_conflicts "$INBOUND_PORT" "$PANEL_PORT" "$SUB_PORT"
            ;;
        *)
            echo "[!] Invalid option selected. Defaulting to Overwrite with Backup."
            mkdir -p "$NGINX_BACKUP_DIR"
            for cfg in "${EXISTING_CONFIGS[@]}"; do
                mv "$cfg" "$NGINX_BACKUP_DIR/" 2>/dev/null || true
            done
            find /etc/nginx/sites-enabled -xtype l -delete 2>/dev/null || true
            ;;
    esac
}

check_port_conflicts() {
    local INBOUND_PORT="$1"
    local PANEL_PORT="$2"
    local SUB_PORT="$3"

    echo "[*] Checking for port collisions with existing Nginx rules..."
    local PORTS_CHECK=("$INBOUND_PORT" "$PANEL_PORT" "$SUB_PORT")

    for port in "${PORTS_CHECK[@]}"; do
        local OCCUPIED
        OCCUPIED=$(grep -rE "listen[ \t]+([0-9\.\:]+:)?"$port"[^0-9]" /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null | grep -v "xui_proxy.conf" || true)
        if [[ -n "$OCCUPIED" ]]; then
            echo "[WARNING] Port $port is in use by an existing configuration:"
            echo "$OCCUPIED"
            echo "You may need to select a different public port for this gateway service."
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    inspect_and_resolve_nginx "$@"
fi
