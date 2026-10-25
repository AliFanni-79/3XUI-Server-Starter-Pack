import os
import re
import sys
import json
import sqlite3
import subprocess
import shutil
import tempfile
import time
import logging

try:  # POSIX only; the engine itself only ever runs on Linux
    import fcntl
except ImportError:  # pragma: no cover
    fcntl = None

CONFIG_FILE = "/etc/x-ui/nginx_proxy.json"
LOCK_FILE = os.path.join("/run" if os.access("/run", os.W_OK) else tempfile.gettempdir(), "xui-sync.lock")
DEBOUNCE_SECONDS = 5

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[logging.StreamHandler(sys.stdout)]
)

def load_config():
    if not os.path.exists(CONFIG_FILE):
        logging.error(f"Configuration file {CONFIG_FILE} not found.")
        sys.exit(1)
    try:
        with open(CONFIG_FILE, "r") as f:
            conf = json.load(f)
    except (OSError, ValueError) as e:
        logging.error(f"Configuration file {CONFIG_FILE} is unreadable or invalid: {e}")
        sys.exit(1)
    for key in ("domain", "ssl_cert", "ssl_key"):
        if not str(conf.get(key, "")).strip():
            logging.error(f"Configuration is missing required key '{key}'. Re-run the installer.")
            sys.exit(1)
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

def extract_inbound_host_header(stream_dict, default_domain=""):
    """Extract configured Host header from inbound stream settings."""
    if not isinstance(stream_dict, dict):
        return default_domain
    net = stream_dict.get("network", "tcp")
    net_key = f"{net}Settings" if net != "httpupgrade" else "httpupgradeSettings"
    net_settings = stream_dict.get(net_key, {})
    if not isinstance(net_settings, dict):
        net_settings = {}

    host_val = None
    if net == "ws":
        headers = net_settings.get("headers", {})
        if isinstance(headers, dict):
            host_val = headers.get("Host") or headers.get("host")
        if not host_val:
            host_val = net_settings.get("host")
    elif net in ["httpupgrade", "splithttp", "xhttp"]:
        host_val = net_settings.get("host")
        if not host_val:
            headers = net_settings.get("headers", {})
            if isinstance(headers, dict):
                host_val = headers.get("Host") or headers.get("host")
    elif net == "grpc":
        host_val = net_settings.get("authority")
    elif net == "http":
        h = net_settings.get("host")
        if isinstance(h, list) and len(h) > 0:
            host_val = h[0]
        elif isinstance(h, str):
            host_val = h
    elif net == "tcp":
        tcp_header = net_settings.get("header", {})
        if isinstance(tcp_header, dict) and tcp_header.get("type") == "http":
            req_headers = tcp_header.get("request", {}).get("headers", {})
            if isinstance(req_headers, dict):
                h = req_headers.get("Host") or req_headers.get("host")
                if isinstance(h, list) and len(h) > 0:
                    host_val = h[0]
                elif isinstance(h, str):
                    host_val = h

    if host_val and str(host_val).strip():
        return str(host_val).strip()

    return default_domain

def extract_inbound_sni(stream_dict, default_domain=""):
    """Extract configured SNI from inbound stream settings."""
    if not isinstance(stream_dict, dict):
        return default_domain
    sec = stream_dict.get("security", "none")
    if sec == "reality":
        server_names = stream_dict.get("realitySettings", {}).get("serverNames", [])
        if server_names and server_names[0] and str(server_names[0]).strip():
            return str(server_names[0]).strip()
    elif sec == "tls":
        server_name = stream_dict.get("tlsSettings", {}).get("serverName", "")
        if server_name and str(server_name).strip():
            return str(server_name).strip()

    # Even if security is 'none' (or stripped), preserve original tlsSettings serverName
    tls_sn = stream_dict.get("tlsSettings", {}).get("serverName", "")
    if tls_sn and str(tls_sn).strip():
        return str(tls_sn).strip()

    return default_domain

def safe_int(value, default):
    """Convert a settings value to int, falling back to a default."""
    try:
        return int(str(value).strip())
    except (ValueError, TypeError):
        return default

def set_setting(cursor, settings, key, value):
    """Upsert a 3X-UI setting (the table has no UNIQUE(key)). Returns True if changed."""
    value = str(value)
    if settings.get(key) == value:
        return False
    cursor.execute("UPDATE settings SET value = ? WHERE key = ?", (value, key))
    if cursor.rowcount == 0:
        cursor.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (key, value))
    settings[key] = value
    return True

def sync(force=False):
    """Serialise runs with a file lock and coalesce bursts of DB writes.

    A run that starts inside the debounce window waits for the remainder
    instead of being dropped, so a change made right after a previous run is
    never lost.
    """
    conf = load_config()
    lock_fh = open(LOCK_FILE, "a+")
    try:
        if fcntl:
            fcntl.flock(lock_fh, fcntl.LOCK_EX)
        if not force:
            lock_fh.seek(0)
            try:
                last = float(lock_fh.read().strip() or 0)
            except ValueError:
                last = 0.0
            wait = DEBOUNCE_SECONDS - (time.time() - last)
            if wait > 0:
                logging.info(f"Debounce: waiting {wait:.1f}s for pending writes to settle.")
                time.sleep(wait)
        try:
            _sync_locked(conf)
        finally:
            lock_fh.seek(0)
            lock_fh.truncate()
            lock_fh.write(str(time.time()))
            lock_fh.flush()
    finally:
        lock_fh.close()

def _sync_locked(conf):
    db_path = conf.get("db_path", "/etc/x-ui/x-ui.db")

    if not os.path.exists(db_path):
        logging.error(f"Database {db_path} does not exist. Please ensure 3X-UI is installed.")
        return

    conn = sqlite3.connect(db_path, timeout=30)
    cursor = conn.cursor()
    db_modified = False
    restart_xui = False

    # 1. Read Panel & Sub settings from 3X-UI
    cursor.execute("SELECT key, value FROM settings")
    settings = {k: (v if v is not None else "") for k, v in cursor.fetchall()}

    web_port = safe_int(settings.get("webPort"), conf["panel_internal_port"])
    sub_port = safe_int(settings.get("subPort"), conf["sub_internal_port"])
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

    # Subscription links must point at the public gateway. The internal subPort is
    # NOT overwritten with the public port (that made the engine flip-flop on every
    # run); instead the public URL is advertised through subDomain/subURI.
    if set_setting(cursor, settings, "subDomain", conf["domain"]):
        db_modified = True

    if "subURI" in settings:
        current_uri = settings["subURI"].strip()
        if not current_uri or current_uri.startswith(f"https://{conf['domain']}"):
            desired_uri = f"https://{conf['domain']}:{conf['sub_public_port']}{sub_path or '/sub/'}"
            if set_setting(cursor, settings, "subURI", desired_uri):
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

    # Moving the panel/sub listener only takes effect after x-ui restarts; without
    # the restart Nginx would proxy to a port nothing listens on (502).
    panel_internal_port = conf["panel_internal_port"]
    if web_port in reserved_public:
        set_setting(cursor, settings, "webPort", panel_internal_port)
        web_port = panel_internal_port
        db_modified = True
        restart_xui = True

    sub_internal_port = conf["sub_internal_port"]
    if sub_port in reserved_public:
        set_setting(cursor, settings, "subPort", sub_internal_port)
        sub_port = sub_internal_port
        db_modified = True
        restart_xui = True

    # 2. Inspect Inbounds
    cursor.execute("PRAGMA table_info(inbounds)")
    inbound_cols = [r[1] for r in cursor.fetchall()]
    has_node_id = "node_id" in inbound_cols

    if has_node_id:
        cursor.execute("SELECT id, port, listen, protocol, settings, stream_settings, remark, enable, node_id FROM inbounds")
    else:
        cursor.execute("SELECT id, port, listen, protocol, settings, stream_settings, remark, enable, 0 AS node_id FROM inbounds")
    inbounds = cursor.fetchall()

    proxied_http_inbounds = []
    reality_inbounds = []
    seen_paths = set()
    if web_base_path:
        seen_paths.add(web_base_path.rstrip("/"))
    if sub_path:
        seen_paths.add(sub_path.rstrip("/"))

    for row in inbounds:
        inbound_id, port, listen, protocol, settings_json, stream_json, remark, enable, node_id = row
        if not enable:
            continue

        # MULTI-NODE PROTECTION:
        # node_id > 0 means the inbound is hosted on a remote/external 3X-UI node.
        # We must NOT modify remote inbounds, bind them to 127.0.0.1, or route them in local Nginx.
        if node_id is not None and int(node_id) > 0:
            logging.info(f"Skipping remote node inbound #{inbound_id} (node_id={node_id})")
            continue

        try:
            stream = json.loads(stream_json) if stream_json else {}
        except Exception:
            stream = {}

        network = stream.get("network", "tcp")
        security = stream.get("security", "none")

        # Extract configured Host header & SNI from inbound stream settings
        inbound_host = extract_inbound_host_header(stream, conf["domain"])
        inbound_sni = extract_inbound_sni(stream, conf["domain"])

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
                "host_header": extract_inbound_host_header(stream, ""),
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
        if not isinstance(net_settings, dict):
            net_settings = {}
        current_path = str(net_settings.get(path_key) or "").strip()

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
            elif net_settings.get(path_key) != current_path:
                # Persist the normalized leading slash so Xray and Nginx agree on the path.
                net_settings[path_key] = current_path
                stream[net_key] = net_settings
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
            "host_header": inbound_host,
            "sni": inbound_sni,
            "ech_config": ech_config
        })

    # 3. Synchronize Modern 3X-UI "hosts" table
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='hosts'")
    if cursor.fetchone():
        now_ms = int(time.time() * 1000)

        cursor.execute("PRAGMA table_info(hosts)")
        host_table_cols = {col[1] for col in cursor.fetchall()}

        known_cols = ["id", "inbound_id", "address", "port", "security", "sni", "host_header", "path", "ech_config_list", "fingerprint"]
        selected_cols = [c for c in known_cols if c in host_table_cols]
        col_idx = {c: idx for idx, c in enumerate(selected_cols)}
        select_clause = ", ".join(selected_cols)

        def find_matching_host(existing_rows, target_domain, target_port, target_sec=None):
            """
            Find the matching gateway host record from a list of rows.
            Prevents overwriting secondary/custom endpoints (like CDNs or other nodes)
            while ensuring the local gateway record is accurately updated.
            """
            if not existing_rows:
                return None

            # 1. Exact match on target_domain and target_port
            for row in existing_rows:
                h_addr = row[col_idx["address"]] if "address" in col_idx else ""
                h_port = row[col_idx["port"]] if "port" in col_idx else 0
                h_sec = row[col_idx["security"]] if "security" in col_idx else ""
                if h_addr == target_domain and h_port == target_port:
                    if target_sec is None or h_sec == target_sec:
                        return row

            # 2. Match on target_domain (even if port changed in gateway config)
            for row in existing_rows:
                h_addr = row[col_idx["address"]] if "address" in col_idx else ""
                h_sec = row[col_idx["security"]] if "security" in col_idx else ""
                if h_addr == target_domain:
                    if target_sec is None or h_sec == target_sec:
                        return row

            # 3. For REALITY inbounds: Match on port and security == 'reality'
            if target_sec == "reality":
                for row in existing_rows:
                    h_port = row[col_idx["port"]] if "port" in col_idx else 0
                    h_sec = row[col_idx["security"]] if "security" in col_idx else ""
                    if h_port == target_port and h_sec == "reality":
                        return row

            # 4. Adopt unconfigured / blank template host
            for row in existing_rows:
                h_addr = row[col_idx["address"]] if "address" in col_idx else ""
                if not h_addr or h_addr.strip() == "":
                    return row

            # Any remaining rows belong to custom CDNs, alternative addresses, or other endpoints.
            # Do NOT overwrite them!
            return None

        # Sync HTTP-proxied inbounds into hosts
        for ib in proxied_http_inbounds:
            cursor.execute(f"SELECT {select_clause} FROM hosts WHERE inbound_id = ?", (ib["id"],))
            existing_rows = cursor.fetchall()

            matched = find_matching_host(existing_rows, conf["domain"], conf["inbounds_port"], "tls")

            desired_host = {
                "inbound_id": ib["id"],
                "sort_order": 0,
                "remark": ib["remark"],
                "server_description": "",
                "is_disabled": 0,
                "is_hidden": 0,
                "address": conf["domain"],
                "port": conf["inbounds_port"],
                "security": "tls",
                "sni": ib["sni"],
                "host_header": ib["host_header"],
                "path": ib["path"],
                "ech_config_list": ib["ech_config"],
            }
            if "node_id" in host_table_cols:
                desired_host["node_id"] = 0

            if matched:
                h_id = matched[col_idx["id"]]
                h_addr = matched[col_idx["address"]] if "address" in col_idx else ""
                h_port = matched[col_idx["port"]] if "port" in col_idx else 0
                h_sec = matched[col_idx["security"]] if "security" in col_idx else ""
                h_sni = matched[col_idx["sni"]] if "sni" in col_idx else ""
                h_host = matched[col_idx["host_header"]] if "host_header" in col_idx else ""
                h_path = matched[col_idx["path"]] if "path" in col_idx else ""
                h_ech = matched[col_idx["ech_config_list"]] if "ech_config_list" in col_idx else ""

                needs_update = (
                    h_addr != desired_host["address"] or
                    h_port != desired_host["port"] or
                    h_sec != desired_host["security"] or
                    h_sni != desired_host["sni"] or
                    h_host != desired_host["host_header"] or
                    h_path != desired_host["path"] or
                    (desired_host["ech_config_list"] and h_ech != desired_host["ech_config_list"])
                )

                if needs_update:
                    update_fields = {
                        "address": desired_host["address"],
                        "port": desired_host["port"],
                        "security": desired_host["security"],
                        "sni": desired_host["sni"],
                        "host_header": desired_host["host_header"],
                        "path": desired_host["path"],
                    }
                    if "ech_config_list" in host_table_cols and desired_host["ech_config_list"]:
                        update_fields["ech_config_list"] = desired_host["ech_config_list"]
                    if "updated_at" in host_table_cols:
                        update_fields["updated_at"] = now_ms

                    set_clause = ", ".join([f"{k} = ?" for k in update_fields.keys()])
                    cursor.execute(f"UPDATE hosts SET {set_clause} WHERE id = ?", list(update_fields.values()) + [h_id])
                    db_modified = True
            else:
                insert_cols = []
                insert_vals = []
                for k, v in desired_host.items():
                    if k in host_table_cols:
                        insert_cols.append(k)
                        insert_vals.append(v)
                if "created_at" in host_table_cols:
                    insert_cols.append("created_at")
                    insert_vals.append(now_ms)
                if "updated_at" in host_table_cols:
                    insert_cols.append("updated_at")
                    insert_vals.append(now_ms)

                placeholders = ", ".join(["?"] * len(insert_cols))
                cursor.execute(f"INSERT INTO hosts ({', '.join(insert_cols)}) VALUES ({placeholders})", insert_vals)
                db_modified = True

        # Sync REALITY inbounds into hosts (Preserving Reality security, SNI, Fingerprint, and ECH!)
        for r_ib in reality_inbounds:
            cursor.execute(f"SELECT {select_clause} FROM hosts WHERE inbound_id = ?", (r_ib["id"],))
            existing_rows = cursor.fetchall()

            matched = find_matching_host(existing_rows, conf["domain"], r_ib["port"], "reality")

            desired_reality_host = {
                "inbound_id": r_ib["id"],
                "sort_order": 0,
                "remark": r_ib["remark"],
                "server_description": "",
                "is_disabled": 0,
                "is_hidden": 0,
                "address": conf["domain"],
                "port": r_ib["port"],
                "security": "reality",
                "sni": r_ib["sni"],
                "host_header": r_ib.get("host_header", ""),
                "path": "",
                "ech_config_list": r_ib["ech_config"],
                "fingerprint": r_ib["fingerprint"],
            }
            if "node_id" in host_table_cols:
                desired_reality_host["node_id"] = 0

            if matched:
                h_id = matched[col_idx["id"]]
                h_addr = matched[col_idx["address"]] if "address" in col_idx else ""
                h_port = matched[col_idx["port"]] if "port" in col_idx else 0
                h_sec = matched[col_idx["security"]] if "security" in col_idx else ""
                h_sni = matched[col_idx["sni"]] if "sni" in col_idx else ""
                h_host = matched[col_idx["host_header"]] if "host_header" in col_idx else ""
                h_ech = matched[col_idx["ech_config_list"]] if "ech_config_list" in col_idx else ""
                h_fp = matched[col_idx["fingerprint"]] if "fingerprint" in col_idx else ""

                needs_update = (
                    h_port != desired_reality_host["port"] or
                    h_sec != "reality" or
                    h_sni != desired_reality_host["sni"] or
                    (desired_reality_host["fingerprint"] and h_fp != desired_reality_host["fingerprint"]) or
                    (desired_reality_host["ech_config_list"] and h_ech != desired_reality_host["ech_config_list"])
                )

                if needs_update:
                    update_fields = {
                        "port": desired_reality_host["port"],
                        "security": "reality",
                        "sni": desired_reality_host["sni"],
                    }
                    if "fingerprint" in host_table_cols:
                        update_fields["fingerprint"] = desired_reality_host["fingerprint"]
                    if "ech_config_list" in host_table_cols and desired_reality_host["ech_config_list"]:
                        update_fields["ech_config_list"] = desired_reality_host["ech_config_list"]
                    if "updated_at" in host_table_cols:
                        update_fields["updated_at"] = now_ms

                    set_clause = ", ".join([f"{k} = ?" for k in update_fields.keys()])
                    cursor.execute(f"UPDATE hosts SET {set_clause} WHERE id = ?", list(update_fields.values()) + [h_id])
                    db_modified = True
            else:
                insert_cols = []
                insert_vals = []
                for k, v in desired_reality_host.items():
                    if k in host_table_cols:
                        insert_cols.append(k)
                        insert_vals.append(v)
                if "created_at" in host_table_cols:
                    insert_cols.append("created_at")
                    insert_vals.append(now_ms)
                if "updated_at" in host_table_cols:
                    insert_cols.append("updated_at")
                    insert_vals.append(now_ms)

                placeholders = ", ".join(["?"] * len(insert_cols))
                cursor.execute(f"INSERT INTO hosts ({', '.join(insert_cols)}) VALUES ({placeholders})", insert_vals)
                db_modified = True

    if db_modified:
        conn.commit()
        logging.info("Database updated with inbounds, hosts, ECH parameters, and subscription settings.")
    else:
        logging.info("Database inbounds and hosts are up to date.")
    conn.close()

    if restart_xui and shutil.which("systemctl"):
        logging.info("Internal panel/subscription port changed; restarting x-ui to apply.")
        subprocess.run(["systemctl", "restart", "x-ui"], check=False)

    # 4. Generate Nginx Config (x-ui is only restarted above when its own listener moved)
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

    # Include custom inbound host headers in server_name so Nginx accepts and proxies them
    inbound_server_names = [domain]
    for ib in inbounds:
        h = ib.get("host_header", "")
        if h and h != domain and " " not in h and h not in inbound_server_names:
            inbound_server_names.append(h)
    inbounds_server_name_str = " ".join(inbound_server_names)

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
        f"    server_name {inbounds_server_name_str};",
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

    # The standalone "http2 on;" directive needs nginx >= 1.25.1; older versions
    # expect "listen ... ssl http2;".
    if not nginx_supports_http2_directive():
        conf_content = re.sub(r"(listen [^;\n]*\bssl)(;)", r"\1 http2\2", conf_content)
        conf_content = re.sub(r"^[ \t]*http2 on;\n", "", conf_content, flags=re.MULTILINE)

    previous = None
    if os.path.exists(conf_path):
        with open(conf_path, "r") as f:
            previous = f.read()
        # Check for diffs before writing
        if previous.strip() == conf_content.strip():
            logging.info("Nginx configuration is already identical. No reload needed.")
            return

    os.makedirs(os.path.dirname(conf_path), exist_ok=True)
    tmp_path = conf_path + ".tmp"
    with open(tmp_path, "w") as f:
        f.write(conf_content if conf_content.endswith("\n") else conf_content + "\n")
    os.replace(tmp_path, conf_path)

    if not shutil.which("nginx"):
        logging.info(f"Nginx configuration written to {conf_path} (nginx binary not in PATH).")
        return

    test = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
    if test.returncode == 0:
        if shutil.which("systemctl"):
            subprocess.run(["systemctl", "reload", "nginx"], check=False)
        logging.info("Nginx configuration updated and reloaded successfully.")
        return

    # Never leave an invalid file behind: a later nginx restart/boot would fail.
    logging.error(f"Nginx config validation failed:\n{test.stderr}")
    if previous is not None:
        with open(conf_path, "w") as f:
            f.write(previous)
        logging.error("Previous working configuration has been restored.")
    else:
        os.remove(conf_path)
        logging.error("The invalid generated configuration was removed.")
    sys.exit(1)

def nginx_supports_http2_directive():
    """True when nginx is >= 1.25.1 (or its version cannot be determined)."""
    if not shutil.which("nginx"):
        return True
    try:
        out = subprocess.run(["nginx", "-v"], capture_output=True, text=True).stderr
        m = re.search(r"nginx/(\d+)\.(\d+)\.(\d+)", out)
        if m:
            return tuple(int(x) for x in m.groups()) >= (1, 25, 1)
    except Exception:
        pass
    return True

if __name__ == "__main__":
    sync(force="--force" in sys.argv[1:])
