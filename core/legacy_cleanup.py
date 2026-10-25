#!/usr/bin/env python3
"""
Legacy-setup helper for 3XUI-Server-Starter-Pack.

Sub-commands
  detect-bot   Inspect an already installed xui-bot.service: where it listens and
               how it is exposed (nginx / cloudflared / direct / local).
               Prints machine-readable `key=value` lines.
  cleanup      After a successful install, retire old nginx files that only proxy
               the 3X-UI panel / subscription / bot (backed up, auto-rollback).
  cf-switch    Remove the bot's route from a Cloudflare tunnel config.
"""

import argparse
import datetime
import glob
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nginx_inspector as ni  # noqa: E402  (parser + colours + safe_input)

NGINX_DIRS = ["/etc/nginx/conf.d", "/etc/nginx/sites-enabled"]
PROXY_RE = re.compile(r"proxy_pass\s+\w+://(?:127\.0\.0\.1|localhost|\[::1\]|0\.0\.0\.0):(\d+)")
BOT_UNIT = "xui-bot.service"
SECRET_KEY_RE = re.compile(r"token|secret|pass|key|hash", re.I)


def out(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except Exception:
        return ""


def say_ok(msg):
    print(f"  {ni.GREEN}✔{ni.NC} {msg}")


def say_info(msg):
    print(f"  {ni.BLUE}●{ni.NC} {msg}")


def say_warn(msg):
    print(f"  {ni.YELLOW}▲{ni.NC} {msg}")


def say_err(msg):
    print(f"  {ni.RED}✖{ni.NC} {msg}")


# ------------------------------------------------------------------ nginx scan
def nginx_entries():
    """(entry_path, real_path) of every non-gateway nginx config file."""
    seen, res = set(), []
    for d in NGINX_DIRS:
        for entry in sorted(glob.glob(d + "/*")):
            if not os.path.isfile(entry) or entry.endswith("xui_proxy.conf"):
                continue
            real = os.path.realpath(entry)
            if real in seen or real.endswith("xui_proxy.conf"):
                continue
            seen.add(real)
            res.append((entry, real))
    return res


def only_server_blocks(path):
    """True if the file contains nothing but `server { ... }` blocks."""
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            toks = ni.tokenize_nginx(f.read())
    except OSError:
        return False
    i, n = 0, len(toks)
    while i < n:
        if toks[i] == "server" and i + 1 < n and toks[i + 1] == "{":
            depth, i = 1, i + 2
            while i < n and depth:
                depth += 1 if toks[i] == "{" else -1 if toks[i] == "}" else 0
                i += 1
        else:
            return False
    return True


def classify(real, kind_ports, domain=""):
    """
    kind_ports: {"panel": set, "sub": set, "bot": set}
    Returns dict(kinds=set, listens=[ports], names=[...], dedicated=bool, touches=bool)
    A file is `dedicated` when every server block in it only proxies one of the
    known local services (or is a port-80 redirect) so it can be retired whole.
    """
    servers = ni.parse_nginx_file(real)
    res = {"kinds": set(), "listens": [], "names": [], "dedicated": False, "touches": False}
    if not servers:
        return res
    dedicated = only_server_blocks(real)
    proxied = 0
    for s in servers:
        targets = set()
        all_local = bool(s["locations"])
        for loc in s["locations"].values():
            ports = {int(p) for p in PROXY_RE.findall(loc["raw"])}
            if not ports:
                all_local = False
            targets |= ports
        known = set()
        for kind, ports in kind_ports.items():
            if targets & ports:
                known.add(kind)
        known_ports = set().union(*kind_ports.values()) if kind_ports else set()
        if known:
            res["touches"] = True
            res["kinds"] |= known
            res["listens"] += [p for p in s["ports"] if p != 80]
            res["names"] += s["server_names"]
        if all_local and known and targets <= known_ports:
            proxied += 1
        elif not s["locations"] and set(s["ports"]) <= {80}:
            pass  # plain port-80 redirect block
        else:
            dedicated = False
    if proxied == 0:
        dedicated = False
    if "bot" in res["kinds"] and domain:
        names = [n for n in res["names"] if n not in ("_", "")]
        if names and domain.lower() not in names:
            dedicated = False  # belongs to some other domain: do not touch
    res["dedicated"] = dedicated
    return res


# --------------------------------------------------------------------- bot scan
def descendants(pid):
    rows = out(["ps", "-eo", "pid=,ppid="]).split()
    pairs = list(zip(rows[0::2], rows[1::2]))
    found, todo = {str(pid)}, [str(pid)]
    while todo:
        cur = todo.pop()
        for p, pp in pairs:
            if pp == cur and p not in found:
                found.add(p)
                todo.append(p)
    return found


def listening_for(pids):
    res = []
    for line in out(["ss", "-H", "-tlnp"]).splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        found = set(re.findall(r"pid=(\d+)", line))
        if found & pids:
            addr, _, port = parts[3].rpartition(":")
            if port.isdigit():
                res.append((addr.strip("[]"), int(port)))
    return res


def config_hints(workdir):
    hints, ports = [], []
    if not workdir or not os.path.isdir(workdir):
        return hints, ports
    names = [".env"] + [os.path.basename(p) for p in glob.glob(os.path.join(workdir, "*.env"))]
    for pat in ("config.*", "settings.*", "docker-compose*.y*ml"):
        names += [os.path.basename(p) for p in glob.glob(os.path.join(workdir, pat))]
    key_re = re.compile(r"^\s*([\w.\-]*(?:port|host|domain|url|webhook|tunnel|cloudflare)[\w.\-]*)\s*[=:]\s*(.*)$", re.I)
    for name in dict.fromkeys(names):
        path = os.path.join(workdir, name)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                text = f.read(65536)
        except OSError:
            continue
        for line in text.splitlines():
            m = key_re.match(line)
            if not m:
                continue
            key, val = m.group(1), m.group(2).strip().strip("'\"")
            if SECRET_KEY_RE.search(key):
                val = "***"
            if "port" in key.lower() and val.isdigit():
                ports.append(int(val))
            if len(hints) < 15:
                hints.append(f"{name}: {key}={val}")
    return hints, ports


def cloudflared_info(port):
    units = [l.split()[0] for l in out(["systemctl", "list-units", "--all", "--no-legend", "--plain", "cloudflared*"]).splitlines() if l.strip()]
    active = any(out(["systemctl", "is-active", u]).strip() == "active" for u in units) or bool(out(["pgrep", "-x", "cloudflared"]).strip())
    port_re = re.compile(rf"(?:localhost|127\.0\.0\.1|\[::1\]):{port}\b")
    cfg_paths = ["/etc/cloudflared/config.yml", "/etc/cloudflared/config.yaml",
                 os.path.expanduser("~/.cloudflared/config.yml"), "/root/.cloudflared/config.yml"]
    info = {"active": active, "unit": "", "config": "", "matched": False}
    for p in dict.fromkeys(cfg_paths):
        try:
            if os.path.isfile(p) and port_re.search(open(p, encoding="utf-8", errors="ignore").read()):
                info.update(config=p, matched=True)
                break
        except OSError:
            pass
    for u in units:
        text = out(["systemctl", "cat", u])
        if port_re.search(text):
            info.update(unit=u, matched=True)
            break
    if not info["unit"] and units:
        info["unit"] = units[0]
    return info


def cmd_detect_bot(_args):
    show = {}
    for line in out(["systemctl", "show", BOT_UNIT, "--no-pager",
                     "-p", "LoadState", "-p", "ActiveState", "-p", "MainPID",
                     "-p", "WorkingDirectory", "-p", "ExecStart"]).splitlines():
        k, _, v = line.partition("=")
        show[k] = v
    if show.get("LoadState", "not-found") != "loaded":
        print("installed=false")
        return 0

    state = show.get("ActiveState", "unknown")
    workdir = show.get("WorkingDirectory", "").lstrip("!-")
    if not workdir or not os.path.isdir(workdir):
        workdir = "/root/3XUI-Shop-Bot" if os.path.isdir("/root/3XUI-Shop-Bot") else ""
    pid = show.get("MainPID", "0")
    pids = descendants(pid) if pid.isdigit() and pid != "0" else set()
    listens = listening_for(pids)
    hints, hint_ports = config_hints(workdir)

    port = 0
    listening_ports = [p for _, p in listens]
    for hp in hint_ports:
        if hp in listening_ports:
            port = hp
            break
    if not port and listening_ports:
        port = listening_ports[0]
    if not port:
        for hp in hint_ports:
            if hp > 1024:
                port = hp
                break

    exposure, nginx_info = "local", None
    if port:
        for entry, real in nginx_entries():
            cl = classify(real, {"bot": {port}})
            if cl["touches"]:
                nginx_info = (entry, cl)
                break
        cf = cloudflared_info(port)
        public_bind = any(p == port and a in ("0.0.0.0", "*", "::", "") for a, p in listens)
        if nginx_info:
            exposure = "nginx"
        elif cf["matched"]:
            exposure = "cloudflared"
        elif cf["active"]:
            exposure = "cloudflared-remote"  # token-managed tunnel: routes live in the dashboard
        elif public_bind:
            exposure = "direct"

    print("installed=true")
    print(f"state={state}")
    print(f"dir={workdir}")
    print(f"port={port or ''}")
    print(f"exposure={exposure}")
    if nginx_info:
        entry, cl = nginx_info
        print(f"nginx_file={entry}")
        print(f"nginx_listen={cl['listens'][0] if cl['listens'] else ''}")
        print(f"nginx_names={','.join(dict.fromkeys(cl['names']))}")
        print(f"nginx_dedicated={'true' if cl['dedicated'] else 'false'}")
    if port and exposure.startswith("cloudflared"):
        print(f"cf_config={cf['config']}")
        print(f"cf_unit={cf['unit']}")
    for h in hints:
        print(f"hint={h}")
    return 0


# ------------------------------------------------------------------- cleanup
def nums(csv):
    return {int(x) for x in (csv or "").split(",") if x.strip().isdigit()}


def run_sync(script):
    return subprocess.run(["python3", script, "--force"]).returncode == 0


def nginx_ok():
    return subprocess.run(["nginx", "-t"], capture_output=True).returncode == 0


def cmd_cleanup(args):
    kind_ports = {"panel": nums(args.panel_ports), "sub": nums(args.sub_ports), "bot": nums(args.bot_ports)}
    kind_ports = {k: v for k, v in kind_ports.items() if v}
    if not kind_ports:
        say_info("No legacy ports known; nothing to clean up.")
        return 0

    cands, manual = [], []
    for entry, real in nginx_entries():
        cl = classify(real, kind_ports, args.domain)
        if cl["dedicated"]:
            cands.append((entry, cl))
        elif cl["touches"]:
            manual.append(entry)

    for m in manual:
        say_warn(f"{m} mixes other sites with 3X-UI/bot routes; left untouched (review manually).")
    if not cands:
        say_ok("No old nginx configuration for 3X-UI / bot found.")
        return 0

    say_info("Old nginx configuration now replaced by the gateway:")
    for entry, cl in cands:
        print(f"      {ni.CYAN}{entry}{ni.NC}  ({', '.join(sorted(cl['kinds']))})")

    preset = os.environ.get("XUI_RETIRE_LEGACY", "")
    ans = preset or ni.safe_input("  ? Back them up and remove them now? [Y/n]: ", "y")
    if ans.strip().lower() not in ("y", "yes", "true", "1"):
        say_info("Keeping old configuration files.")
        return 0

    backup = args.backup_dir or "/etc/nginx/backup_legacy_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    os.makedirs(backup, exist_ok=True)
    with open(args.config, "r", encoding="utf-8") as f:
        original_conf = f.read()
    conf = json.loads(original_conf)

    moved = []
    for entry, cl in cands:
        dst = os.path.join(backup, os.path.basename(entry))
        shutil.move(entry, dst)
        moved.append((entry, dst))
        if "panel" in cl["kinds"]:
            conf["skip_panel_proxy"] = False
        if "sub" in cl["kinds"]:
            conf["skip_sub_proxy"] = False
        if "bot" in cl["kinds"]:
            conf["skip_bot_proxy"] = False
    with open(args.config, "w", encoding="utf-8") as f:
        json.dump(conf, f, indent=2)

    success = run_sync(args.sync_script) and nginx_ok()
    if success:
        subprocess.run(["systemctl", "reload", "nginx"], check=False)
        say_ok(f"Old configuration retired (backup: {backup}); gateway now serves those routes.")
        return 0

    say_err("Gateway validation failed after removal; restoring previous configuration.")
    for entry, dst in moved:
        shutil.move(dst, entry)
    with open(args.config, "w", encoding="utf-8") as f:
        f.write(original_conf)
    run_sync(args.sync_script)
    subprocess.run(["systemctl", "reload", "nginx"], check=False)
    return 1


# -------------------------------------------------------------- cloudflared
def cmd_cf_switch(args):
    port_re = re.compile(rf"(?:localhost|127\.0\.0\.1|\[::1\]):{args.port}\b")
    changed = False
    if args.config and os.path.isfile(args.config):
        with open(args.config, "r", encoding="utf-8") as f:
            lines = f.read().splitlines(keepends=True)
        start = next((i for i, l in enumerate(lines) if re.match(r"^\s*ingress\s*:", l)), None)
        if start is not None:
            entry_re = re.compile(r"^(\s*)-\s")
            first = next((i for i in range(start + 1, len(lines)) if entry_re.match(lines[i])), None)
            if first is not None:
                indent = entry_re.match(lines[first]).group(1)
                groups, cur = [], None
                tail_start = len(lines)
                for i in range(first, len(lines)):
                    m = entry_re.match(lines[i])
                    if m and m.group(1) == indent:
                        cur = [i]
                        groups.append(cur)
                    elif lines[i].strip() and not lines[i].startswith(indent + " ") and not lines[i].startswith(indent + "\t"):
                        tail_start = i
                        break
                    elif cur is not None:
                        cur.append(i)
                drop = set()
                for g in groups:
                    if any(port_re.search(lines[i]) for i in g):
                        drop.update(g)
                if drop:
                    backup = args.config + ".bak-" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
                    shutil.copy2(args.config, backup)
                    with open(args.config, "w", encoding="utf-8") as f:
                        f.writelines(l for i, l in enumerate(lines) if i not in drop)
                    say_ok(f"Removed the bot route from {args.config} (backup: {backup})")
                    changed = True
        if changed and args.unit:
            subprocess.run(["systemctl", "restart", args.unit], check=False)
            say_ok(f"Restarted {args.unit}")
    elif args.unit:
        text = out(["systemctl", "cat", args.unit])
        if port_re.search(text) and "--url" in text:
            subprocess.run(["systemctl", "disable", "--now", args.unit], check=False)
            say_ok(f"Stopped and disabled quick-tunnel unit {args.unit}")
            changed = True

    if not changed:
        say_warn("No local tunnel route could be edited automatically (remote-managed tunnel?).")
        say_warn("Remove the bot's public hostname in the Cloudflare Zero Trust dashboard,")
        say_warn("or leave it: the gateway also serves the bot on its own port.")
    say_warn("Update any public URL stored in the bot's own config (webhook/base URL) to the new gateway address.")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("detect-bot")
    c = sub.add_parser("cleanup")
    c.add_argument("--config", default="/etc/x-ui/nginx_proxy.json")
    c.add_argument("--domain", default="")
    c.add_argument("--panel-ports", default="")
    c.add_argument("--sub-ports", default="")
    c.add_argument("--bot-ports", default="")
    c.add_argument("--backup-dir", default="")
    c.add_argument("--sync-script", default="/usr/local/bin/xui-nginx-sync.py")
    f = sub.add_parser("cf-switch")
    f.add_argument("--config", default="")
    f.add_argument("--unit", default="")
    f.add_argument("--port", type=int, required=True)
    args = ap.parse_args()
    sys.exit({"detect-bot": cmd_detect_bot, "cleanup": cmd_cleanup, "cf-switch": cmd_cf_switch}[args.cmd](args))


if __name__ == "__main__":
    main()
