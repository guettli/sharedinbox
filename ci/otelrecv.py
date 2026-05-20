#!/usr/bin/env python3
"""
Pipe filter for dagger --progress=plain timing analysis.

Usage:
    dagger call --progress=plain ... 2>&1 | python3 ci/otelrecv.py

Echoes every line to stdout in real-time, then prints a timing table sorted
by duration when stdin closes.
"""

import re
import sys

_ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
# Matches completed span lines: "Container.withExec CACHED [1.23s]"
_TIMING = re.compile(r"([\w.]+)\s+(CACHED\s+)?\[(\d+\.?\d*)s\]$")

rows = []
for line in sys.stdin:
    sys.stdout.write(line)
    sys.stdout.flush()
    clean = _ANSI.sub("", line).rstrip()
    m = _TIMING.search(clean)
    if m:
        dur = float(m.group(3))
        if dur > 0:
            rows.append(
                {
                    "name": m.group(1),
                    "cached": bool(m.group(2)),
                    "dur": dur,
                }
            )

if not rows:
    sys.exit(0)

rows.sort(key=lambda r: r["dur"], reverse=True)

NAME_W, ATTR_W = 38, 6
print(f'\n{"STATUS":<6}  {"DURATION":>8}  SPAN')
print("─" * (6 + 2 + 8 + 2 + NAME_W + 20))
for r in rows:
    status = "CACHED" if r["cached"] else "LIVE"
    name = r["name"]
    if len(name) > NAME_W:
        name = name[: NAME_W - 1] + "…"
    print(f'{status:<6}  {r["dur"]:7.2f}s  {name}')
print(f"\n{len(rows)} spans total")
