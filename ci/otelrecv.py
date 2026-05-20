#!/usr/bin/env python3
"""
Minimal OTLP HTTP/protobuf trace receiver for Dagger CI timing.

Usage:
    python3 ci/otelrecv.py --port-file=/tmp/otel.port

Caller sets:
    OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:<port>
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
"""

import argparse
import signal
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


# ── Minimal protobuf binary decoder ─────────────────────────────────────────
# Only decodes the fields we need; skips everything else safely.

def _varint(buf, pos):
    n, shift = 0, 0
    while pos < len(buf):
        b = buf[pos]; pos += 1
        n |= (b & 0x7F) << shift
        shift += 7
        if not (b & 0x80):
            return n, pos
    raise ValueError("truncated varint")


def _fields(buf):
    """Yield (field_num, wire_type, raw_value) for each field in a message."""
    pos = 0
    while pos < len(buf):
        tag, pos = _varint(buf, pos)
        wt, fn = tag & 7, tag >> 3
        if wt == 0:                                          # varint
            v, pos = _varint(buf, pos)
        elif wt == 1:                                        # fixed64
            v = struct.unpack_from("<Q", buf, pos)[0]; pos += 8
        elif wt == 2:                                        # length-delimited
            n, pos = _varint(buf, pos)
            v = buf[pos:pos + n]; pos += n
        elif wt == 5:                                        # fixed32
            v = struct.unpack_from("<I", buf, pos)[0]; pos += 4
        else:
            break                                            # unknown: stop
        yield fn, wt, v


def _any_value(buf):
    """Parse AnyValue, return (type_tag, python_value)."""
    for fn, wt, v in _fields(buf):
        if fn == 1 and wt == 2:                              # string_value
            return "str", v.decode("utf-8", errors="replace")
        if fn == 2 and wt == 0:                              # bool_value
            return "bool", bool(v)
        if fn == 3 and wt == 0:                              # int_value (sint64)
            return "int", v
        if fn == 4 and wt == 1:                              # double_value
            return "float", struct.unpack("<d", struct.pack("<Q", v))[0]
    return None, None


def _keyvalue(buf):
    key, tag, val = None, None, None
    for fn, wt, v in _fields(buf):
        if fn == 1 and wt == 2:
            key = v.decode("utf-8", errors="replace")
        elif fn == 2 and wt == 2:
            tag, val = _any_value(v)
    return key, tag, val


def _span(buf):
    name = ""
    start_ns = end_ns = 0
    cached = False
    for fn, wt, v in _fields(buf):
        if fn == 5 and wt == 2:                              # name
            name = v.decode("utf-8", errors="replace")
        elif fn == 7 and wt == 1:                            # start_time_unix_nano
            start_ns = v
        elif fn == 8 and wt == 1:                            # end_time_unix_nano
            end_ns = v
        elif fn == 9 and wt == 2:                            # attributes (repeated)
            k, tag, val = _keyvalue(v)
            if tag == "bool" and k and "cached" in k.lower():
                cached = val
    return {"name": name, "dur": max(0.0, (end_ns - start_ns) / 1e9), "cached": cached}


def _decode(body):
    spans = []
    for fn1, wt1, rs in _fields(body):                      # resource_spans = 1
        if fn1 != 1 or wt1 != 2:
            continue
        for fn2, wt2, ss in _fields(rs):                    # scope_spans = 2
            if fn2 != 2 or wt2 != 2:
                continue
            for fn3, wt3, sp in _fields(ss):                # spans = 2
                if fn3 == 2 and wt3 == 2:
                    spans.append(_span(sp))
    return spans


# ── HTTP receiver ────────────────────────────────────────────────────────────

_spans = []
_lock = threading.Lock()


class _Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/traces":
            self.send_response(404); self.end_headers(); return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            decoded = _decode(body)
        except Exception as exc:
            self.send_response(400); self.end_headers()
            self.wfile.write(str(exc).encode()); return
        with _lock:
            _spans.extend(decoded)
        self.send_response(200); self.end_headers()

    def log_message(self, *_):
        pass


# ── Timing report ────────────────────────────────────────────────────────────

def _report():
    with _lock:
        if not _spans:
            print("otelrecv: no spans received", file=sys.stderr)
            return
        rows = sorted(_spans, key=lambda r: r["dur"], reverse=True)
        NAME_W = 38
        print(f'\n{"STATUS":<6}  {"DURATION":>8}  SPAN')
        print("─" * (6 + 2 + 8 + 2 + NAME_W + 20))
        for r in rows:
            status = "CACHED" if r["cached"] else "LIVE"
            name = r["name"]
            if len(name) > NAME_W:
                name = name[: NAME_W - 1] + "…"
            print(f'{status:<6}  {r["dur"]:7.2f}s  {name}')
        print(f"\n{len(rows)} spans total")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port-file", default="")
    args = ap.parse_args()

    server = HTTPServer(("127.0.0.1", 0), _Handler)
    if args.port_file:
        with open(args.port_file, "w") as f:
            f.write(str(server.server_address[1]))

    def _shutdown(sig, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    server.serve_forever()
    _report()


if __name__ == "__main__":
    main()
