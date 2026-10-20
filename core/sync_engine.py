import os
import sys
import json
import sqlite3
import subprocess
import time
import logging

CONFIG_FILE = "/etc/x-ui/nginx_proxy.json"
STATE_FILE = "/tmp/xui_sync.lock"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)

def load_config():
    if not os.path.exists(CONFIG_FILE):
        logging.error(f"Configuration file {CONFIG_FILE} not found.")
        sys.exit(1)
    with open(CONFIG_FILE, "r") as f:
        conf = json.load(f)
    conf.setdefault("panel_internal_port", 20830)
    conf.setdefault("sub_internal_port", 20960)
    conf.setdefault("bot_internal_port", 8080)
    conf.setdefault("inbounds_port", 443)
    conf.setdefault("panel_public_port", 2083)
    conf.setdefault("sub_public_port", 2096)
    conf.setdefault("bot_public_port", 8443)
    conf.setdefault("sub_path", "/sub/")
    conf.setdefault("enable_reality_stream", False)
    return conf

def extract_ech_config(stream_dict):
    """Extract ECH (Encrypted Client Hello) config from stream_settings."""
    if not isinstance(stream_dict, dict):
        return ""
    for sec_key in ["realitySettings", "tlsSettings", "echSettings"]:
        sec_dict = stream_dict.get(sec_key, {})
        if isinstance(sec_dict, dict):
            if "echConfigList" in sec_dict and sec_dict["echConfigList"]:
                return str(sec_dict["echConfigList"]).strip()
            if "ech_config_list" in sec_dict and sec_dict["ech_config_list"]:
                return str(sec_dict["ech_config_list"]).strip()
    return ""

def sync():
    conf = load_config()
    db_path = conf.get("db_path", "/etc/x-ui/x-ui.db")

    if not os.path.exists(db_path):
        logging.error(f"Database {db_path} does not exist. Please ensure 3X-UI is installed.")
        return

    # Debounce (5 seconds cooldown to prevent rapid trigger loops)
    now = time.time()
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                if now - float(f.read().strip()) < 5:
                    logging.info("Skipped: Ran within 5s debounce window.")
                    return
        except Exception:
            pass

    with open(STATE_FILE, "w") as f:
        f.write(str(now))

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    db_modified = False

    # 1. Read Panel & Sub settings from 3X-UI
    cursor.execute("SELECT key, value FROM settings")
    settings = dict(cursor.fetchall())

    web_port = int(settings.get("webPort", conf["panel_internal_port"]))
    sub_port = int(settings.get("subPort", conf["sub_internal_port"])) if "subPort" in settings else conf["sub_internal_port"]
    web_cert = settings.get("webCertFile", "").strip()
    sub_cert = settings.get("subCertFile", "").strip()

    web_base_path = settings.get("webBasePath", "").strip()
    if web_base_path and not web_base_path.startswith("/"):
        web_base_path = "/" + web_base_path
    if web_base_path and not web_base_path.endswith("/"):
        web_base_path = web_base_path + "/"

    sub_path = settings.get("subPath", conf.get("sub_path", "/sub/")).strip()
    if sub_path and not sub_path.startswith("/"):
        sub_path = "/" + sub_path
    if sub_path and not sub_path.endswith("/"):
        sub_path = sub_path + "/"

    # Configure Reverse Proxy settings in 3X-UI settings table for subscription generation
    if settings.get("subDomain") != conf["domain"]:
        cursor.execute("UPDATE settings SET value = ? WHERE key = 'subDomain'", (conf["domain"],))
        db_modified = True

    if settings.get("subPort") != str(conf["sub_public_port"]):
        cursor.execute("UPDATE settings SET value = ? WHERE key = 'subPort'", (str(conf["sub_public_port"]),))
        db_modified = True

    panel_proto = "https" if web_cert else "http"
    sub_proto = "https" if sub_cert else "http"

    # Avoid port collisions for internal services
    reserved_public = [
        conf["inbounds_port"],
        conf["panel_public_port"],
        conf["sub_public_port"],
        conf["bot_public_port"],
        80
    ]

    panel_internal_port = conf["panel_internal_port"]
    if web_port in reserved_public:
        cursor.execute("UPDATE settings SET value = ? WHERE key = 'webPort'", (str(panel_internal_port),))
        web_port = panel_internal_port
        db_modified = True

    sub_internal_port = conf["sub_internal_port"]
    if sub_port in reserved_public:
        cursor.execute("UPDATE settings SET value = ? WHERE key = 'subPort'", (str(sub_internal_port),))
        sub_port = sub_internal_port
        db_modified = True

    # 2. Inspect Inbounds
    cursor.execute("SELECT id, port, listen, protocol, settings, stream_settings, remark, enable FROM inbounds")
    inbounds = cursor.fetchall()

    proxied_http_inbounds = []
    reality_inbounds = []
    seen_paths = set()
    if web_base_path:
        seen_paths.add(web_base_path.rstrip("/"))
    if sub_path:
        seen_paths.add(sub_path.rstrip("/"))

    for row in inbounds:
        inbound_id, port, listen, protocol, settings_json, stream_json, remark, enable = row
        if not enable:
            continue

        try:
            stream = json.loads(stream_json) if stream_json else {}
        except Exception:
            stream = {}

        network = stream.get("network", "tcp")
        security = stream.get("security", "none")

        # Extract ECH (Encrypted Client Hello) before modifying anything
        ech_config = extract_ech_config(stream)

        # Handle REALITY inbounds
        if security == "reality":
            reality_settings = stream.get("realitySettings", {})
            server_names = reality_settings.get("serverNames", [])
            sni = server_names[0] if server_names else conf["domain"]
            fingerprint = reality_settings.get("fingerprint", "chrome")
            public_key = reality_settings.get("publicKey", "")
            short_ids = reality_settings.get("shortIds", [])
            short_id = short_ids[0] if short_ids else ""

            reality_inbounds.append({
                "id": inbound_id,
                "port": port,
                "protocol": protocol,
                "network": network,
                "remark": remark or f"Reality-{inbound_id}",
                "sni": sni,
                "fingerprint": fingerprint,
                "public_key": public_key,
                "short_id": short_id,
                "ech_config": ech_config
            })
            continue

        # Skip non-HTTP-compatible raw TCP (unless REALITY which is handled above)
        if network not in ["ws", "httpupgrade", "splithttp", "xhttp", "grpc"]:
            continue

        inbound_updated = False

        # Port conflict & loopback binding
        target_port = port
        if port in reserved_public:
            target_port = 10000 + inbound_id
            cursor.execute("UPDATE inbounds SET port = ? WHERE id = ?", (target_port, inbound_id))
            inbound_updated = True

        if listen != "127.0.0.1":
            cursor.execute("UPDATE inbounds SET listen = '127.0.0.1' WHERE id = ?", (inbound_id,))
            inbound_updated = True

        # Strip double TLS (Only for non-Trojan; Trojan strictly requires TLS in Xray)
        if security == "tls" and protocol.lower() != "trojan":
            stream["security"] = "none"
            inbound_updated = True

        # Path protection: Ensure unique paths for Nginx location routing
        net_key = f"{network}Settings" if network != "httpupgrade" else "httpupgradeSettings"
        path_key = "serviceName" if network == "grpc" else "path"
        net_settings = stream.get(net_key, {})
        current_path = net_settings.get(path_key, "").strip()

        if network == "grpc":
            if not current_path or current_path in seen_paths:
                new_path = f"grpc-{protocol}-{inbound_id}"
                net_settings[path_key] = new_path
                stream[net_key] = net_settings
                current_path = new_path
                inbound_updated = True
        else:
            if not current_path.startswith("/"):
                current_path = "/" + current_path
            if current_path == "/" or current_path.rstrip("/") in seen_paths:
                new_path = f"/{protocol}-{network}-{inbound_id}"
                net_settings[path_key] = new_path
                stream[net_key] = net_settings
                current_path = new_path
                inbound_updated = True

        seen_paths.add(current_path.rstrip("/"))

        # Inject externalProxy for SpeedyBot & older link generators
        expected_ext_proxy = [{
            "forceTls": "tls",
            "dest": conf["domain"],
            "port": conf["inbounds_port"],
            "remark": remark or f"Inbound-{inbound_id}"
        }]
        if stream.get("externalProxy") != expected_ext_proxy:
            stream["externalProxy"] = expected_ext_proxy
            inbound_updated = True

        if inbound_updated:
            cursor.execute("UPDATE inbounds SET stream_settings = ? WHERE id = ?", (json.dumps(stream), inbound_id))
            db_modified = True

        proxied_http_inbounds.append({
            "id": inbound_id,
            "port": target_port,
            "protocol": protocol,
            "network": network,
            "path": current_path,
            "remark": remark or f"Inbound-{inbound_id}",
            "ech_config": ech_config
        })

    # 3. Synchronize Modern 3X-UI "hosts" table
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='hosts'")
    if cursor.fetchone():
        now_ms = int(time.time() * 1000)

        # Sync HTTP-proxied inbounds into hosts
        for ib in proxied_http_inbounds:
            cursor.execute("SELECT id, address, port, security, path, ech_config_list FROM hosts WHERE inbound_id = ?", (ib["id"],))
            host_row = cursor.fetchone()
            if not host_row:
                cursor.execute("""
                    INSERT INTO hosts (
                        inbound_id, sort_order, remark, server_description,
                        is_disabled, is_hidden, address, port, security,
                        sni, host_header, path, ech_config_list, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    ib["id"], 0, ib["remark"], "",
                    0, 0, conf["domain"], conf["inbounds_port"], "tls",
                    conf["domain"], conf["domain"], ib["path"], ib["ech_config"], now_ms, now_ms
                ))
                db_modified = True
            else:
                h_id, h_addr, h_port, h_sec, h_path, h_ech = host_row
                if (h_addr != conf["domain"] or h_port != conf["inbounds_port"] or
                    h_sec != "tls" or h_path != ib["path"] or (ib["ech_config"] and h_ech != ib["ech_config"])):
                    cursor.execute("""
                        UPDATE hosts SET
                            address = ?, port = ?, security = 'tls',
                            sni = ?, host_header = ?, path = ?,
                            ech_config_list = COALESCE(NULLIF(?, ''), ech_config_list),
                            updated_at = ?
                        WHERE id = ?
                    """, (
                        conf["domain"], conf["inbounds_port"],
                        conf["domain"], conf["domain"], ib["path"],
                        ib["ech_config"], now_ms, h_id
                    ))
                    db_modified = True

        # Sync REALITY inbounds into hosts (Preserving Reality security, SNI, Fingerprint, and ECH!)
        for r_ib in reality_inbounds:
            cursor.execute("SELECT id, address, port, security, sni, fingerprint, ech_config_list FROM hosts WHERE inbound_id = ?", (r_ib["id"],))
            host_row = cursor.fetchone()
            if not host_row:
                cursor.execute("""
                    INSERT INTO hosts (
                        inbound_id, sort_order, remark, server_description,
                        is_disabled, is_hidden, address, port, security,
                        sni, fingerprint, ech_config_list, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    r_ib["id"], 0, r_ib["remark"], "",
                    0, 0, conf["domain"], r_ib["port"], "reality",
                    r_ib["sni"], r_ib["fingerprint"], r_ib["ech_config"], now_ms, now_ms
                ))
                db_modified = True
            else:
                h_id, h_addr, h_port, h_sec, h_sni, h_fp, h_ech = host_row
                if (h_sec != "reality" or h_sni != r_ib["sni"] or h_fp != r_ib["fingerprint"] or
                    (r_ib["ech_config"] and h_ech != r_ib["ech_config"])):
                    cursor.execute("""
                        UPDATE hosts SET
                            address = ?, port = ?, security = 'reality',
                            sni = ?, fingerprint = ?,
                            ech_config_list = COALESCE(NULLIF(?, ''), ech_config_list),
                            updated_at = ?
                        WHERE id = ?
                    """, (
                        conf["domain"], r_ib["port"],
                        r_ib["sni"], r_ib["fingerprint"],
                        r_ib["ech_config"], now_ms, h_id
                    ))
                    db_modified = True

    if db_modified:
        conn.commit()
        logging.info("Database updated with inbounds, hosts, ECH parameters, and subscription settings.")
    else:
        logging.info("Database inbounds and hosts are up to date.")
    conn.close()

    # 4. Generate Nginx Config (Zero downtime - never restarts x-ui)
    generate_nginx_config(conf, proxied_http_inbounds, web_port, panel_proto, web_base_path, sub_port, sub_proto, sub_path)

def generate_nginx_config(conf, inbounds, panel_port, panel_proto, web_base_path, sub_port, sub_proto, sub_path):
    domain = conf["domain"]
    ssl_cert = conf["ssl_cert"]
    ssl_key = conf["ssl_key"]
    inbounds_port = conf["inbounds_port"]
    panel_public = conf["panel_public_port"]
    sub_public = conf["sub_public_port"]
    bot_public = conf["bot_public_port"]
    bot_internal = conf["bot_internal_port"]

    root_rule = conf.get("root_location_rule", "return 444;").strip()
    skip_panel = conf.get("skip_panel_proxy", False)
    skip_sub = conf.get("skip_sub_proxy", False)
    skip_bot = conf.get("skip_bot_proxy", False)
    skip_inbound_ids = set(conf.get("skip_inbound_ids", []))

    lines = [
        "# Auto-generated by xui-nginx-sync.py - DO NOT EDIT MANUALLY",
        "map $http_upgrade $connection_upgrade {",
        "    default upgrade;",
        "    '' close;",
        "}",
        "",
        "# Port 80 Redirect",
        "server {",
        "    listen 80;",
        "    listen [::]:80;",
        f"    server_name {domain};",
        "    location /.well-known/acme-challenge/ { root /var/www/html; }",
        "    location / { return 301 https://$host$request_uri; }",
        "}",
        "",
        f"# Inbounds Gateway on Port {inbounds_port}",
        "server {",
        f"    listen {inbounds_port} ssl;",
        f"    listen [::]:{inbounds_port} ssl;",
        "    http2 on;",
        f"    server_name {domain};",
        f"    ssl_certificate {ssl_cert};",
        f"    ssl_certificate_key {ssl_key};",
        "    ssl_protocols TLSv1.2 TLSv1.3;",
        "    ssl_ciphers HIGH:!aNULL:!MD5;",
        "",
        "    # Root location (/) handler",
        "    location / {",
    ]

    for r_line in root_rule.splitlines():
        r_line_clean = r_line.strip()
        if r_line_clean:
            lines.append(f"        {r_line_clean}")
    lines.append("    }")

    for ib in inbounds:
        if ib["id"] in skip_inbound_ids:
            continue

        net = ib["network"]
        path = ib["path"]
        port = ib["port"]
        remark = ib.get("remark", "")

        lines.append(f"\n    # Inbound #{ib['id']} ({remark}) - {ib['protocol']} over {net}")
        if net in ["ws", "httpupgrade"]:
            lines.extend([
                f"    location ^~ {path} {{",
                "        proxy_redirect off;",
                f"        proxy_pass http://127.0.0.1:{port};",
                "        client_max_body_size 0;",
                "        proxy_http_version 1.1;",
                "        proxy_set_header Upgrade $http_upgrade;",
                "        proxy_set_header Connection $connection_upgrade;",
                "        proxy_set_header Host $host;",
                "        proxy_set_header X-Real-IP $remote_addr;",
                "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
                "        proxy_read_timeout 86400s;",
                "        proxy_send_timeout 86400s;",
            ])
            if net == "httpupgrade":
                lines.append("        proxy_buffering off;")
            lines.append("    }")
        elif net in ["splithttp", "xhttp"]:
            lines.extend([
                f"    location ^~ {path} {{",
                "        proxy_redirect off;",
                f"        proxy_pass http://127.0.0.1:{port};",
                "        client_max_body_size 0;",
                "        proxy_http_version 1.1;",
                "        proxy_buffering off;",
                "        proxy_request_buffering off;",
                "        proxy_set_header Host $host;",
                "        proxy_set_header X-Real-IP $remote_addr;",
                "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
                "        proxy_read_timeout 86400s;",
                "        proxy_send_timeout 86400s;",
                "    }"
            ])
        elif net == "grpc":
            grpc_path = path if path.startswith("/") else f"/{path}"
            lines.extend([
                f"    location ^~ {grpc_path} {{",
                f"        grpc_pass grpc://127.0.0.1:{port};",
                "        client_max_body_size 0;",
                "        grpc_set_header Host $host;",
                "        grpc_set_header X-Real-IP $remote_addr;",
                "        grpc_read_timeout 86400s;",
                "        grpc_send_timeout 86400s;",
                "    }"
            ])

    lines.append("}\n")

    # Port 2083: 3X-UI Web Panel (Direct proxy, NO 302 redirect leaking secret path)
    if not skip_panel:
        panel_ssl_verify = "        proxy_ssl_verify off;\n        proxy_ssl_server_name on;" if panel_proto == "https" else ""
        lines.extend([
            f"# 3X-UI Web Panel on Port {panel_public}",
            "server {",
            f"    listen {panel_public} ssl;",
            f"    listen [::]:{panel_public} ssl;",
            "    http2 on;",
            f"    server_name {domain};",
            f"    ssl_certificate {ssl_cert};",
            f"    ssl_certificate_key {ssl_key};",
            "    client_max_body_size 16m;",
            "",
            "    location / {",
            f"        proxy_pass {panel_proto}://127.0.0.1:{panel_port};",
            panel_ssl_verify,
            "        proxy_http_version 1.1;",
            "        proxy_set_header Upgrade $http_upgrade;",
            "        proxy_set_header Connection $connection_upgrade;",
            "        proxy_set_header Host $host;",
            "        proxy_set_header X-Real-IP $remote_addr;",
            "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
            "        proxy_read_timeout 86400s;",
            "        proxy_send_timeout 86400s;",
            "    }",
            "}\n"
        ])

    # Port 2096: 3X-UI Subscription (Direct proxy, NO 302 redirect leaking sub path)
    if not skip_sub:
        sub_ssl_verify = "        proxy_ssl_verify off;\n        proxy_ssl_server_name on;" if sub_proto == "https" else ""
        lines.extend([
            f"# 3X-UI Subscription on Port {sub_public}",
            "server {",
            f"    listen {sub_public} ssl;",
            f"    listen [::]:{sub_public} ssl;",
            "    http2 on;",
            f"    server_name {domain};",
            f"    ssl_certificate {ssl_cert};",
            f"    ssl_certificate_key {ssl_key};",
            "    client_max_body_size 16m;",
            "",
            "    location / {",
            f"        proxy_pass {sub_proto}://127.0.0.1:{sub_port};",
            sub_ssl_verify,
            "        proxy_http_version 1.1;",
            "        proxy_set_header Host $host;",
            "        proxy_set_header X-Real-IP $remote_addr;",
            "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
            "    }",
            "}\n"
        ])

    # Telegram Bot WebUI on Port 8443
    if not skip_bot:
        lines.extend([
            f"# Telegram Bot WebUI on Port {bot_public}",
            "server {",
            f"    listen {bot_public} ssl;",
            f"    listen [::]:{bot_public} ssl;",
            "    http2 on;",
            f"    server_name {domain};",
            f"    ssl_certificate {ssl_cert};",
            f"    ssl_certificate_key {ssl_key};",
            "    client_max_body_size 16m;",
            "",
            "    location / {",
            f"        proxy_pass http://127.0.0.1:{bot_internal};",
            "        proxy_http_version 1.1;",
            "        proxy_set_header Upgrade $http_upgrade;",
            "        proxy_set_header Connection $connection_upgrade;",
            "        proxy_set_header Host $host;",
            "        proxy_set_header X-Real-IP $remote_addr;",
            "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
            "        proxy_read_timeout 86400s;",
            "        proxy_send_timeout 86400s;",
            "    }",
            "}\n"
        ])

    conf_content = "\n".join([line for line in lines if line is not None])
    conf_path = conf.get("nginx_conf_path", "/etc/nginx/conf.d/xui_proxy.conf")

    # Check for diffs before writing
    if os.path.exists(conf_path):
        with open(conf_path, "r") as f:
            existing = f.read()
        if existing.strip() == conf_content.strip():
            logging.info("Nginx configuration is already identical. No reload needed.")
            return

    with open(conf_path, "w") as f:
        f.write(conf_content)

    test = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
    if test.returncode == 0:
        subprocess.run(["systemctl", "reload", "nginx"], check=False)
        logging.info("Nginx configuration updated and reloaded successfully.")
    else:
        logging.error(f"Nginx config validation failed:\n{test.stderr}")

if __name__ == "__main__":
    sync()
