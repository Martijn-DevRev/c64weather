#!/usr/bin/env python3
"""
C64U_Weather Pro Server — intermediary server with web monitoring dashboard.

All C64 endpoints are identical to server.py.  Additional endpoints:
  GET /monitor        — Live monitoring dashboard (HTML, browser-only)
  GET /monitor/stats  — Live stats as JSON (polled by the dashboard)

Usage
-----
    python3 serverPro.py [--port 8064] [--station 6260]

Requires
--------
    pip install psutil pillow
"""

import argparse
import base64
import collections
import hmac
import json
import logging
import sys
import threading
import time

import http.server

# ── Import all shared logic from server.py ─────────────────────────────────
# server.py is importable; its main() guard prevents auto-execution.
from server import (
    fetch_buienradar,
    build_current,
    build_forecast,
    build_report,
    build_temps,
    build_help,
    _radar,
    DEFAULT_STATION_ID,
    WeatherHandler as _BaseHandler,
)

DEFAULT_PORT = 8064

# Credentials for the /monitor dashboard (HTTP Basic Auth).
# Username is always "monitor"; change the password here if needed.
_MONITOR_USER = "monitor"
_MONITOR_PASS = "DihwvdsBuienradar2026!"
_MONITOR_TOKEN = base64.b64encode(
    f"{_MONITOR_USER}:{_MONITOR_PASS}".encode()
).decode()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("c64weather.pro")

# ── Try to import psutil for system metrics (optional) ─────────────────────
try:
    import psutil as _psutil
    _HAS_PSUTIL = True
    _psutil.cpu_percent(interval=None)   # prime the first sample
except ImportError:
    _psutil = None
    _HAS_PSUTIL = False
    log.warning("psutil not installed — system metrics unavailable.  pip install psutil")


# ---------------------------------------------------------------------------
# Stats data model
# ---------------------------------------------------------------------------

MAX_RECENT   = 200   # ring buffer depth for recent requests
ACTIVE_SECS  = 600   # an IP is "active" if seen within this many seconds (10 min)


class _IPStats:
    __slots__ = ("ip", "first_seen", "last_seen", "request_count", "bytes_sent", "endpoints")

    def __init__(self, ip: str) -> None:
        self.ip            = ip
        self.first_seen    = time.time()
        self.last_seen     = time.time()
        self.request_count = 0
        self.bytes_sent    = 0
        self.endpoints     = collections.Counter()


class _ReqRecord:
    __slots__ = ("ts", "ip", "path", "status", "bytes_sent", "ms")

    def __init__(self, ip, path, status, bytes_sent, ms):
        self.ts         = time.time()
        self.ip         = ip
        self.path       = path
        self.status     = status
        self.bytes_sent = bytes_sent
        self.ms         = ms


class _ServerStats:
    def __init__(self) -> None:
        self.start_time      = time.time()
        self._lock           = threading.Lock()
        self.total_requests  = 0
        self.total_bytes     = 0
        self.endpoint_counts = collections.Counter()
        self.per_ip: dict[str, _IPStats] = {}
        self.recent: collections.deque[_ReqRecord] = collections.deque(maxlen=MAX_RECENT)

    def record(self, ip: str, path: str, status: int,
               bytes_sent: int, ms: float) -> None:
        with self._lock:
            self.total_requests += 1
            self.total_bytes    += bytes_sent
            self.endpoint_counts[path] += 1

            if ip not in self.per_ip:
                self.per_ip[ip] = _IPStats(ip)
            s = self.per_ip[ip]
            s.last_seen     = time.time()
            s.request_count += 1
            s.bytes_sent    += bytes_sent
            s.endpoints[path] += 1

            self.recent.appendleft(_ReqRecord(ip, path, status, bytes_sent, ms))

    def to_dict(self) -> dict:
        now = time.time()

        # System metrics via psutil
        sys_info: dict = {}
        if _HAS_PSUTIL:
            cpu = _psutil.cpu_percent(interval=None)
            mem = _psutil.virtual_memory()
            try:
                dsk = _psutil.disk_usage("/")
                sys_info["disk_pct"]   = dsk.percent
                sys_info["disk_used"]  = dsk.used
                sys_info["disk_total"] = dsk.total
            except Exception:
                pass
            sys_info["cpu_pct"]        = cpu
            sys_info["mem_pct"]        = mem.percent
            sys_info["mem_used"]       = mem.used
            sys_info["mem_total"]      = mem.total

        with self._lock:
            active_cutoff = now - ACTIVE_SECS
            ips_sorted = sorted(
                self.per_ip.values(),
                key=lambda x: x.last_seen,
                reverse=True,
            )
            return {
                "uptime_s":       now - self.start_time,
                "total_requests": self.total_requests,
                "total_bytes":    self.total_bytes,
                "endpoint_counts": dict(self.endpoint_counts.most_common()),
                "active_ips": [
                    {
                        "ip":           s.ip,
                        "requests":     s.request_count,
                        "bytes":        s.bytes_sent,
                        "first_seen":   s.first_seen,
                        "last_seen":    s.last_seen,
                        "active":       s.last_seen >= active_cutoff,
                        "top_endpoint": s.endpoints.most_common(1)[0][0]
                                        if s.endpoints else "-",
                        "all_endpoints": dict(s.endpoints.most_common()),
                    }
                    for s in ips_sorted
                ],
                "recent": [
                    {
                        "ts":     r.ts,
                        "ip":     r.ip,
                        "path":   r.path,
                        "status": r.status,
                        "bytes":  r.bytes_sent,
                        "ms":     round(r.ms, 1),
                    }
                    for r in self.recent
                ],
                "system": sys_info,
            }


_stats = _ServerStats()


# ---------------------------------------------------------------------------
# Monitoring dashboard HTML
# ---------------------------------------------------------------------------

_MONITOR_HTML = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>C64U Weather Server — Monitor</title>
<style>
  :root {
    --bg:       #0d1117;
    --surface:  #161b22;
    --border:   #30363d;
    --text:     #e6edf3;
    --muted:    #8b949e;
    --green:    #3fb950;
    --yellow:   #d29922;
    --red:      #f85149;
    --blue:     #58a6ff;
    --purple:   #bc8cff;
    --orange:   #ffa657;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", monospace; font-size: 14px; min-height: 100vh; }
  header { background: var(--surface); border-bottom: 1px solid var(--border); padding: 14px 24px; display: flex; align-items: center; justify-content: space-between; }
  header h1 { font-size: 17px; font-weight: 600; color: var(--blue); letter-spacing: .5px; }
  header h1 span { color: var(--muted); font-weight: 400; font-size: 13px; margin-left: 12px; }
  .refresh-badge { font-size: 12px; color: var(--muted); display: flex; align-items: center; gap: 6px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--green); animation: pulse 2s infinite; }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: .4; } }

  main { padding: 20px 24px; }

  /* ── Cards ── */
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: 14px; margin-bottom: 24px; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 16px; }
  .card .label { font-size: 11px; text-transform: uppercase; letter-spacing: .8px; color: var(--muted); margin-bottom: 8px; }
  .card .value { font-size: 26px; font-weight: 700; }
  .card .sub { font-size: 11px; color: var(--muted); margin-top: 4px; }
  .bar-wrap { margin-top: 8px; background: var(--border); border-radius: 4px; height: 6px; overflow: hidden; }
  .bar { height: 100%; border-radius: 4px; transition: width .4s; }
  .bar.ok   { background: var(--green); }
  .bar.warn { background: var(--yellow); }
  .bar.crit { background: var(--red); }

  /* ── Sections ── */
  .section { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 20px; overflow: hidden; }
  .section-header { padding: 12px 16px; border-bottom: 1px solid var(--border); font-weight: 600; font-size: 13px; display: flex; align-items: center; justify-content: space-between; }
  .badge { background: var(--border); border-radius: 12px; padding: 2px 8px; font-size: 11px; color: var(--muted); }
  .badge.active { background: rgba(63,185,80,.15); color: var(--green); }

  /* ── Tables ── */
  table { width: 100%; border-collapse: collapse; }
  th { font-size: 11px; text-transform: uppercase; letter-spacing: .6px; color: var(--muted); padding: 8px 16px; text-align: left; border-bottom: 1px solid var(--border); }
  td { padding: 9px 16px; border-bottom: 1px solid rgba(48,54,61,.5); font-size: 13px; white-space: nowrap; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: rgba(255,255,255,.03); }
  .mono { font-family: "SFMono-Regular", Consolas, monospace; }
  .status-2 { color: var(--green); }
  .status-4 { color: var(--yellow); }
  .status-5 { color: var(--red); }
  .active-dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; margin-right: 6px; }
  .active-dot.on  { background: var(--green); }
  .active-dot.off { background: var(--muted); }
  .endpoint-pill { display: inline-block; background: rgba(88,166,255,.12); color: var(--blue); border-radius: 4px; padding: 1px 7px; font-size: 11px; font-family: monospace; }
  .empty { padding: 24px; text-align: center; color: var(--muted); font-style: italic; }

  /* ── Endpoint breakdown ── */
  .ep-row { display: flex; gap: 8px; flex-wrap: wrap; }
  .ep-chip { background: var(--border); border-radius: 4px; padding: 2px 7px; font-size: 11px; font-family: monospace; }
</style>
</head>
<body>
<header>
  <h1>&#128377; C64U Weather Server <span id="uptime">—</span></h1>
  <div class="refresh-badge"><div class="dot"></div> Live &mdash; next refresh in <span id="countdown">3</span>s</div>
</header>
<main>
  <div class="cards" id="cards">
    <div class="card"><div class="label">Requests</div><div class="value" id="c-reqs">—</div><div class="sub" id="c-reqs-sub">total served</div></div>
    <div class="card"><div class="label">Bytes Out</div><div class="value" id="c-bytes">—</div><div class="sub" id="c-bytes-sub">&nbsp;</div></div>
    <div class="card"><div class="label">Clients</div><div class="value" id="c-clients">—</div><div class="sub">active / total</div></div>
    <div class="card"><div class="label">CPU</div><div class="value" id="c-cpu">—</div><div class="sub">percent</div><div class="bar-wrap"><div class="bar" id="b-cpu" style="width:0%"></div></div></div>
    <div class="card"><div class="label">Memory</div><div class="value" id="c-mem">—</div><div class="sub" id="c-mem-sub">&nbsp;</div><div class="bar-wrap"><div class="bar" id="b-mem" style="width:0%"></div></div></div>
    <div class="card"><div class="label">Disk</div><div class="value" id="c-disk">—</div><div class="sub" id="c-disk-sub">&nbsp;</div><div class="bar-wrap"><div class="bar" id="b-disk" style="width:0%"></div></div></div>
  </div>

  <div class="section">
    <div class="section-header">Endpoint usage <span class="badge" id="ep-badge">—</span></div>
    <div style="padding:14px 16px;" id="ep-chips"><span class="empty">No data yet</span></div>
  </div>

  <div class="section">
    <div class="section-header">Clients <span class="badge active" id="clients-badge">0 active</span></div>
    <table>
      <thead><tr><th>IP</th><th>Requests</th><th>Bytes Out</th><th>Top Endpoint</th><th>Last Seen</th><th>First Seen</th></tr></thead>
      <tbody id="clients-body"><tr><td colspan="6" class="empty">No clients yet</td></tr></tbody>
    </table>
  </div>

  <div class="section">
    <div class="section-header">Recent Requests <span class="badge" id="recent-badge">0</span></div>
    <table>
      <thead><tr><th>Time</th><th>IP</th><th>Path</th><th>Status</th><th>Bytes</th><th>ms</th></tr></thead>
      <tbody id="recent-body"><tr><td colspan="6" class="empty">No requests yet</td></tr></tbody>
    </table>
  </div>
</main>

<script>
const $ = id => document.getElementById(id);
let countdown = 3;

function fmt_bytes(n) {
  if (n === null || n === undefined) return '—';
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n/1024).toFixed(1) + ' KB';
  if (n < 1073741824) return (n/1048576).toFixed(1) + ' MB';
  return (n/1073741824).toFixed(2) + ' GB';
}
function fmt_uptime(s) {
  const h = Math.floor(s/3600), m = Math.floor((s%3600)/60), sec = Math.floor(s%60);
  return (h ? h+'h ' : '') + (m ? m+'m ' : '') + sec + 's';
}
function fmt_time(ts) {
  return new Date(ts*1000).toLocaleTimeString();
}
function fmt_ago(ts) {
  const d = Date.now()/1000 - ts;
  if (d < 60) return Math.floor(d)+'s ago';
  if (d < 3600) return Math.floor(d/60)+'m ago';
  return Math.floor(d/3600)+'h ago';
}
function bar_class(pct) {
  return pct === null ? 'ok' : pct < 60 ? 'ok' : pct < 85 ? 'warn' : 'crit';
}
function set_bar(id, pct) {
  const el = $(id);
  if (!el) return;
  const p = pct ?? 0;
  el.style.width = p + '%';
  el.className = 'bar ' + bar_class(pct);
}

function update(data) {
  // uptime
  $('uptime').textContent = '— up ' + fmt_uptime(data.uptime_s);

  // cards
  $('c-reqs').textContent = data.total_requests.toLocaleString();
  $('c-bytes').textContent = fmt_bytes(data.total_bytes);

  const active = data.active_ips.filter(x => x.active).length;
  $('c-clients').textContent = active + ' / ' + data.active_ips.length;

  const sys = data.system || {};
  if (sys.cpu_pct !== undefined && sys.cpu_pct !== null) {
    $('c-cpu').textContent = sys.cpu_pct.toFixed(1) + '%';
    set_bar('b-cpu', sys.cpu_pct);
  } else { $('c-cpu').textContent = 'N/A'; }

  if (sys.mem_pct !== undefined && sys.mem_pct !== null) {
    $('c-mem').textContent = sys.mem_pct.toFixed(1) + '%';
    $('c-mem-sub').textContent = fmt_bytes(sys.mem_used) + ' / ' + fmt_bytes(sys.mem_total);
    set_bar('b-mem', sys.mem_pct);
  } else { $('c-mem').textContent = 'N/A'; }

  if (sys.disk_pct !== undefined && sys.disk_pct !== null) {
    $('c-disk').textContent = sys.disk_pct.toFixed(1) + '%';
    $('c-disk-sub').textContent = fmt_bytes(sys.disk_used) + ' / ' + fmt_bytes(sys.disk_total);
    set_bar('b-disk', sys.disk_pct);
  } else { $('c-disk').textContent = 'N/A'; }

  // endpoint chips
  const ec = data.endpoint_counts || {};
  const total_ep = Object.values(ec).reduce((a,b)=>a+b, 0);
  $('ep-badge').textContent = total_ep + ' total';
  if (Object.keys(ec).length) {
    $('ep-chips').innerHTML = Object.entries(ec)
      .sort((a,b)=>b[1]-a[1])
      .map(([k,v]) => `<span class="ep-chip">${k} <strong>${v}</strong></span>`)
      .join(' ');
  }

  // clients table — only show IPs active within the last 10 minutes
  $('clients-badge').textContent = active + ' active';
  const cb = $('clients-body');
  const visible = data.active_ips.filter(s => s.active);
  if (!visible.length) {
    cb.innerHTML = '<tr><td colspan="6" class="empty">No active clients</td></tr>';
  } else {
    cb.innerHTML = visible.map(s => {
      const dot = `<span class="active-dot ${s.active?'on':'off'}"></span>`;
      const eps = Object.entries(s.all_endpoints||{})
        .sort((a,b)=>b[1]-a[1])
        .map(([k,v])=>`<span class="ep-chip">${k} ${v}</span>`)
        .join(' ');
      return `<tr>
        <td class="mono">${dot}${s.ip}</td>
        <td>${s.requests.toLocaleString()}</td>
        <td>${fmt_bytes(s.bytes)}</td>
        <td>${eps || '<span class="muted">—</span>'}</td>
        <td>${fmt_ago(s.last_seen)}</td>
        <td>${fmt_ago(s.first_seen)}</td>
      </tr>`;
    }).join('');
  }

  // recent requests
  $('recent-badge').textContent = data.recent.length;
  const rb = $('recent-body');
  if (!data.recent.length) {
    rb.innerHTML = '<tr><td colspan="6" class="empty">No requests yet</td></tr>';
  } else {
    rb.innerHTML = data.recent.map(r => {
      const sc = 'status-' + Math.floor(r.status/100);
      return `<tr>
        <td class="mono">${fmt_time(r.ts)}</td>
        <td class="mono">${r.ip}</td>
        <td><span class="endpoint-pill">${r.path}</span></td>
        <td class="mono ${sc}">${r.status}</td>
        <td>${fmt_bytes(r.bytes)}</td>
        <td class="mono">${r.ms}</td>
      </tr>`;
    }).join('');
  }
}

async function refresh() {
  try {
    const res = await fetch('/monitor/stats');
    if (res.ok) update(await res.json());
  } catch(e) {}
  countdown = 3;
}

setInterval(() => {
  countdown--;
  $('countdown').textContent = Math.max(0, countdown);
  if (countdown <= 0) refresh();
}, 1000);

refresh();
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Extended HTTP handler — wraps _BaseHandler, adds /monitor endpoints
# ---------------------------------------------------------------------------

class WeatherHandlerPro(_BaseHandler):
    """Extends the base C64 handler with request stats tracking and /monitor."""

    # ── override send_* to count bytes ─────────────────────────────────────

    def send_text(self, body: str, status: int = 200) -> None:
        encoded = body.encode("ascii", errors="replace")
        self._resp_bytes  = getattr(self, "_resp_bytes",  0) + len(encoded)
        self._resp_status = status
        super().send_text(body, status)

    def send_binary(self, data: bytes, status: int = 200) -> None:
        self._resp_bytes  = getattr(self, "_resp_bytes",  0) + len(data)
        self._resp_status = status
        super().send_binary(data, status)

    # ── HTTP Basic Auth for /monitor ────────────────────────────────────────

    def _check_monitor_auth(self) -> bool:
        """Return True if the request carries valid Basic Auth credentials.

        Sends a 401 challenge and returns False if credentials are absent or
        wrong.  Uses hmac.compare_digest to prevent timing-based attacks.
        """
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            provided = header[len("Basic "):].strip()
            if hmac.compare_digest(provided, _MONITOR_TOKEN):
                return True
        # Challenge the browser
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="C64U Monitor"')
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "13")
        self.end_headers()
        self.wfile.write(b"Unauthorized\n")
        self._resp_status = 401
        self._resp_bytes  += 13
        return False

    # ── main GET dispatcher ─────────────────────────────────────────────────

    def do_GET(self):
        self._resp_bytes  = 0
        self._resp_status = 200
        t0   = time.time()
        path = self.path.split("?")[0].rstrip("/") or "/"

        if path == "/monitor":
            if self._check_monitor_auth():
                self._serve_monitor_page()
        elif path == "/monitor/stats":
            if self._check_monitor_auth():
                self._serve_monitor_stats()
        else:
            super().do_GET()

        ms = (time.time() - t0) * 1000
        _stats.record(
            self.client_address[0], path,
            self._resp_status, self._resp_bytes, ms,
        )

    # ── monitoring endpoints ─────────────────────────────────────────────────

    def _serve_monitor_page(self) -> None:
        body = _MONITOR_HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type",   "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self._resp_bytes  += len(body)
        self._resp_status  = 200

    def _serve_monitor_stats(self) -> None:
        body = json.dumps(_stats.to_dict(), separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type",   "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control",  "no-cache")
        self.end_headers()
        self.wfile.write(body)
        self._resp_bytes  += len(body)
        self._resp_status  = 200


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="C64U Weather Pro server with monitoring dashboard"
    )
    parser.add_argument(
        "--port", type=int, default=DEFAULT_PORT,
        help=f"TCP port to listen on (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--station", type=int, default=DEFAULT_STATION_ID,
        help=f"Buienradar station ID for /current (default: {DEFAULT_STATION_ID} = De Bilt)",
    )
    args = parser.parse_args()

    WeatherHandlerPro.station_id = args.station

    server = http.server.HTTPServer(("", args.port), WeatherHandlerPro)
    log.info("C64U Weather Pro server  →  http://0.0.0.0:%d", args.port)
    log.info("Monitoring dashboard     →  http://localhost:%d/monitor", args.port)
    log.info("Station: %d  |  psutil: %s", args.station,
             "available" if _HAS_PSUTIL else "NOT installed — pip install psutil")
    log.info("Press Ctrl-C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
        server.server_close()
        sys.exit(0)


if __name__ == "__main__":
    main()
