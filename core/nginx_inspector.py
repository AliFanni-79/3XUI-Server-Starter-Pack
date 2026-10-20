#!/usr/bin/env python3
"""
Nginx Inspector & Conflict Resolver for 3XUI-Server-Starter-Pack
Features:
- Scans existing Nginx server blocks across conf.d and sites-enabled.
- Pre-configuration detection: Checks if 3X-UI panel, inbounds, or subscription are already proxied.
- Update / Completion Mode: Routes missing inbounds/sub without touching working rules.
- Granular Rule-by-Rule Conflict Resolver: Checks (domain, port, path) conflicts and prompts user.
"""

import os
import sys
import json
import re
import glob
import shutil
import sqlite3
import datetime
from pathlib import Path

RED = "\033[0;31m"
GREEN = "\033[0;32m"
BLUE = "\033[0;34m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
NC = "\033[0m"

def tokenize_nginx(content: str):
    """Tokenize Nginx configuration, skipping comments."""
    tokens = []
    i = 0
    n = len(content)
    while i < n:
        c = content[i]
        if c.isspace():
            i += 1
            continue
        if c == '#':
            while i < n and content[i] != '\n':
                i += 1
            continue
        if c in ('{', '}', ';'):
            tokens.append(c)
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            start = i
            i += 1
            while i < n and content[i] != quote:
                if content[i] == '\\':
                    i += 1
                i += 1
            if i < n:
                i += 1
            tokens.append(content[start:i])
            continue
        start = i
        while i < n and not content[i].isspace() and content[i] not in ('{', '}', ';', '#'):
            i += 1
        tokens.append(content[start:i])
    return tokens

def reconstruct_tokens(tokens):
    """Reconstruct formatted text from tokens."""
    lines = []
    current = []
    indent = 0
    for tok in tokens:
        if tok == '{':
            current.append('{')
            lines.append("    " * indent + " ".join(current))
            current = []
            indent += 1
        elif tok == '}':
            if current:
                lines.append("    " * indent + " ".join(current))
                current = []
            indent = max(0, indent - 1)
            lines.append("    " * indent + "}")
        elif tok == ';':
            current.append(';')
            lines.append("    " * indent + " ".join(current))
            current = []
        else:
            current.append(tok)
    if current:
        lines.append("    " * indent + " ".join(current))
    return "\n".join(lines)

def parse_nginx_file(file_path):
    """Parse a single Nginx configuration file into server blocks."""
    try:
        with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except Exception:
        return []

    tokens = tokenize_nginx(content)
    servers = []
    i = 0
    n = len(tokens)

    while i < n:
        if tokens[i] == 'server' and i + 1 < n and tokens[i+1] == '{':
            i += 2
            depth = 1
            listens = []
            server_names = []
            locations = {}
            current_directive = []

            while i < n and depth > 0:
                tok = tokens[i]
                if tok == '{':
                    depth += 1
                    i += 1
                elif tok == '}':
                    depth -= 1
                    i += 1
                elif tok == 'location' and depth == 1:
                    loc_header = []
                    i += 1
                    while i < n and tokens[i] != '{':
                        loc_header.append(tokens[i])
                        i += 1
                    if i < n and tokens[i] == '{':
                        i += 1
                        loc_depth = 1
                        loc_body = []
                        while i < n and loc_depth > 0:
                            if tokens[i] == '{':
                                loc_depth += 1
                            elif tokens[i] == '}':
                                loc_depth -= 1
                            if loc_depth > 0:
                                loc_body.append(tokens[i])
                            i += 1

                        path = "/"
                        mod = ""
                        if len(loc_header) == 1:
                            path = loc_header[0].strip('"\'')
                        elif len(loc_header) >= 2:
                            mod = loc_header[0]
                            path = loc_header[1].strip('"\'')

                        locations[path] = {
                            "modifier": mod,
                            "raw": reconstruct_tokens(loc_body),
                            "tokens": loc_body
                        }
                elif depth == 1:
                    if tok == ';':
                        if current_directive:
                            cmd = current_directive[0]
                            args = current_directive[1:]
                            if cmd == 'listen':
                                listens.append(" ".join(args))
                            elif cmd == 'server_name':
                                for sn in args:
                                    server_names.append(sn.strip('"\'').lower())
                            current_directive = []
                        i += 1
                    else:
                        current_directive.append(tok)
                        i += 1
                else:
                    i += 1

            # Extract numeric ports
            parsed_ports = []
            for l_str in listens:
                m = re.search(r'(?:^|:)(\d{1,5})(?:\s|$)', l_str)
                if m:
                    parsed_ports.append(int(m.group(1)))

            servers.append({
                "file": file_path,
                "listens_raw": listens,
                "ports": parsed_ports,
                "server_names": server_names,
                "locations": locations
            })
        else:
            i += 1

    return servers

def scan_all_nginx_configs():
    """Scan all existing Nginx configuration files except xui_proxy.conf."""
    search_dirs = ["/etc/nginx/conf.d", "/etc/nginx/sites-enabled", "/etc/nginx/sites-available"]
    found_files = []
    for s_dir in search_dirs:
        if os.path.isdir(s_dir):
            for entry in glob.glob(f"{s_dir}/*"):
                if os.path.isfile(entry) and not entry.endswith("xui_proxy.conf"):
                    if entry not in found_files and not os.path.islink(entry):
                        found_files.append(entry)
                    elif os.path.islink(entry):
                        real_path = os.path.realpath(entry)
                        if real_path not in found_files and not real_path.endswith("xui_proxy.conf"):
                            found_files.append(real_path)

    all_servers = []
    for f in found_files:
        all_servers.extend(parse_nginx_file(f))
    return all_servers, found_files

def read_xui_database(db_path="/etc/x-ui/x-ui.db"):
    """Read 3X-UI SQLite database for panel settings and inbounds."""
    if not os.path.isfile(db_path):
        return None

    try:
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()
        cur.execute("SELECT key, value FROM settings")
        settings = dict(cur.fetchall())

        cur.execute("SELECT id, port, protocol, stream_settings, remark FROM inbounds")
        inbounds = []
        for row in cur.fetchall():
            i_id, i_port, proto, stream_raw, remark = row
            try:
                stream = json.loads(stream_raw)
            except Exception:
                stream = {}
            net = stream.get("network", "tcp")
            net_key = f"{net}Settings"
            path_key = "serviceName" if net == "grpc" else "path"
            path = stream.get(net_key, {}).get(path_key, "")
            inbounds.append({
                "id": i_id,
                "port": i_port,
                "protocol": proto,
                "network": net,
                "path": path,
                "remark": remark or f"Inbound-{i_id}"
            })
        conn.close()
        return {"settings": settings, "inbounds": inbounds}
    except Exception:
        return None

def detect_integration(domain, servers, xui_data):
    """Detect whether 3X-UI and Nginx are already partially or fully configured together."""
    domain_lower = domain.lower()
    xui_settings = xui_data["settings"] if xui_data else {}
    xui_inbounds = xui_data["inbounds"] if xui_data else []

    web_port = int(xui_settings.get("webPort", 2053))
    sub_port = int(xui_settings.get("subPort", 2096))
    web_base_path = xui_settings.get("webBasePath", "").strip()

    panel_proxied = None
    sub_proxied = None
    existing_root_rule = None
    routed_inbound_ids = set()

    for s in servers:
        # Check domain match (exact match, wildcard, or default server if none specified)
        matches_domain = domain_lower in s["server_names"] or "_" in s["server_names"] or len(s["server_names"]) == 0

        if not matches_domain:
            continue

        for path, loc_info in s["locations"].items():
            raw_loc = loc_info["raw"]

            # 1. Check Panel proxy
            if (f":{web_port}" in raw_loc or ":20830" in raw_loc) and "proxy_pass" in raw_loc:
                panel_proxied = {
                    "file": s["file"],
                    "port": s["ports"][0] if s["ports"] else 2083,
                    "path": path,
                    "raw": raw_loc
                }

            # 2. Check Sub proxy
            if (f":{sub_port}" in raw_loc or ":20960" in raw_loc) and "proxy_pass" in raw_loc:
                sub_proxied = {
                    "file": s["file"],
                    "port": s["ports"][0] if s["ports"] else 2096,
                    "path": path,
                    "raw": raw_loc
                }

            # 3. Check existing root website (on port 443)
            if 443 in s["ports"] and path == "/":
                if "return 444" not in raw_loc:
                    existing_root_rule = {
                        "file": s["file"],
                        "raw": raw_loc.strip()
                    }

            # 4. Check Inbounds
            for ib in xui_inbounds:
                if ib["path"] and (ib["path"] in path or path.startswith(ib["path"])):
                    routed_inbound_ids.add(ib["id"])
                elif f":{ib['port']}" in raw_loc:
                    routed_inbound_ids.add(ib["id"])

    missing_inbounds = [ib for ib in xui_inbounds if ib["id"] not in routed_inbound_ids]

    return {
        "panel_proxied": panel_proxied,
        "sub_proxied": sub_proxied,
        "existing_root": existing_root_rule,
        "routed_inbound_ids": list(routed_inbound_ids),
        "missing_inbounds": missing_inbounds
    }

def backup_file(filepath, backup_dir):
    """Safely back up a file."""
    os.makedirs(backup_dir, exist_ok=True)
    dst = os.path.join(backup_dir, os.path.basename(filepath))
    try:
        shutil.move(filepath, dst)
        return dst
    except Exception:
        return None

def inspect_and_resolve(domain, inbounds_port=443, panel_port=2083, sub_port=2096, config_json_path="/etc/x-ui/nginx_proxy.json"):
    """Main orchestrator for conflict inspection, resolution, and completion mode."""
    domain = domain.strip().lower()
    inbounds_port = int(inbounds_port)
    panel_port = int(panel_port)
    sub_port = int(sub_port)

    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_dir = f"/etc/nginx/backup_{timestamp}"

    print(f"\n{CYAN}=========================================================={NC}")
    print(f"{CYAN}       Nginx Pre-Configuration & Conflict Inspector       {NC}")
    print(f"{CYAN}=========================================================={NC}")

    servers, found_files = scan_all_nginx_configs()
    xui_data = read_xui_database()

    # Load existing json if available
    proxy_config = {}
    if os.path.isfile(config_json_path):
        try:
            with open(config_json_path, "r", encoding="utf-8") as f:
                proxy_config = json.load(f)
        except Exception:
            proxy_config = {}

    proxy_config["domain"] = domain
    proxy_config["inbounds_port"] = inbounds_port
    proxy_config["panel_public_port"] = panel_port
    proxy_config["sub_public_port"] = sub_port

    if not found_files:
        print(f"{GREEN}[+] No existing Nginx configuration files found. Clean setup.{NC}")
        proxy_config.setdefault("root_location_rule", "return 444;")
        proxy_config.setdefault("skip_panel_proxy", False)
        proxy_config.setdefault("skip_sub_proxy", False)
        proxy_config.setdefault("skip_inbound_ids", [])
        save_json(config_json_path, proxy_config)
        return 0

    integration = detect_integration(domain, servers, xui_data) if xui_data else None

    # --- Scenario 1: Pre-Configured Panel + Nginx Detected ---
    if integration and (integration["panel_proxied"] or integration["routed_inbound_ids"]):
        print(f"\n{GREEN}[+] Detected existing 3X-UI & Nginx integration for {domain}:{NC}")
        if integration["panel_proxied"]:
            p = integration["panel_proxied"]
            print(f"    - 3X-UI Web Panel: Proxied on Port {p['port']} (Path: {p['path']}) in {p['file']}")
        if integration["routed_inbound_ids"]:
            print(f"    - Inbounds already routed in Nginx: {len(integration['routed_inbound_ids'])} inbound(s)")
            for r_id in integration["routed_inbound_ids"]:
                ib = next((x for x in xui_data["inbounds"] if x["id"] == r_id), None)
                if ib:
                    print(f"      * Inbound #{ib['id']} ({ib['remark']}): {ib['protocol']}/{ib['network']} on path {ib['path']}")
        if integration["sub_proxied"]:
            s = integration["sub_proxied"]
            print(f"    - Subscriptions: Proxied on Port {s['port']} (Path: {s['path']}) in {s['file']}")

        # Show missing elements
        missing = integration["missing_inbounds"]
        missing_sub = not integration["sub_proxied"]
        if missing or missing_sub:
            print(f"\n{YELLOW}[!] Unrouted / Missing Components:{NC}")
            if missing:
                print(f"    - {len(missing)} inbound(s) not yet routed in Nginx:")
                for m in missing:
                    print(f"      * Inbound #{m['id']} ({m['remark']}): {m['protocol']}/{m['network']} (Path: {m['path'] or 'needs path'})")
            if missing_sub:
                print(f"    - Subscription reverse proxy (Port {sub_port}) is not yet routed in Nginx.")
        else:
            print(f"\n{GREEN}[+] All inbounds, panel, and subscriptions are fully routed!{NC}")

        print(f"\n{BLUE}How would you like to proceed?{NC}")
        print("  1) Update & Complete Only (Keeps all working panel & inbounds untouched; only routes missing items)")
        print("  2) Interactive Conflict Resolver (Review domain, port, and path conflicts rule-by-rule)")
        print("  3) Overwrite All (Backup existing configs to /etc/nginx/backup and replace with fresh gateway)")
        choice = input(f"Select option [1-3, default: 1]: ").strip() or "1"

        if choice == "1":
            print(f"{GREEN}[+] Running in Update & Completion Mode.{NC}")
            proxy_config["skip_panel_proxy"] = bool(integration["panel_proxied"])
            proxy_config["skip_sub_proxy"] = bool(integration["sub_proxied"])
            proxy_config["skip_inbound_ids"] = integration["routed_inbound_ids"]

            # Preserve root rule if website was already configured
            if integration["existing_root"]:
                proxy_config["root_location_rule"] = integration["existing_root"]["raw"]
                print(f"{GREEN}[+] Preserved existing website root (/) from {integration['existing_root']['file']}.{NC}")
            else:
                proxy_config.setdefault("root_location_rule", "return 444;")

            save_json(config_json_path, proxy_config)
            print(f"{GREEN}[+] Gateway configured for completion mode without disrupting working rules.{NC}")
            return 0
        elif choice == "3":
            print(f"{YELLOW}[*] Backing up all existing configurations to {backup_dir}...{NC}")
            for f in found_files:
                backup_file(f, backup_dir)
            proxy_config["root_location_rule"] = "return 444;"
            proxy_config["skip_panel_proxy"] = False
            proxy_config["skip_sub_proxy"] = False
            proxy_config["skip_inbound_ids"] = []
            save_json(config_json_path, proxy_config)
            print(f"{GREEN}[+] Overwrite complete. Fresh gateway initialized.{NC}")
            return 0

    # --- Scenario 2: Granular Rule-by-Rule Conflict Resolver ---
    print(f"\n{YELLOW}--- Granular Rule-by-Rule Conflict Resolver ---{NC}")

    # Check Conflict on (domain, inbounds_port (443), "/")
    root_rule = "return 444;"
    conflicting_443 = []
    for s in servers:
        matches_domain = domain in s["server_names"] or "_" in s["server_names"]
        if inbounds_port in s["ports"] and matches_domain:
            conflicting_443.append(s)

    if conflicting_443:
        for s in conflicting_443:
            loc_root = s["locations"].get("/", None)
            if loc_root and "return 444" not in loc_root["raw"]:
                print(f"\n{YELLOW}[!] Conflict detected on Domain '{domain}', Port {inbounds_port}, Path '/':{NC}")
                print(f"    File: {s['file']}")
                print(f"    Current rule in file:")
                for r_line in loc_root["raw"].splitlines():
                    print(f"       {r_line}")
                print(f"    Gateway default: return 444; (Stealth Drop)")

                print(f"\nHow would you like to handle this conflict?")
                print(f"  1) Keep existing rule (Preserve website at '/', attach VPN inbounds alongside it)")
                print(f"  2) Replace with Gateway Stealth Drop (return 444;)")
                ans = input("Select option [1-2, default: 1]: ").strip() or "1"
                if ans == "1":
                    root_rule = loc_root["raw"]
                    print(f"{GREEN}[+] Preserving existing root rule.{NC}")
                    # Disable conflicting old file so duplicate server_name warning doesn't trigger
                    backup_file(s["file"], backup_dir)
                    print(f"{BLUE}[*] Migrated existing site rule to gateway; archived {s['file']}.{NC}")
                else:
                    backup_file(s["file"], backup_dir)
                    print(f"{YELLOW}[-] Replaced with Stealth Drop. Archived {s['file']}.{NC}")

    proxy_config["root_location_rule"] = root_rule

    # Check Conflict on (domain, panel_port (2083), panel_path)
    skip_panel = False
    conflicting_panel = []
    for s in servers:
        matches_domain = domain in s["server_names"] or "_" in s["server_names"]
        if panel_port in s["ports"] and matches_domain:
            conflicting_panel.append(s)

    if conflicting_panel:
        for s in conflicting_panel:
            print(f"\n{YELLOW}[!] Conflict detected on Domain '{domain}', Port {panel_port} (3X-UI Web Panel):{NC}")
            print(f"    File: {s['file']}")
            print(f"    Existing server configuration found.")
            print(f"How would you like to handle this conflict?")
            print(f"  1) Keep existing panel config (Leave {s['file']} untouched, do not overwrite)")
            print(f"  2) Replace with Gateway Panel direct SSL proxy")
            ans = input("Select option [1-2, default: 1]: ").strip() or "1"
            if ans == "1":
                skip_panel = True
                print(f"{GREEN}[+] Kept existing panel configuration.{NC}")
            else:
                backup_file(s["file"], backup_dir)
                print(f"{YELLOW}[-] Replaced with Gateway panel proxy. Archived {s['file']}.{NC}")

    proxy_config["skip_panel_proxy"] = skip_panel

    # Check Conflict on (domain, sub_port (2096))
    skip_sub = False
    conflicting_sub = []
    for s in servers:
        matches_domain = domain in s["server_names"] or "_" in s["server_names"]
        if sub_port in s["ports"] and matches_domain:
            conflicting_sub.append(s)

    if conflicting_sub:
        for s in conflicting_sub:
            print(f"\n{YELLOW}[!] Conflict detected on Domain '{domain}', Port {sub_port} (Subscriptions):{NC}")
            print(f"    File: {s['file']}")
            print(f"How would you like to handle this conflict?")
            print(f"  1) Keep existing subscription config (Leave {s['file']} untouched)")
            print(f"  2) Replace with Gateway subscription proxy")
            ans = input("Select option [1-2, default: 1]: ").strip() or "1"
            if ans == "1":
                skip_sub = True
                print(f"{GREEN}[+] Kept existing subscription configuration.{NC}")
            else:
                backup_file(s["file"], backup_dir)
                print(f"{YELLOW}[-] Replaced with Gateway subscription proxy. Archived {s['file']}.{NC}")

    proxy_config["skip_sub_proxy"] = skip_sub
    proxy_config.setdefault("skip_inbound_ids", [])

    save_json(config_json_path, proxy_config)
    print(f"\n{GREEN}[+] All conflicts inspected and resolved successfully.{NC}")
    return 0

def save_json(path, data):
    """Save configuration dictionary to JSON file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

if __name__ == "__main__":
    domain_arg = sys.argv[1] if len(sys.argv) > 1 else "localhost"
    in_port = sys.argv[2] if len(sys.argv) > 2 else 443
    pan_port = sys.argv[3] if len(sys.argv) > 3 else 2083
    sub_port_arg = sys.argv[4] if len(sys.argv) > 4 else 2096
    inspect_and_resolve(domain_arg, in_port, pan_port, sub_port_arg)
