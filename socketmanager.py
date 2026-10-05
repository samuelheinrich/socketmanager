#!/usr/bin/env python3
"""
socketmanager - TUI overview of locally listening (web)servers.

Shows every listening TCP socket you own, the process behind it, the project it
was started from, and lets you stop one, a whole process tree, or a marked batch.

  ./socketmanager.py                 TUI
  ./socketmanager.py -l / --json     list once
  ./socketmanager.py --watch         notify whenever a new server appears
  ./socketmanager.py --stop 8777     free a port without the TUI
"""

import argparse
import curses
import functools
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

REFRESH_SECONDS = 3.0
PROBE_TTL = 30.0
PROBE_TIMEOUT = 0.4
KILL_LOG = os.path.expanduser("~/.local/state/socketmanager.log")

DEV_CMD_RE = re.compile(
    r"(node|npm|npx|pnpm|yarn|bun|deno|vite|next|nuxt|webpack|esbuild|parcel|"
    r"python|python3|uvicorn|gunicorn|hypercorn|daphne|flask|django|fastapi|streamlit|"
    r"ruby|rails|puma|php|caddy|nginx|httpd|http-server|live-server|serve|"
    r"go|air|dotnet|java|jekyll|hugo|storybook|ng |rustc|cargo|miniserve|dart|flutter)",
    re.I,
)
WEB_PORTS = {80, 443, 1313, 3000, 4200, 4321, 5000, 5173, 5174, 7777, 8080, 8081, 8888, 9000}
NOISE_CMD_RE = re.compile(
    r"(rapportd|onedrive|dropbox|google ?drive|spotify|steam|sharingd|"
    r"controlcenter|airplay|mysqld|postgres|redis-server|mongod|com\.apple)",
    re.I,
)
# parents that merely supervise a dev server and would respawn it if left alive
SUPERVISOR_RE = re.compile(
    r"^(npm|npx|yarn|pnpm|bun|nodemon|concurrently|foreman|honcho|air|watchexec|"
    r"watchman|make|task|just|sh|bash|zsh|fish|python|python3|node)\b", re.I)
# never signal these directly - the container has to be stopped instead
DOCKER_PROC_RE = re.compile(r"(com\.docker|docker-proxy|dockerd|colima|vpnkit|containerd)", re.I)

V4_ANY = ("127.0.0.1", "*", "0.0.0.0")
V6_ANY = ("::1", "::", "[::]")
LOOPBACK = V4_ANY + V6_ANY
PUBLIC_ADDRS = ("*", "0.0.0.0", "::", "[::]")

# claude code scratchpads live here; the dir name encodes the originating project
SCRATCH_RE = re.compile(r"/claude-\d+/(?P<mangled>[^/]+)/")


# ---------------------------------------------------------------- helpers


def etime_seconds(text):
    """ps etime ('12-18:14:49', '21:26:16', '03:41') -> seconds."""
    if not text or text == "-":
        return 0
    days, _, rest = text.partition("-")
    if not rest:
        days, rest = "0", days
    try:
        parts = [int(x) for x in rest.split(":")]
    except ValueError:
        return 0
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, s = parts[-3:]
    return int(days or 0) * 86400 + h * 3600 + m * 60 + s


def fmt_uptime(seconds):
    if seconds <= 0:
        return "-"
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m, s = divmod(rem, 60)
    if d:
        return f"{d}d{h:02d}h"
    if h:
        return f"{h}h{m:02d}m"
    return f"{m}m{s:02d}s"


def parse_duration(text):
    """'90', '30s', '15m', '2h', '3d' -> seconds."""
    m = re.fullmatch(r"(\d+)\s*([smhd]?)", text.strip(), re.I)
    if not m:
        raise argparse.ArgumentTypeError(f"cannot read duration {text!r} (use 30m, 2h, 3d)")
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2).lower()]


@functools.lru_cache(maxsize=512)
def git_root(path):
    """nearest ancestor holding a .git - the project a server was started from."""
    cur = path
    for _ in range(10):
        if not cur or cur == "/":
            return ""
        try:
            if os.path.exists(os.path.join(cur, ".git")):
                return cur
        except OSError:
            return ""
        parent = os.path.dirname(cur)
        if parent == cur:
            return ""
        cur = parent
    return ""


@functools.lru_cache(maxsize=512)
def project_of(cwd):
    """(label, origin) for a working directory."""
    if not cwd or cwd == "/":
        return "", ""
    # the innermost claude-* dir wins: scratchpads can be nested inside each other
    scratch = None
    for scratch in SCRATCH_RE.finditer(cwd):
        pass
    scratch_note = ""
    if scratch:
        # the mangled dir is the agent's project path with every separator as '-'
        tail = "-".join(scratch.group("mangled").strip("-").split("-")[-4:])
        scratch_note = f"agent scratchpad · {tail}"

    # a repo is the stronger signal - it names the project even inside a scratchpad
    root = git_root(cwd)
    if root:
        sub = os.path.relpath(cwd, root)
        origin = "git repo" + ("" if sub == "." else f" · subdir {sub}")
        return os.path.basename(root), origin + (f" · {scratch_note}" if scratch_note else "")
    if scratch_note:
        return os.path.basename(cwd.rstrip("/")), scratch_note
    return os.path.basename(cwd.rstrip("/")), ""


def log_kill(text):
    try:
        os.makedirs(os.path.dirname(KILL_LOG), exist_ok=True)
        with open(KILL_LOG, "a") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {text}\n")
    except OSError:
        pass


def open_url(url):
    cmd = ["open", url] if sys.platform == "darwin" else ["xdg-open", url]
    if not shutil.which(cmd[0]):
        return False, f"no {cmd[0]} available"
    subprocess.run(cmd, capture_output=True)
    return True, f"opened {url}"


def copy_text(text):
    for cmd in (["pbcopy"], ["wl-copy"], ["xclip", "-selection", "clipboard"], ["xsel", "-ib"]):
        if shutil.which(cmd[0]):
            try:
                subprocess.run(cmd, input=text.encode(), check=True)
                return True, f"copied {text}"
            except subprocess.SubprocessError as exc:
                return False, f"copy failed: {exc}"
    return False, "no clipboard tool found"


def desktop_notify(title, text):
    if sys.platform == "darwin" and shutil.which("osascript"):
        script = f'display notification {json.dumps(text)} with title {json.dumps(title)}'
        subprocess.run(["osascript", "-e", script], capture_output=True)
    elif shutil.which("notify-send"):
        subprocess.run(["notify-send", title, text], capture_output=True)


# ---------------------------------------------------------------- data model


class Proc:
    INTERPRETERS = ("node", "python", "python3", "ruby", "php", "bun", "deno",
                    "sh", "bash", "zsh", "java", "perl")

    def __init__(self, pid, ppid, etime, user, args):
        self.pid, self.ppid, self.user = pid, ppid, user
        self.etime = etime
        # ps escapes newlines as \012 - collapse so names stay printable
        self.args = " ".join(args.replace("\\012", " ").split())

    @property
    def uptime(self):
        return etime_seconds(self.etime)

    @property
    def short(self):
        toks = self.args.split()
        if not toks:
            return "?"
        base = os.path.basename(toks[0])
        if base.lower().rstrip("0123456789.") in self.INTERPRETERS or base.lower() in self.INTERPRETERS:
            name = base.lower()
            rest = toks[1:]
            for i, tok in enumerate(rest):
                if tok == "-m" and i + 1 < len(rest):
                    return f"{name} {rest[i + 1]}"
                if tok == "-c":
                    return f"{name} -c"
                if not tok.startswith("-"):
                    return f"{name} {os.path.basename(tok)}"
            return name
        return base


class Entry:
    def __init__(self, pid, port, addrs, proc, cwd="", container=""):
        self.pid = pid
        self.port = port
        self.addrs = addrs          # ['127.0.0.1'] / ['*'] / ['::1']
        self.proc = proc
        self.cwd = cwd
        self.container = container  # docker container name, if this port is published
        self.probe = None
        self.project, self.origin = project_of(cwd)
        if container:
            self.project = self.project or container
            self.origin = f"docker container {container}"

    @property
    def key(self):
        return (self.pid, self.port)

    @property
    def host(self):
        """the address this server is actually reachable on."""
        if any(a in V4_ANY for a in self.addrs):
            return "127.0.0.1"
        if any(a in V6_ANY for a in self.addrs):
            return "::1"
        return self.addrs[0]

    @property
    def scheme(self):
        if self.probe and self.probe.get("scheme"):
            return self.probe["scheme"]
        return "https" if self.port == 443 else "http"

    @property
    def url(self):
        host = f"[{self.host}]" if ":" in self.host else self.host
        return f"{self.scheme}://{host}:{self.port}/"

    @property
    def public(self):
        return any(a in PUBLIC_ADDRS for a in self.addrs)

    @property
    def uptime(self):
        return self.proc.uptime if self.proc else 0

    def name(self):
        return self.container and f"docker {self.container}" or (self.proc.short if self.proc else "?")

    def is_docker(self):
        return bool(self.container) or bool(self.proc and DOCKER_PROC_RE.search(self.proc.args))

    def is_web(self):
        if not any(a in LOOPBACK for a in self.addrs):
            return False
        if self.probe and self.probe.get("kind") == "http":
            return True
        if self.container:
            return True
        cmd = self.proc.args if self.proc else ""
        if NOISE_CMD_RE.search(cmd):
            return False
        if self.port in WEB_PORTS or 3000 <= self.port <= 3100 or 8000 <= self.port <= 8999:
            return True
        return bool(DEV_CMD_RE.search(cmd))

    def haystack(self):
        return " ".join([
            str(self.port), str(self.pid), self.name(), self.project, self.cwd,
            self.proc.args if self.proc else "",
            (self.probe or {}).get("title", ""), (self.probe or {}).get("server", ""),
        ]).lower()


# ---------------------------------------------------------------- collection


def ps_table():
    """pid -> Proc for every process we can see."""
    out = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,etime=,user=,command="],
        capture_output=True, text=True,
    ).stdout
    procs = {}
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        pid, ppid, etime, user, args = parts
        try:
            procs[int(pid)] = Proc(int(pid), int(ppid), etime, user, args)
        except ValueError:
            pass
    return procs


def listening_sockets():
    """[(pid, port, addr)] for all listening TCP sockets visible to us."""
    try:
        out = subprocess.run(
            ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"],
            capture_output=True, text=True,
        ).stdout
    except FileNotFoundError:
        return []
    rows, pid = [], None
    for line in out.splitlines():
        tag, val = line[:1], line[1:]
        if tag == "p":
            pid = int(val)
        elif tag == "n" and pid is not None:
            host, _, port = val.rpartition(":")
            try:
                rows.append((pid, int(port), host.strip("[]") or "*"))
            except ValueError:
                pass
    return rows


def cwds(pids):
    """pid -> current working directory, in a single lsof call."""
    if not pids:
        return {}
    try:
        out = subprocess.run(
            ["lsof", "-a", "-d", "cwd", "-p", ",".join(str(p) for p in pids), "-F", "pn"],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return {}
    result, pid = {}, None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid is not None:
            result.setdefault(pid, line[1:])
    return result


_docker_cache = {"ts": 0.0, "map": {}}


def docker_ports():
    """published host port -> container name (cached, only called when needed)."""
    if time.time() - _docker_cache["ts"] < 30:
        return _docker_cache["map"]
    mapping = {}
    if shutil.which("docker"):
        try:
            out = subprocess.run(
                ["docker", "ps", "--format", "{{.Names}}\t{{.Ports}}"],
                capture_output=True, text=True, timeout=2,
            ).stdout
            for line in out.splitlines():
                name, _, ports = line.partition("\t")
                for hit in re.finditer(r":(\d+)->", ports):
                    mapping[int(hit.group(1))] = name
        except Exception:
            pass
    _docker_cache.update(ts=time.time(), map=mapping)
    return mapping


def collect():
    procs = ps_table()
    grouped = {}
    for pid, port, addr in listening_sockets():
        grouped.setdefault((pid, port), []).append(addr)
    dirs = cwds({pid for pid, _ in grouped})

    needs_docker = any(
        procs.get(pid) and DOCKER_PROC_RE.search(procs[pid].args) for pid, _ in grouped
    )
    containers = docker_ports() if needs_docker else {}

    entries = [
        Entry(pid, port, sorted(set(addrs)), procs.get(pid), dirs.get(pid, ""),
              containers.get(port, "") if needs_docker else "")
        for (pid, port), addrs in grouped.items()
    ]
    entries.sort(key=lambda e: (e.port, e.pid))
    return entries, procs


def ancestors(proc, procs, limit=6):
    chain, seen = [], set()
    cur = proc
    while cur and cur.ppid > 1 and cur.ppid not in seen and len(chain) < limit:
        seen.add(cur.ppid)
        cur = procs.get(cur.ppid)
        if cur:
            chain.append(cur)
    return chain


def own_chain(procs):
    """pids we must never signal: ourselves and everything that launched us."""
    forbidden, pid, depth = {0, 1, os.getpid()}, os.getpid(), 0
    while pid in procs and depth < 30:
        forbidden.add(pid)
        pid = procs[pid].ppid
        depth += 1
    forbidden.add(pid)
    return forbidden


def children_of(pid, procs):
    kids = [p.pid for p in procs.values() if p.ppid == pid]
    out = list(kids)
    for k in kids:
        out.extend(children_of(k, procs))
    return out


class Collector(threading.Thread):
    """runs lsof/ps off the ui thread so a slow filesystem never freezes input."""

    daemon = True

    def __init__(self, interval=REFRESH_SECONDS):
        super().__init__()
        self.interval = interval
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.entries, self.procs, self.generation, self.error = [], {}, 0, ""

    def run(self):
        while True:
            try:
                entries, procs = collect()
                with self.lock:
                    self.entries, self.procs, self.error = entries, procs, ""
                    self.generation += 1
            except Exception as exc:                      # keep the ui alive
                with self.lock:
                    self.error = f"{type(exc).__name__}: {exc}"
                    self.generation += 1
            self.wake.wait(self.interval)
            self.wake.clear()

    def snapshot(self):
        with self.lock:
            return self.entries, self.procs, self.generation, self.error

    def refresh(self, wait=0.0):
        before = self.generation
        self.wake.set()
        deadline = time.time() + wait
        while wait and self.generation == before and time.time() < deadline:
            time.sleep(0.03)


# ---------------------------------------------------------------- http probe


def probe_http(host, port):
    """Cheap 'is this an http server' check: one GET / with a short timeout."""
    res = {"kind": "tcp", "scheme": "http", "status": "", "server": "", "title": "", "ts": time.time()}
    hostname = f"[{host}]" if ":" in host else host
    try:
        with socket.create_connection((host, port), PROBE_TIMEOUT) as s:
            s.settimeout(PROBE_TIMEOUT)
            s.sendall(
                f"GET / HTTP/1.1\r\nHost: {hostname}:{port}\r\n"
                "User-Agent: socketmanager\r\nConnection: close\r\nAccept: */*\r\n\r\n".encode()
            )
            data = b""
            while len(data) < 4096:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
    except Exception:
        res["kind"] = "closed"
        return res
    if data[:1] in (b"\x15", b"\x16"):          # TLS alert / handshake
        res.update(kind="https", scheme="https")
        return res
    text = data.decode("utf-8", "replace")
    if text.startswith("HTTP/"):
        res["kind"] = "http"
        res["status"] = text.split(" ", 2)[1] if " " in text else ""
        m = re.search(r"^server:\s*(.+)$", text, re.I | re.M)
        if m:
            res["server"] = m.group(1).strip()[:40]
        m = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
        if m:
            res["title"] = re.sub(r"\s+", " ", m.group(1)).strip()[:60]
    return res


class Prober:
    def __init__(self, enabled=True):
        self.cache, self.lock = {}, threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=12)
        self.pending = set()
        self.enabled = enabled

    def get(self, host, port):
        key = (host, port)
        with self.lock:
            hit = self.cache.get(key)
            if hit and time.time() - hit["ts"] < PROBE_TTL:
                return hit
            if not self.enabled or key in self.pending:
                return hit
            self.pending.add(key)
        self.pool.submit(self._run, key)
        return hit

    def _run(self, key):
        try:
            res = probe_http(*key)
        except Exception:
            res = None
        with self.lock:
            self.pending.discard(key)
            if res:
                self.cache[key] = res

    def clear(self):
        with self.lock:
            self.cache.clear()


# ---------------------------------------------------------------- stopping


def stop_pid(pid, sig=signal.SIGTERM):
    try:
        os.kill(pid, sig)
        return True, f"sent {sig.name} to {pid}"
    except ProcessLookupError:
        return False, f"pid {pid} is already gone"
    except PermissionError:
        return False, f"no permission to signal {pid} (try sudo)"
    except Exception as exc:
        return False, str(exc)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_container(name):
    try:
        out = subprocess.run(["docker", "stop", name], capture_output=True, text=True, timeout=30)
        if out.returncode == 0:
            return True, f"docker stop {name}"
        return False, (out.stderr or out.stdout).strip()[:120]
    except Exception as exc:
        return False, str(exc)


def stop_entry(entry, grace=2.0):
    """stop one entry the right way; returns (ok, message)."""
    if entry.container:
        ok, info = stop_container(entry.container)
    else:
        ok, info = stop_pid(entry.pid, signal.SIGTERM)
        if ok:
            deadline = time.time() + grace
            while time.time() < deadline and alive(entry.pid):
                time.sleep(0.1)
            if alive(entry.pid):
                ok, info = stop_pid(entry.pid, signal.SIGKILL)
                info += " (escalated)"
    log_kill(f"{'ok ' if ok else 'FAIL'} port {entry.port} pid {entry.pid} "
             f"{entry.name()} [{entry.project}] {info}")
    return ok, info


# ---------------------------------------------------------------- tui


def put(scr, y, x, text, attr=curses.A_NORMAL, width=None):
    """addnstr that never blows up on the last cell / a too-small window."""
    h, w = scr.getmaxyx()
    if y < 0 or y >= h or x >= w:
        return
    room = w - x - (1 if y == h - 1 else 0)
    if width is not None:
        room = min(room, width)
    if room <= 0:
        return
    try:
        scr.addnstr(y, x, text, room, attr)
    except curses.error:
        pass


SORTS = [
    ("port", lambda e: (e.port, e.pid)),
    ("uptime", lambda e: (-e.uptime, e.port)),
    ("project", lambda e: ((e.project or "~").lower(), e.port)),
    ("process", lambda e: (e.name().lower(), e.port)),
]

HELP = [
    "navigate      ↑ ↓ / j k      PgUp PgDn      Home End",
    "open / copy   ⏎ open in browser             c copy url",
    "stop          s stop (TERM→KILL)            K force kill",
    "              t stop process tree (incl. supervisor parent)",
    "mark          space toggle    v mark all shown    m mark same project",
    "              u unmark all    S stop everything marked",
    "view          a all sockets / web only      o cycle sort order",
    "              / search        p http probe on/off    r refresh now",
    "quit          q                             ? close this help",
    "",
    "colors: green = answers http · yellow = reachable from the network",
    f"every stop is appended to {KILL_LOG}",
]


class App:
    def __init__(self, stdscr, web_only=True, probe=True):
        self.scr = stdscr
        self.web_only = web_only
        self.prober = Prober(probe)
        self.collector = Collector()
        self.collector.start()
        self.sel = self.top = 0
        self.sort = 0
        self.query = ""
        self.marked = set()
        self.show_help = False
        self.msg, self.msg_ts = "", 0.0
        self.entries, self.all_entries, self.procs = [], [], {}
        self.generation = -1
        self.error = ""
        for _ in range(60):                       # wait briefly for the first scan
            if self.collector.generation:
                break
            time.sleep(0.05)
        self.adopt()

    # -- data
    def adopt(self, force=False):
        entries, procs, generation, error = self.collector.snapshot()
        if generation == self.generation and not force:
            return
        self.generation, self.error = generation, error
        self.all_entries, self.procs = entries, procs
        for e in self.all_entries:
            e.probe = self.prober.get(e.host, e.port)
        live = {e.key for e in self.all_entries}
        self.marked &= live                       # drop marks for vanished servers
        self.apply_filter()

    def apply_filter(self):
        keep = self.current().key if self.current() else None
        rows = self.all_entries if not self.web_only else [e for e in self.all_entries if e.is_web()]
        if self.query:
            needle = self.query.lower()
            rows = [e for e in rows if needle in e.haystack()]
        rows.sort(key=SORTS[self.sort][1])
        self.entries = rows
        if keep:
            for i, e in enumerate(self.entries):
                if e.key == keep:
                    self.sel = i
                    break
        self.sel = max(0, min(self.sel, len(self.entries) - 1))

    def current(self):
        return self.entries[self.sel] if 0 <= self.sel < len(self.entries) else None

    def marked_entries(self):
        return [e for e in self.entries if e.key in self.marked]

    def notify(self, text):
        self.msg, self.msg_ts = text, time.time()

    # -- drawing
    def draw(self):
        scr = self.scr
        scr.erase()
        h, w = scr.getmaxyx()
        if self.show_help:
            self.draw_help(h, w)
            scr.refresh()
            return

        detail_h = 7 if h > 16 else 0
        list_h = max(1, h - 3 - detail_h - 1)
        wide = w >= 104

        hidden = len(self.all_entries) - len(self.entries)
        mode = "web servers" if self.web_only else "listening sockets"
        head = f" socketmanager · {len(self.entries)} {mode} · sort {SORTS[self.sort][0]}"
        if self.query:
            head += f" · filter '{self.query}'"
        if self.marked:
            head += f" · {len(self.marked)} marked"
        if hidden > 0:
            head += f" · {hidden} hidden (a)"
        if not self.prober.enabled:
            head += " · probe off"
        if self.error:
            head += f" · scan error: {self.error}"
        put(scr, 0, 0, head.ljust(w), curses.color_pair(1) | curses.A_BOLD)

        cols = (f"   {'PORT':>5}  {'PID':>6}  {'PROCESS':<18} {'PROJECT':<18} "
                + (f"{'BY':<11} " if wide else "")
                + f"{'UP':>7}  {'HTTP':<5} INFO")
        put(scr, 1, 0, cols.ljust(w), curses.A_REVERSE)

        if self.sel < self.top:
            self.top = self.sel
        if self.sel >= self.top + list_h:
            self.top = self.sel - list_h + 1

        if not self.entries:
            hint = "nothing matches this filter (press / to change, a to show all)" \
                if (self.query or self.web_only) else "no listening sockets found."
            put(scr, 3, 2, hint, curses.A_DIM)

        for row in range(list_h):
            idx = self.top + row
            if idx >= len(self.entries):
                break
            self.draw_row(2 + row, w, idx, wide)

        if detail_h:
            self.draw_detail(h - detail_h - 1, w, detail_h)

        if self.msg and time.time() - self.msg_ts < 6:
            foot, attr = " " + self.msg, curses.color_pair(5) | curses.A_BOLD
        else:
            foot = (" ↑↓ move  ⏎ open  s stop  t tree  space mark  S stop marked  "
                    "/ search  o sort  a all  ? help  q quit")
            attr = curses.A_REVERSE
        put(scr, h - 1, 0, foot.ljust(w), attr)
        scr.refresh()

    def draw_row(self, y, w, idx, wide):
        e = self.entries[idx]
        if e.probe is None:                       # probe results arrive async
            e.probe = self.prober.get(e.host, e.port)
        probe = e.probe or {}
        parent = self.procs.get(e.proc.ppid) if e.proc else None
        by = "orphan" if e.proc and e.proc.ppid <= 1 else (parent.short if parent else "-")
        kind = {"http": "HTTP", "https": "TLS", "closed": "-", "tcp": "tcp"}.get(probe.get("kind"), "…")
        info = (probe.get("title") or probe.get("server") or e.origin
                or (e.proc.args if e.proc else ""))
        if probe.get("status"):
            info = f"{probe['status']} {info}".strip()
        if e.public:
            info = "[all interfaces] " + info
        if e.host == "::1":
            info = "[ipv6] " + info
        mark = "▸" if e.key in self.marked else " "
        line = (f" {mark} {e.port:>5}  {e.pid:>6}  {e.name()[:18]:<18} {e.project[:18]:<18} "
                + (f"{by[:11]:<11} " if wide else "")
                + f"{fmt_uptime(e.uptime):>7}  {kind:<5} {info}")

        attr = curses.A_NORMAL
        if probe.get("kind") == "http":
            attr = curses.color_pair(2)
        if e.public:
            attr = curses.color_pair(4)
        if e.key in self.marked:
            attr |= curses.A_BOLD
        if idx == self.sel:
            attr = curses.color_pair(3) | curses.A_BOLD
        put(self.scr, y, 0, line.ljust(w), attr)

    def draw_detail(self, y, w, height):
        scr = self.scr
        try:
            scr.hline(y, 0, curses.ACS_HLINE, w)
        except curses.error:
            pass
        e = self.current()
        if not e:
            return
        chain = ancestors(e.proc, self.procs) if e.proc else []
        lines = [
            f"url      {e.url}   listening on {', '.join(e.addrs)}",
            f"process  pid {e.pid}   user {e.proc.user if e.proc else '?'}   "
            f"uptime {fmt_uptime(e.uptime)}   {e.origin}",
            f"command  {e.proc.args if e.proc else '?'}",
            f"cwd      {e.cwd or '?'}",
            "chain    " + (" ← ".join(p.short for p in chain) if chain else
                           "orphaned – its launcher (shell/agent) already exited"),
        ]
        if chain:
            lines.append(f"parent   pid {chain[0].pid}: {chain[0].args}")
        for i, text in enumerate(lines[: height - 1]):
            label, _, rest = text.partition("  ")
            put(scr, y + 1 + i, 1, label, curses.color_pair(1), width=8)
            put(scr, y + 1 + i, 1 + len(label), "  " + rest, curses.A_DIM)

    def draw_help(self, h, w):
        put(self.scr, 0, 0, " socketmanager – keys ".ljust(w),
            curses.color_pair(1) | curses.A_BOLD)
        for i, line in enumerate(HELP):
            put(self.scr, 2 + i, 2, line, curses.A_DIM if line.startswith(" ") else curses.A_NORMAL)
        put(self.scr, h - 1, 0, " any key closes this help ".ljust(w), curses.A_REVERSE)

    # -- prompts
    def confirm(self, question):
        h, w = self.scr.getmaxyx()
        put(self.scr, h - 1, 0, f" {question} [y/N] ".ljust(w),
            curses.color_pair(5) | curses.A_BOLD)
        self.scr.refresh()
        curses.flushinp()                          # a held key must not confirm a kill
        self.scr.nodelay(False)
        try:
            key = self.scr.getch()
        finally:
            self.scr.nodelay(True)
        return key in (ord("y"), ord("Y"))

    def prompt(self, label, initial=""):
        buf = initial
        self.scr.nodelay(False)
        curses.curs_set(1)
        try:
            while True:
                h, w = self.scr.getmaxyx()
                put(self.scr, h - 1, 0, f" {label}{buf}".ljust(w),
                    curses.color_pair(5) | curses.A_BOLD)
                self.scr.refresh()
                key = self.scr.getch()
                if key in (10, 13, curses.KEY_ENTER):
                    return buf
                if key == 27:
                    return None
                if key in (curses.KEY_BACKSPACE, 127, 8):
                    buf = buf[:-1]
                elif 32 <= key < 127:
                    buf += chr(key)
        finally:
            curses.curs_set(0)
            self.scr.nodelay(True)

    def guard(self, entry):
        """None if it may be signalled, otherwise the reason it may not."""
        if entry.is_docker() and not entry.container:
            return "that is the docker daemon – stop the container instead"
        if not entry.container and entry.pid in own_chain(self.procs):
            return "that process is part of this session"
        return None

    # -- actions
    def act_stop(self, sig=signal.SIGTERM):
        e = self.current()
        if not e:
            return
        why = self.guard(e)
        if why:
            self.notify("✗ refusing: " + why)
            return
        label = "kill -9" if sig is signal.SIGKILL else "stop"
        if not self.confirm(f"{label} {e.name()} (pid {e.pid}) on port {e.port}?"):
            self.notify("cancelled")
            return
        if e.container:
            ok, info = stop_container(e.container)
        elif sig is signal.SIGKILL:
            ok, info = stop_pid(e.pid, sig)
            log_kill(f"{'ok ' if ok else 'FAIL'} kill -9 port {e.port} pid {e.pid} {e.name()}")
        else:
            ok, info = stop_entry(e)
        self.notify(("✓ " if ok else "✗ ") + info)
        self.collector.refresh(wait=1.5)
        self.adopt()

    def act_stop_marked(self):
        targets = self.marked_entries()
        if not targets:
            self.notify("nothing marked – use space, v or m first")
            return
        blocked = [(e, self.guard(e)) for e in targets]
        allowed = [e for e, why in blocked if not why]
        skipped = [e for e, why in blocked if why]
        if not allowed:
            self.notify("✗ refusing: nothing here may be stopped")
            return
        ports = ", ".join(str(e.port) for e in allowed[:8]) + ("…" if len(allowed) > 8 else "")
        if not self.confirm(f"stop {len(allowed)} server(s) on port {ports}?"):
            self.notify("cancelled")
            return
        done = sum(1 for e in allowed if stop_entry(e)[0])
        note = f", {len(skipped)} skipped" if skipped else ""
        self.notify(f"✓ stopped {done}/{len(allowed)}{note}")
        self.marked -= {e.key for e in allowed}
        self.collector.refresh(wait=1.5)
        self.adopt()

    def act_kill_tree(self):
        e = self.current()
        if not e:
            return
        why = self.guard(e)
        if why:
            self.notify("✗ refusing: " + why)
            return
        if e.container:
            self.act_stop()
            return
        forbidden = own_chain(self.procs)
        targets = [e.pid] + children_of(e.pid, self.procs)
        note = ""
        parent = self.procs.get(e.proc.ppid) if e.proc else None
        if parent and parent.pid not in forbidden and SUPERVISOR_RE.match(parent.short):
            # a supervisor left alive would just restart the server
            targets = [parent.pid] + children_of(parent.pid, self.procs)
            note = f" incl. supervisor {parent.short} (pid {parent.pid})"
        targets = [p for p in dict.fromkeys(targets) if p not in forbidden]
        if not targets:
            self.notify("✗ nothing safe to kill here")
            return
        if not self.confirm(f"kill {len(targets)} process(es){note}?"):
            self.notify("cancelled")
            return
        for pid in reversed(targets):              # children first, supervisor last
            stop_pid(pid, signal.SIGTERM)
        time.sleep(0.6)
        for pid in [p for p in targets if alive(p)]:
            stop_pid(pid, signal.SIGKILL)
        gone = sum(1 for p in targets if not alive(p))
        log_kill(f"tree port {e.port} pids {targets} {e.name()} [{e.project}]{note}")
        self.notify(f"✓ stopped {gone}/{len(targets)} process(es){note}")
        self.collector.refresh(wait=1.5)
        self.adopt()

    def act_open(self):
        e = self.current()
        if e:
            self.notify(open_url(e.url)[1])

    def act_copy(self):
        e = self.current()
        if e:
            self.notify(copy_text(e.url)[1])

    def act_mark_project(self):
        e = self.current()
        if not e:
            return
        same = [x for x in self.entries if (x.project, x.cwd) == (e.project, e.cwd)]
        self.marked |= {x.key for x in same}
        self.notify(f"marked {len(same)} server(s) from {e.project or 'this directory'}")

    def act_search(self):
        got = self.prompt("search: ", self.query)
        if got is not None:
            self.query = got.strip()
            self.apply_filter()
            self.notify(f"filter '{self.query}'" if self.query else "filter cleared")

    # -- loop
    def run(self):
        curses.curs_set(0)
        self.scr.nodelay(True)
        self.scr.keypad(True)
        while True:
            self.adopt()
            self.draw()
            key = self.scr.getch()
            if key == -1:
                time.sleep(0.05)
                continue
            if self.show_help:
                self.show_help = False
                self.scr.clear()
                continue
            last = max(0, len(self.entries) - 1)
            if key == ord("q"):
                return
            elif key == 27:                        # ESC: unknown key seq, never quit
                continue
            elif key in (curses.KEY_DOWN, ord("j")):
                self.sel = min(self.sel + 1, last)
            elif key in (curses.KEY_UP, ord("k")):
                self.sel = max(self.sel - 1, 0)
            elif key == curses.KEY_NPAGE:
                self.sel = min(self.sel + 10, last)
            elif key == curses.KEY_PPAGE:
                self.sel = max(self.sel - 10, 0)
            elif key == curses.KEY_HOME:
                self.sel = 0
            elif key == curses.KEY_END:
                self.sel = last
            elif key in (curses.KEY_ENTER, 10, 13):
                self.act_open()
            elif key == ord("c"):
                self.act_copy()
            elif key in (ord("s"), curses.KEY_DC, curses.KEY_BACKSPACE, 127):
                self.act_stop()
            elif key == ord("K"):
                self.act_stop(signal.SIGKILL)
            elif key == ord("t"):
                self.act_kill_tree()
            elif key == ord(" "):
                e = self.current()
                if e:
                    self.marked ^= {e.key}
                    self.sel = min(self.sel + 1, last)
            elif key == ord("v"):
                self.marked |= {e.key for e in self.entries}
                self.notify(f"marked {len(self.entries)} shown server(s)")
            elif key == ord("m"):
                self.act_mark_project()
            elif key == ord("u"):
                self.marked.clear()
                self.notify("marks cleared")
            elif key == ord("S"):
                self.act_stop_marked()
            elif key == ord("/"):
                self.act_search()
            elif key == ord("o"):
                self.sort = (self.sort + 1) % len(SORTS)
                self.apply_filter()
                self.notify(f"sorted by {SORTS[self.sort][0]}")
            elif key == ord("a"):
                self.web_only = not self.web_only
                self.apply_filter()
            elif key == ord("p"):
                self.prober.enabled = not self.prober.enabled
                self.adopt(force=True)
            elif key == ord("r"):
                self.prober.clear()
                self.collector.refresh(wait=1.5)
                self.adopt(force=True)
                self.notify("refreshed")
            elif key == ord("?"):
                self.show_help = True
                self.scr.clear()
            elif key == curses.KEY_RESIZE:
                self.scr.clear()


def start_tui(stdscr, args):
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_CYAN, -1)
    curses.init_pair(2, curses.COLOR_GREEN, -1)
    curses.init_pair(3, curses.COLOR_BLACK, curses.COLOR_CYAN)
    curses.init_pair(4, curses.COLOR_YELLOW, -1)
    curses.init_pair(5, curses.COLOR_BLACK, curses.COLOR_YELLOW)
    App(stdscr, web_only=not args.all, probe=not args.no_probe).run()


# ---------------------------------------------------------------- cli


def gather(args, probe=None):
    entries, procs = collect()
    if probe is None:
        probe = not args.no_probe
    if probe:
        with ThreadPoolExecutor(max_workers=12) as pool:
            for e, res in zip(entries, pool.map(lambda x: probe_http(x.host, x.port), entries)):
                e.probe = res
    rows = [e for e in entries if args.all or e.is_web()]
    rows.sort(key=SORTS[0][1])
    return rows, procs


def cli_list(args):
    rows, procs = gather(args)
    if args.json:
        print(json.dumps([{
            "port": e.port, "pid": e.pid, "url": e.url, "addrs": e.addrs,
            "process": e.name(), "command": e.proc.args if e.proc else None,
            "parent_pid": e.proc.ppid if e.proc else None,
            "parent": procs[e.proc.ppid].args if e.proc and e.proc.ppid in procs else None,
            "uptime_seconds": e.uptime, "uptime": fmt_uptime(e.uptime),
            "cwd": e.cwd, "project": e.project, "origin": e.origin,
            "container": e.container or None, "public": e.public,
            "http": e.probe or {},
        } for e in rows], indent=2))
        return
    for e in rows:
        flags = ("!" if e.public else " ")
        print(f"{flags}{e.port:>5}  pid {e.pid:<7} {e.name():<22} {e.project:<18} "
              f"{fmt_uptime(e.uptime):>7}  {e.url:<30} {e.origin or e.cwd}")


def cli_watch(args):
    """poll for new listeners and raise a desktop notification for each."""
    try:                       # stay readable when redirected into a log file
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass
    known, first = {}, True
    print(f"watching for new local servers every {args.interval}s – ctrl-c to stop")
    while True:
        try:
            rows, _ = gather(args, probe=not args.no_probe)
        except Exception as exc:
            print(f"scan failed: {exc}")
            time.sleep(args.interval)
            continue
        current = {e.key: e for e in rows}
        for key, e in current.items():
            if key in known:
                continue
            stamp = time.strftime("%H:%M:%S")
            where = e.project or e.cwd or "?"
            if first:
                print(f"{stamp}  · {e.url:<30} {e.name()}  [{where}]")
            else:
                print(f"{stamp}  + {e.url:<30} {e.name()}  [{where}]")
                desktop_notify("new local server", f"{e.url} · {e.name()} · {where}")
        for key, e in known.items():
            if key not in current:
                print(f"{time.strftime('%H:%M:%S')}  - {e.url:<30} {e.name()} stopped")
        known, first = current, False
        time.sleep(args.interval)


def cli_stop(args):
    ports = {int(p) for p in re.split(r"[,\s]+", args.stop) if p.strip().isdigit()}
    entries, _ = collect()
    targets = [e for e in entries if e.port in ports]
    missing = ports - {e.port for e in targets}
    for port in sorted(missing):
        print(f"nothing listening on port {port}")
    for e in targets:
        print(f"stopping {e.name()} (pid {e.pid}) on port {e.port} …")
        ok, info = stop_entry(e)
        print(f"  {'✓' if ok else '✗'} {info}")
    return 0 if targets and not missing else 1


def cli_stop_all(args):
    rows, procs = gather(args, probe=False)
    forbidden = own_chain(procs)
    targets = []
    for e in rows:
        if e.pid in forbidden or (e.is_docker() and not e.container):
            continue
        if args.older_than and e.uptime < args.older_than:
            continue
        if args.cwd and args.cwd.lower() not in f"{e.cwd} {e.project}".lower():
            continue
        targets.append(e)
    if not targets:
        print("nothing matches – no server stopped")
        return 1
    print(f"{len(targets)} server(s) would be stopped:")
    for e in targets:
        print(f"  {e.port:>5}  pid {e.pid:<7} {e.name():<22} {fmt_uptime(e.uptime):>7}  "
              f"{e.project or e.cwd}")
    if not args.yes:
        try:
            if input("stop them all? [y/N] ").strip().lower() not in ("y", "yes"):
                print("cancelled")
                return 1
        except EOFError:
            print("cancelled (no tty – pass --yes)")
            return 1
    failed = 0
    for e in targets:
        ok, info = stop_entry(e)
        print(f"  {'✓' if ok else '✗'} port {e.port}: {info}")
        failed += not ok
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser(description="overview and control of local (web)servers")
    ap.add_argument("-l", "--list", action="store_true", help="print list and exit")
    ap.add_argument("--json", action="store_true", help="print list as json and exit")
    ap.add_argument("-a", "--all", action="store_true", help="include non-web listening sockets")
    ap.add_argument("--no-probe", action="store_true", help="do not send http probe requests")
    ap.add_argument("--stop", metavar="PORTS", help="stop what listens on PORT[,PORT…]")
    ap.add_argument("--stop-all", action="store_true", help="stop every matching server")
    ap.add_argument("--older-than", type=parse_duration, metavar="DUR",
                    help="with --stop-all: only servers running longer than e.g. 2h, 3d")
    ap.add_argument("--cwd", metavar="TEXT",
                    help="with --stop-all: only servers whose project/cwd contains TEXT")
    ap.add_argument("-y", "--yes", action="store_true", help="do not ask before stopping")
    ap.add_argument("--watch", action="store_true",
                    help="keep running and notify when a new server appears")
    ap.add_argument("--interval", type=float, default=5.0, metavar="SEC",
                    help="poll interval for --watch (default 5)")
    args = ap.parse_args()

    if args.stop:
        sys.exit(cli_stop(args))
    if args.stop_all:
        sys.exit(cli_stop_all(args))
    if args.watch:
        cli_watch(args)
        return
    if args.list or args.json or not sys.stdout.isatty():
        cli_list(args)
        return
    curses.wrapper(start_tui, args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
