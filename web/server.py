#!/usr/bin/env python3
"""Local web UI for the OCaml portfolio engine.

    python3 web/server.py [--config india/config.ini] [--port 8765]

Binds to 127.0.0.1 only. Serves web/index.html and a small JSON API that edits
holdings/config, runs `fp analyze` and the NSE data refresh as background jobs,
and returns the engine's out/report.json. Standard library only.
"""
import argparse, csv, io, json, os, re, subprocess, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(ROOT, "_build", "default", "bin", "main.exe")
VENV_PY = os.path.join(ROOT, "sidecar", ".venv", "bin", "python")
FETCH = os.path.join(ROOT, "scripts", "fetch_nse.py")
SYMBOL_RE = re.compile(r"^[A-Z0-9&\-]{1,20}$")
MILESTONES = os.path.join(ROOT, "docs", "milestones.md")
JOBS = ("analyze", "refresh", "refresh_analyze", "forecasts", "forecasts_all", "service_start", "service_stop")

# Settings the UI may change, with (type, min, max).
EDITABLE = {
    "cash": (float, 0, 1e12), "w_value": (float, 0, 10), "w_quality": (float, 0, 10), "w_growth": (float, 0, 10),
    "w_momentum": (float, 0, 10), "w_lowvol": (float, 0, 10), "ic": (float, 0, 0.5),
    "risk_aversion": (float, 0.01, 100), "target_vol": (float, 0, 2), "max_weight": (float, 0.01, 1),
    "max_sector": (float, 0.01, 1), "min_invested": (float, 0, 1), "max_invested": (float, 0, 1),
    "tc_bps": (float, 0, 500), "holding_days": (int, 1, 2520), "min_trade": (float, 0, 0.5),
    "risk_free": (float, -0.05, 0.5), "sector_neutral": (bool, None, None), "use_model": (bool, None, None),
}


class State:
    def __init__(self, config):
        self.config = os.path.abspath(config)
        self.base = os.path.dirname(self.config)
        self.lock = threading.Lock()
        self.job = {"running": False, "kind": None, "log": "", "ok": None, "started": None, "finished": None}

    # -- config ------------------------------------------------------------
    def read_config(self):
        kv = {}
        with open(self.config, encoding="utf-8") as f:
            for line in f:
                line = line.split("#", 1)[0]
                if "=" in line:
                    k, v = line.split("=", 1)
                    kv[k.strip().lower()] = v.strip()
        return kv

    def path(self, key, default):
        p = self.read_config().get(key) or default
        return p if os.path.isabs(p) else os.path.join(self.base, p)

    def write_config(self, updates):
        clean = {}
        for k, v in updates.items():
            if k not in EDITABLE:
                raise ValueError(f"setting '{k}' cannot be edited here")
            typ, lo, hi = EDITABLE[k]
            if typ is bool:
                clean[k] = "true" if (v is True or str(v).lower() in ("true", "1", "yes")) else "false"
                continue
            x = typ(v)
            if not (lo <= x <= hi):
                raise ValueError(f"{k} must be between {lo} and {hi}")
            clean[k] = str(x)
        with open(self.config, encoding="utf-8") as f:
            lines = f.read().split("\n")
        seen = set()
        for i, line in enumerate(lines):
            m = re.match(r"^(\s*)([A-Za-z_]+)(\s*=\s*)([^#]*?)(\s*#.*)?$", line)
            if m and m.group(2).lower() in clean:
                k = m.group(2).lower()
                lines[i] = f"{m.group(1)}{m.group(2)}{m.group(3)}{clean[k]}{('  ' + m.group(5).strip()) if m.group(5) else ''}"
                seen.add(k)
        lines += [f"{k} = {v}" for k, v in clean.items() if k not in seen]
        with open(self.config, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))

    # -- holdings ----------------------------------------------------------
    def read_holdings(self):
        p = self.path("holdings", "data/portfolio.csv")
        if not os.path.exists(p):
            return []
        with open(p, encoding="utf-8") as f:
            rows = [l for l in f if l.strip() and not l.lstrip().startswith("#")]
        out = []
        for r in csv.DictReader(io.StringIO("".join(rows))):
            r = {k.strip().lower(): (v or "").strip() for k, v in r.items() if k}
            out.append({"symbol": r.get("symbol", ""), "shares": r.get("shares", ""), "cost_basis": r.get("cost_basis", "")})
        return out

    def write_holdings(self, rows):
        lines = ["symbol,shares,cost_basis"]
        for r in rows:
            sym = str(r.get("symbol", "")).strip().upper()
            if not sym:
                continue
            if not SYMBOL_RE.match(sym):
                raise ValueError(f"invalid symbol '{sym}'")
            shares = float(r.get("shares") or 0)
            if shares < 0:
                raise ValueError(f"{sym}: shares must be >= 0")
            cost = str(r.get("cost_basis", "")).strip()
            if cost:
                cost = str(float(cost))
            lines.append(f"{sym},{shares:g},{cost}")
        with open(self.path("holdings", "data/portfolio.csv"), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    def universe(self):
        d = self.path("daily_dir", "data/daily")
        return sorted(f[:-4] for f in os.listdir(d) if f.endswith(".csv")) if os.path.isdir(d) else []

    def sectors(self):
        p = self.path("fundamentals", "data/fundamentals.csv")
        if not os.path.exists(p):
            return {}
        with open(p, encoding="utf-8") as f:
            return {r["symbol"]: r.get("sector") or "Unknown" for r in csv.DictReader(f)}

    def nav_log(self):
        p = self.path("nav_log", "data/nav_log.csv")
        if not os.path.exists(p):
            return []
        with open(p, encoding="utf-8") as f:
            return [{"date": r["date"], "nav": float(r["nav"]), "flow": float(r.get("flow") or 0)} for r in csv.DictReader(f)]

    # -- ML models -----------------------------------------------------------
    def inference_health(self):
        url = self.read_config().get("inference_url") or "http://127.0.0.1:8766"
        try:
            with urllib.request.urlopen(url + "/health", timeout=2) as r:
                return {"reachable": True, "url": url, **json.loads(r.read())}
        except Exception as e:
            return {"reachable": False, "url": url, "error": str(e)}

    def model_forecasts(self):
        p = os.path.join(self.path("out_dir", "out"), "model_forecasts.json")
        if not os.path.exists(p):
            return None
        with open(p, encoding="utf-8") as f:
            return json.load(f)

    def milestones_done(self):
        if not os.path.exists(MILESTONES):
            return []
        with open(MILESTONES, encoding="utf-8") as f:
            return sorted({int(m) for m in re.findall(r"^## M(\d+) ", f.read(), re.M)})

    def screener_files(self):
        d = os.path.join(ROOT, "data", "fundamentals")
        return sorted(f for f in os.listdir(d) if not f.startswith(".")) if os.path.isdir(d) else []

    # -- jobs --------------------------------------------------------------
    def start(self, kind):
        with self.lock:
            if self.job["running"]:
                raise RuntimeError("a job is already running")
            self.job = {"running": True, "kind": kind, "log": "", "ok": None, "started": time.time(), "finished": None}
        threading.Thread(target=self._run, args=(kind,), daemon=True).start()

    def _exec(self, cmd):
        self.job["log"] += "$ " + " ".join(os.path.relpath(c, ROOT) if os.path.isabs(c) else c for c in cmd) + "\n"
        p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        for line in p.stdout:
            if "ld: warning" not in line:
                self.job["log"] = (self.job["log"] + line)[-200_000:]
        return p.wait() == 0

    def _run(self, kind):
        ok = True
        try:
            if kind in ("refresh", "refresh_analyze"):
                secs = self.sectors()
                args = [f"{h['symbol']}:{secs[h['symbol']]}" if h["symbol"] in secs else h["symbol"]
                        for h in self.read_holdings() if h["symbol"]]
                ok = self._exec([VENV_PY, FETCH, os.path.dirname(self.path("daily_dir", "data/daily"))] + args)
            if kind in ("forecasts", "forecasts_all"):
                ok = self._exec([ENGINE, "forecasts", self.config] + (["--all"] if kind == "forecasts_all" else []))
            if kind in ("service_start", "service_stop"):
                m = re.match(r"^https?://([^:/]+):(\d+)", self.read_config().get("inference_url") or "http://127.0.0.1:8766")
                host, port = (m.group(1), m.group(2)) if m else ("127.0.0.1", "8766")
                ok = self._exec(["make", "up-bg" if kind == "service_start" else "down", f"INFER_HOST={host}", f"INFER_PORT={port}"])
            if ok and kind in ("analyze", "refresh_analyze"):
                if not os.path.exists(ENGINE):
                    ok = self._exec(["dune", "build"])
                ok = ok and self._exec([ENGINE, "analyze", self.config])
        except Exception as e:  # surface in the UI log
            self.job["log"] += f"\nerror: {e}\n"
            ok = False
        self.job.update(running=False, ok=ok, finished=time.time())


class Handler(BaseHTTPRequestHandler):
    state: State = None

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_GET(self):
        s = self.state
        try:
            if self.path in ("/", "/index.html"):
                with open(os.path.join(ROOT, "web", "index.html"), "rb") as f:
                    return self.send(200, f.read(), "text/html; charset=utf-8")
            if self.path == "/api/report":
                p = os.path.join(s.path("out_dir", "out"), "report.json")
                if not os.path.exists(p):
                    return self.send(404, {"error": "no report yet - run an analysis"})
                with open(p, "rb") as f:
                    return self.send(200, f.read())
            if self.path == "/api/state":
                cfg = s.read_config()
                return self.send(200, {
                    "config_path": os.path.relpath(s.config, ROOT), "holdings": s.read_holdings(),
                    "settings": {k: cfg.get(k, "") for k in EDITABLE}, "universe": s.universe(),
                    "nav_log": s.nav_log(), "currency": cfg.get("currency", "$")})
            if self.path == "/api/models":
                return self.send(200, {"health": s.inference_health(), "forecasts": s.model_forecasts(),
                                       "milestones_done": s.milestones_done(), "screener_files": s.screener_files()})
            if self.path == "/api/job":
                return self.send(200, s.job)
            return self.send(404, {"error": "not found"})
        except Exception as e:
            return self.send(500, {"error": str(e)})

    def do_POST(self):
        s = self.state
        # same-origin guard: the API only accepts JSON from the page itself
        if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            return self.send(415, {"error": "JSON only"})
        origin = self.headers.get("Origin")
        if origin and not re.match(r"^http://(127\.0\.0\.1|localhost):\d+$", origin):
            return self.send(403, {"error": "cross-origin request refused"})
        try:
            b = self.body()
            if self.path == "/api/holdings":
                s.write_holdings(b.get("rows", []))
                if "cash" in b:
                    s.write_config({"cash": b["cash"]})
                return self.send(200, {"ok": True})
            if self.path == "/api/settings":
                s.write_config(b.get("settings", {}))
                return self.send(200, {"ok": True})
            if self.path == "/api/run":
                kind = b.get("kind", "analyze")
                if kind not in JOBS:
                    raise ValueError("unknown job")
                s.start(kind)
                return self.send(202, {"ok": True})
            return self.send(404, {"error": "not found"})
        except (ValueError, RuntimeError) as e:
            return self.send(400, {"error": str(e)})
        except Exception as e:
            return self.send(500, {"error": str(e)})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(ROOT, "india", "config.ini"))
    ap.add_argument("--port", type=int, default=8765)
    a = ap.parse_args()
    Handler.state = State(a.config)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print(f"Portfolio UI on http://127.0.0.1:{a.port}  (config: {os.path.relpath(Handler.state.config, ROOT)})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
