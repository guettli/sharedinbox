#!/usr/bin/env python3
"""
Minimal OTLP HTTP/JSON trace receiver for Dagger CI timing.

Usage:
    python3 ci/otelrecv.py --port-file=/tmp/otel.port [--raw=/tmp/otel.json]

Listens on a random port (written to --port-file), collects OTLP spans via
HTTP/JSON, and prints a timing report on SIGTERM/SIGINT.

Caller sets:
    OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:<port>
    OTEL_EXPORTER_OTLP_PROTOCOL=http/json
"""

import argparse
import json
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

_spans = []
_lock = threading.Lock()
_raw_out = None


class _Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/traces":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if _raw_out:
            _raw_out.write(body)
            _raw_out.write(b"\n")
            _raw_out.flush()
        try:
            req = json.loads(body)
        except json.JSONDecodeError as exc:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(str(exc).encode())
            return
        with _lock:
            for rs in req.get("resourceSpans", []):
                for ss in rs.get("scopeSpans", []):
                    _spans.extend(ss.get("spans", []))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *_):
        pass


def _kv_str(value):
    if "stringValue" in value:
        return str(value["stringValue"])
    if "boolValue" in value:
        return str(value["boolValue"]).lower()
    if "intValue" in value:
        return str(value["intValue"])
    if "doubleValue" in value:
        return str(value["doubleValue"])
    return ""


def _print_report():
    with _lock:
        if not _spans:
            print(
                "otelrecv: no spans received"
                " — check OTEL_EXPORTER_OTLP_PROTOCOL=http/json is supported",
                file=sys.stderr,
            )
            return

        rows = []
        for s in _spans:
            start = int(s.get("startTimeUnixNano", 0))
            end = int(s.get("endTimeUnixNano", 0))
            dur = (end - start) / 1e9

            cached = False
            parts = []
            for attr in s.get("attributes", []):
                key = attr["key"]
                val_obj = attr.get("value", {})
                val = _kv_str(val_obj)
                if "boolValue" in val_obj and "cached" in key.lower():
                    cached = bool(val_obj["boolValue"])
                parts.append(f"{key}={val}")

            rows.append(
                {
                    "name": s.get("name", ""),
                    "dur": dur,
                    "cached": cached,
                    "attrs": "  ".join(parts),
                }
            )

        rows.sort(key=lambda r: r["dur"], reverse=True)

        name_w, attr_w = 38, 60
        print(f'\n{"STATUS":<6}  {"DURATION":>8}  {"SPAN":<{name_w}}  ATTRIBUTES')
        print("─" * (6 + 2 + 8 + 2 + name_w + 2 + attr_w))
        for r in rows:
            status = "CACHED" if r["cached"] else "LIVE"
            attrs = r["attrs"]
            if len(attrs) > attr_w:
                attrs = attrs[: attr_w - 1] + "…"
            name = r["name"]
            if len(name) > name_w:
                name = name[: name_w - 1] + "…"
            print(f"{status:<6}  {r['dur']:7.2f}s  {name:<{name_w}}  {attrs}")
        print(f"\n{len(rows)} spans total")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", default="")
    parser.add_argument("--raw", default="")
    args = parser.parse_args()

    global _raw_out
    if args.raw:
        _raw_out = open(args.raw, "wb")

    server = HTTPServer(("127.0.0.1", 0), _Handler)
    port = server.server_address[1]

    if args.port_file:
        with open(args.port_file, "w") as f:
            f.write(str(port))

    def _shutdown(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    server.serve_forever()
    _print_report()

    if _raw_out:
        _raw_out.close()


if __name__ == "__main__":
    main()
