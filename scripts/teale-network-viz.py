#!/usr/bin/env python3
"""Teale Network Viz — live dashboard of the Teale network.

Runs a local HTTP server on :8777 (override with TEALE_VIZ_PORT), opens your
browser to the dashboard, and polls gateway.teale.com every 5 s for:
  - every connected device (supply side: hardware, loaded models, throughput)
  - per-device role (supply / idle / quarantined)
  - models available to the fleet + per-model supplier count
  - total supply capacity (RAM + EWMA tokens/s)

The gateway bearer token stays server-side; the browser only talks to the
local proxy. Set TEALE_TOKEN to override the hard-coded dev token.

Usage:
  python3 scripts/teale-network-viz.py

Stop with Ctrl-C.
"""
import http.server
import os
import socketserver
import sys
import threading
import time
import webbrowser
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

GATEWAY = os.environ.get("TEALE_GATEWAY", "https://gateway.teale.com")
TOKEN = os.environ.get("TEALE_TOKEN", "tok_dev_1aae940b6028bb79da1c04a598b2a14d")
PORT = int(os.environ.get("TEALE_VIZ_PORT", "8777"))

HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Teale Network</title>
<style>
  :root {
    --bg: #0a0e14;
    --panel: #141925;
    --panel-hi: #1d2333;
    --accent: #4fd1c5;
    --accent-dim: #2c7a7b;
    --muted: #6b7589;
    --text: #e2e8f0;
    --text-bright: #f7fafc;
    --supply: #68d391;
    --idle: #a0aec0;
    --quarantined: #fc8181;
    --warn: #f6ad55;
    --err: #fc8181;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: var(--bg);
    color: var(--text);
    padding: 32px;
    min-height: 100vh;
  }
  header {
    display: flex; align-items: baseline; justify-content: space-between;
    margin-bottom: 24px;
    border-bottom: 1px solid var(--panel-hi);
    padding-bottom: 16px;
  }
  h1 { margin: 0; font-size: 26px; font-weight: 600; color: var(--text-bright); letter-spacing: -0.5px; }
  h1 .dot { color: var(--accent); }
  .status { font-size: 12px; color: var(--muted); font-variant-numeric: tabular-nums; font-family: monospace; }
  .status.ok::before { content: "● "; color: var(--supply); }
  .status.err::before { content: "● "; color: var(--err); }

  .stats {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px;
    margin-bottom: 24px;
  }
  .stat {
    background: var(--panel);
    border: 1px solid var(--panel-hi);
    border-radius: 6px;
    padding: 16px 20px;
  }
  .stat .label { font-size: 10px; text-transform: uppercase; letter-spacing: 1px; color: var(--muted); margin-bottom: 8px; font-weight: 600; }
  .stat .value { font-size: 32px; font-weight: 600; color: var(--text-bright); font-variant-numeric: tabular-nums; line-height: 1; }
  .stat .value.supply-color { color: var(--supply); }
  .stat .value.idle-color { color: var(--idle); }
  .stat .value.quarantined-color { color: var(--quarantined); }
  .stat .unit { font-size: 12px; color: var(--muted); margin-left: 6px; font-weight: 400; }
  .stat .sub { font-size: 11px; color: var(--muted); margin-top: 6px; font-variant-numeric: tabular-nums; }

  .section { margin-bottom: 32px; }
  .section-title {
    font-size: 12px; text-transform: uppercase; letter-spacing: 1.5px;
    color: var(--muted); margin: 0 0 12px 0; font-weight: 600;
  }

  .devices { display: grid; gap: 8px; }
  .device {
    background: var(--panel);
    border: 1px solid var(--panel-hi);
    border-radius: 6px;
    padding: 14px 16px;
    display: grid;
    grid-template-columns: 2.5fr 1fr 1fr 1fr 2fr;
    gap: 14px;
    align-items: center;
  }
  .device.supply { border-left: 3px solid var(--supply); }
  .device.idle { border-left: 3px solid var(--idle); }
  .device.quarantined { border-left: 3px solid var(--quarantined); opacity: 0.7; }

  .device .name {
    font-weight: 500;
    color: var(--text-bright);
    display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap;
  }
  .device .name .id {
    font-family: monospace;
    font-size: 10px;
    color: var(--muted);
    font-weight: 400;
  }
  .device .name .role {
    font-size: 9px; letter-spacing: 1px; text-transform: uppercase;
    padding: 2px 6px; border-radius: 3px; font-weight: 600;
  }
  .device .name .role.supply { background: var(--supply); color: #1a202c; }
  .device .name .role.idle { background: var(--panel-hi); color: var(--idle); }
  .device .name .role.quarantined { background: var(--quarantined); color: #1a202c; }

  .device .cell {
    font-size: 12px; color: var(--muted); font-variant-numeric: tabular-nums;
  }
  .device .cell .val { font-size: 14px; color: var(--text); font-weight: 500; }
  .device .models {
    display: flex; flex-wrap: wrap; gap: 4px;
    justify-content: flex-end;
  }
  .device .models .chip {
    background: var(--panel-hi);
    border-radius: 3px;
    padding: 2px 7px;
    font-family: monospace;
    font-size: 10px;
    color: var(--text);
    white-space: nowrap;
  }
  .device .models .chip.empty { color: var(--muted); font-style: italic; font-family: inherit; }

  .models-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 10px; }
  .model-card {
    background: var(--panel);
    border: 1px solid var(--panel-hi);
    border-radius: 6px;
    padding: 12px 16px;
    display: flex; align-items: center; justify-content: space-between; gap: 10px;
  }
  .model-card.served { border-left: 3px solid var(--supply); }
  .model-card.listed { border-left: 3px solid var(--accent); }
  .model-card.catalog-only { opacity: 0.5; }
  .model-card .id { font-family: monospace; font-size: 12px; color: var(--text); overflow-wrap: anywhere; }
  .model-card .id .org { color: var(--muted); }
  .model-card .count { font-size: 18px; font-weight: 600; color: var(--accent); font-variant-numeric: tabular-nums; white-space: nowrap; }
  .model-card .count.zero { color: var(--muted); }
  .model-card .count .sub { font-size: 10px; color: var(--muted); font-weight: 400; margin-left: 4px; text-transform: uppercase; letter-spacing: 1px; }

  footer { margin-top: 48px; font-size: 11px; color: var(--muted); font-family: monospace; }
  .error { color: var(--err); font-family: monospace; font-size: 12px; margin-top: 12px; }
  .empty { color: var(--muted); font-style: italic; padding: 16px; text-align: center; }

  @media (max-width: 900px) {
    .device { grid-template-columns: 1fr; }
    .device .models { justify-content: flex-start; }
  }
</style>
</head>
<body>
<header>
  <h1>Teale Network<span class="dot">.</span></h1>
  <div class="status" id="status">connecting…</div>
</header>

<section class="stats">
  <div class="stat">
    <div class="label">Devices Connected</div>
    <div class="value"><span id="connected">—</span></div>
    <div class="sub" id="connected-breakdown">—</div>
  </div>
  <div class="stat">
    <div class="label">Supply</div>
    <div class="value supply-color"><span id="supply-count">—</span></div>
    <div class="sub">advertising loaded models</div>
  </div>
  <div class="stat">
    <div class="label">Idle</div>
    <div class="value idle-color"><span id="idle-count">—</span></div>
    <div class="sub">connected, no models loaded</div>
  </div>
  <div class="stat">
    <div class="label">Quarantined</div>
    <div class="value quarantined-color"><span id="quarantined-count">—</span></div>
    <div class="sub">failure cooldown</div>
  </div>
  <div class="stat">
    <div class="label">Unique Models Served</div>
    <div class="value"><span id="unique-models">—</span></div>
    <div class="sub" id="models-catalog">—</div>
  </div>
  <div class="stat">
    <div class="label">Aggregate Capacity</div>
    <div class="value"><span id="total-tps">—</span><span class="unit">tok/s</span></div>
    <div class="sub"><span id="total-ram">—</span> GB unified RAM</div>
  </div>
</section>

<div class="section">
  <div class="section-title">Devices</div>
  <div class="devices" id="devices-list"><div class="empty">loading…</div></div>
</div>

<div class="section">
  <div class="section-title">Models</div>
  <div class="models-grid" id="models-list"><div class="empty">loading…</div></div>
</div>

<div class="error" id="error"></div>

<footer>
  gateway: <span id="gw-url">—</span> · refresh every 5 s · last update <span id="last-update">—</span>
</footer>

<script>
const $ = (id) => document.getElementById(id);

function parsePromMetrics(text) {
  const out = {};
  for (const line of text.split("\n")) {
    if (!line || line.startsWith("#")) continue;
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*)(\{[^}]*\})?\s+([-\d.eE+]+)/);
    if (!m) continue;
    const [, name, labelStr, valStr] = m;
    const labels = {};
    if (labelStr) {
      for (const pair of labelStr.slice(1, -1).split(",")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        const k = pair.slice(0, eq).trim();
        const v = pair.slice(eq + 1).trim().replace(/^"|"$/g, "");
        labels[k] = v;
      }
    }
    if (!out[name]) out[name] = [];
    out[name].push({ labels, value: Number(valStr) });
  }
  return out;
}

function fmtModelId(id) {
  const i = id.indexOf("/");
  if (i < 0) return id;
  return `<span class="org">${id.slice(0, i + 1)}</span>${id.slice(i + 1)}`;
}

function fmtRam(gb) {
  if (gb >= 1024) return (gb / 1024).toFixed(1) + " TB";
  if (gb >= 100) return Math.round(gb) + " GB";
  return gb.toFixed(0) + " GB";
}

function fmtDisplayName(name) {
  return name.replace(/\.local$/, "").replace(/-mac-studio$/, "").replace(/s-mac-/, "-");
}

function fmtTps(v) {
  if (v >= 1000) return (v / 1000).toFixed(1) + "k";
  return v.toFixed(0);
}

async function tick() {
  try {
    const [networkRes, metricsRes, modelsRes, infoRes] = await Promise.all([
      fetch("/api/network"),
      fetch("/api/metrics"),
      fetch("/api/models"),
      fetch("/api/info"),
    ]);
    if (!networkRes.ok) throw new Error(`network HTTP ${networkRes.status}`);

    const network = await networkRes.json();
    const metricsText = metricsRes.ok ? await metricsRes.text() : "";
    const metrics = parsePromMetrics(metricsText);
    const modelsJson = modelsRes.ok ? await modelsRes.json() : { data: [] };
    const info = infoRes.ok ? await infoRes.json() : {};

    $("gw-url").textContent = info.gateway || "—";

    // Summary stats
    const summary = network.summary || {};
    $("connected").textContent = summary.connected ?? 0;
    $("connected-breakdown").textContent =
      `${summary.supply || 0} supply · ${summary.idle || 0} idle · ${summary.quarantined || 0} quar.`;
    $("supply-count").textContent = summary.supply ?? 0;
    $("idle-count").textContent = summary.idle ?? 0;
    $("quarantined-count").textContent = summary.quarantined ?? 0;
    $("unique-models").textContent = summary.uniqueModelsServed ?? 0;
    $("total-tps").textContent = fmtTps(summary.totalEwmaTokensPerSecond || 0);
    $("total-ram").textContent = fmtRam(summary.totalRAMGB || 0);

    // Model-catalog stats
    const listedIds = (modelsJson.data || []).map(m => m.id);
    const eligibleRows = metrics["gateway_devices_eligible"] || [];
    const eligibleMap = {};
    for (const r of eligibleRows) eligibleMap[r.labels.model] = r.value;
    const catalogIds = new Set([...listedIds, ...Object.keys(eligibleMap), ...(summary.modelsServed || [])]);
    $("models-catalog").textContent = `${listedIds.length} advertised · ${catalogIds.size} in catalog`;

    // Devices list
    const devices = network.devices || [];
    if (devices.length === 0) {
      $("devices-list").innerHTML = `<div class="empty">no devices connected</div>`;
    } else {
      $("devices-list").innerHTML = devices.map(d => {
        const name = fmtDisplayName(d.displayName);
        const ram = fmtRam(d.ramGB);
        const tps = fmtTps(d.ewmaTokensPerSecond);
        const chip = d.chip.replace(/^Apple /, "");
        const hbBadge = d.heartbeatStale ? ` <span style="color:var(--warn)">(stale ${d.heartbeatAgeSecs}s)</span>` : "";
        const quar = d.isQuarantined ? ` <span style="color:var(--quarantined)">QUAR</span>` : "";
        const busy = d.isGenerating ? ` <span style="color:var(--accent)">● gen</span>` : "";
        let modelsHtml;
        if (d.loadedModels.length === 0) {
          modelsHtml = `<div class="chip empty">no models loaded</div>`;
        } else {
          modelsHtml = d.loadedModels.map(m => `<div class="chip">${m}</div>`).join("");
        }
        return `<div class="device ${d.role}">
          <div class="name">
            <span>${name}</span>
            <span class="role ${d.role}">${d.role}</span>
            <span class="id">${d.shortID}</span>${hbBadge}${quar}${busy}
          </div>
          <div class="cell"><div class="val">${chip}</div>hardware</div>
          <div class="cell"><div class="val">${ram}</div>${d.memoryBandwidthGBs ? d.memoryBandwidthGBs + " GB/s" : "memory"}</div>
          <div class="cell"><div class="val">${tps}</div>tok/s EWMA</div>
          <div class="models">${modelsHtml}</div>
        </div>`;
      }).join("");
    }

    // Models list (catalog-wide)
    const rows = [];
    for (const id of catalogIds) {
      const listed = listedIds.includes(id);
      const served = (summary.modelsServed || []).includes(id);
      const count = eligibleMap[id] ?? (served ? 1 : 0);
      rows.push({ id, listed, served, count });
    }
    rows.sort((a, b) => (b.count - a.count) || a.id.localeCompare(b.id));
    if (rows.length === 0) {
      $("models-list").innerHTML = `<div class="empty">no models in catalog</div>`;
    } else {
      $("models-list").innerHTML = rows.map(r => {
        const cls = r.count > 0 ? (r.listed ? "listed served" : "served") : "catalog-only";
        let subtext;
        if (r.count === 0) subtext = "catalog only";
        else if (r.listed) subtext = "advertised";
        else subtext = "served";
        return `<div class="model-card ${cls}">
          <div class="id">${fmtModelId(r.id)}</div>
          <div class="count ${r.count === 0 ? "zero" : ""}">${r.count}<span class="sub">${subtext}</span></div>
        </div>`;
      }).join("");
    }

    $("status").textContent = "live";
    $("status").className = "status ok";
    $("error").textContent = "";
    $("last-update").textContent = new Date().toLocaleTimeString();
  } catch (e) {
    $("status").textContent = "error";
    $("status").className = "status err";
    $("error").textContent = String(e);
  }
}

tick();
setInterval(tick, 5000);
</script>
</body>
</html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self._send(200, "text/html", HTML.encode())
        elif self.path == "/api/info":
            body = f'{{"gateway": "{GATEWAY}"}}'.encode()
            self._send(200, "application/json", body)
        elif self.path == "/api/network":
            self._proxy("/v1/network", auth=True, fallback_ctype="application/json")
        elif self.path == "/api/metrics":
            self._proxy("/metrics", auth=False, fallback_ctype="text/plain")
        elif self.path == "/api/models":
            self._proxy("/v1/models", auth=True, fallback_ctype="application/json")
        else:
            self._send(404, "text/plain", b"not found")

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _proxy(self, path, auth, fallback_ctype):
        url = GATEWAY.rstrip("/") + path
        headers = {"User-Agent": "teale-network-viz/1.0"}
        if auth:
            headers["Authorization"] = f"Bearer {TOKEN}"
        try:
            with urlopen(Request(url, headers=headers), timeout=10) as r:
                data = r.read()
                ctype = r.headers.get_content_type() or fallback_ctype
                self._send(200, ctype, data)
        except HTTPError as e:
            self._send(e.code, "text/plain", (e.reason or "").encode())
        except URLError as e:
            self._send(502, "text/plain", str(e).encode())
        except Exception as e:
            self._send(500, "text/plain", str(e).encode())

    def log_message(self, fmt, *args):
        return  # quiet


def main():
    socketserver.TCPServer.allow_reuse_address = True
    try:
        server = socketserver.TCPServer(("127.0.0.1", PORT), Handler)
    except OSError as e:
        print(f"failed to bind 127.0.0.1:{PORT}: {e}", file=sys.stderr)
        print(f"hint: set TEALE_VIZ_PORT to a different port", file=sys.stderr)
        sys.exit(1)

    url = f"http://127.0.0.1:{PORT}/"
    print(f"Teale Network viz → {url}")
    print(f"  gateway: {GATEWAY}")
    print(f"  ctrl-c to stop")
    threading.Thread(
        target=lambda: (time.sleep(0.4), webbrowser.open(url)),
        daemon=True,
    ).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
