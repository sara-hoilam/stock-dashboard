"""
server.py -- runs the quarterly financials dashboard.

    python server.py

Then open http://localhost:8787.

The SEC does not send CORS headers, so a page loaded in a browser cannot call
data.sec.gov directly. This server sits in between: it serves the dashboard and
fetches from the SEC on its behalf, identifying itself the way the SEC asks and
staying under their rate limit.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import traceback
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import envload  # noqa: F401  -- must precede edgar

import edgar

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get("PORT", "8787"))

# Built company models, keyed by ticker. Rebuilding means re-parsing several
# megabytes of XBRL, so hold onto the last few.
_models: dict[str, dict] = {}
_models_lock = threading.Lock()
_MAX_MODELS = 8


def get_model(ticker: str) -> dict:
    key = ticker.upper()
    with _models_lock:
        if key in _models:
            return _models[key]
    model = edgar.build_company(key)
    with _models_lock:
        if len(_models) >= _MAX_MODELS:
            _models.pop(next(iter(_models)))
        _models[key] = model
    return model


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write(f"  {self.address_string()} {fmt % args}\n")

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code: int = 200):
        self._send(code, json.dumps(obj).encode("utf-8"),
                   "application/json; charset=utf-8")

    def _file(self, name: str, ctype: str):
        path = os.path.join(HERE, name)
        if not os.path.exists(path):
            self._send(404, b"not found", "text/plain")
            return
        with open(path, "rb") as fh:
            self._send(200, fh.read(), ctype)

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        route = url.path

        try:
            if route in ("/", "/index.html"):
                return self._file("dashboard.html", "text/html; charset=utf-8")

            if route == "/config.js":
                # Deployed builds ship a real config.js pointing at Supabase.
                # Locally the page talks to this server instead, so an empty
                # file is the correct answer rather than a 404.
                return self._send(200, b"", "application/javascript")

            if route == "/api/search":
                term = (q.get("q") or [""])[0]
                return self._json({"results": edgar.search_tickers(term)})

            if route == "/api/company":
                ticker = (q.get("ticker") or [""])[0].strip()
                if not ticker:
                    return self._json({"error": "ticker is required"}, 400)
                model = get_model(ticker)
                # Segments are fetched per quarter, on demand, so the initial
                # payload stays small.
                slim = {k: v for k, v in model.items() if k != "filings"}
                slim["filings"] = model["filings"][:12]
                return self._json(slim)

            if route == "/api/segments":
                ticker = (q.get("ticker") or [""])[0].strip()
                end = (q.get("end") or [""])[0].strip()
                if not ticker or not end:
                    return self._json({"error": "ticker and end are required"}, 400)
                model = get_model(ticker)
                return self._json({"breakdowns": edgar.attach_segments(model, end)})

            return self._send(404, b"not found", "text/plain")

        except edgar.FetchError as exc:
            return self._json({"error": str(exc)}, 502)
        except Exception as exc:
            traceback.print_exc()
            return self._json({"error": f"{type(exc).__name__}: {exc}"}, 500)


def main():
    if edgar.CONTACT == "dashboard-user@example.com":
        print("  note: set SEC_CONTACT to your email address so the SEC can\n"
              "        identify the requests (they ask for this).\n")
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    url = f"http://localhost:{PORT}"
    print(f"  Quarterly financials dashboard -> {url}")
    print(f"  Data: SEC EDGAR (XBRL company facts + filed reports)")
    print(f"  Cache: {edgar.CACHE_DIR}")
    print("  Ctrl-C to stop.\n")
    threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  stopped.")


if __name__ == "__main__":
    main()
