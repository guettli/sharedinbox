#!/usr/bin/env python3
"""HTTP control API for exploratory testing of the Linux debug build.

Runs inside the ExploreLinux Dagger service (ci/main.go), after
explore_entrypoint.sh has started Xvfb and the accessibility bus. It owns the
app process and wraps scripts/gui_driver.py, so an agent on the host — which
has no Flutter SDK, no X server and no AT-SPI — can drive the app with curl:

    curl -s localhost:8765/tree
    curl -s localhost:8765/click -d name='Add account'
    curl -s localhost:8765/fill -d name='Email address' -d text=bob@example.com
    curl -s localhost:8765/shot -o shot.png

Every endpoint takes its parameters as query string or form body, GET or POST.
See EXPLORATORY-TESTING.md for the full workflow.

    GET  /health          app pid, running, exit code
    GET  /tree            accessibility tree (role: name), the main way to "see"
    GET  /texts           only the named nodes, flat, one per line, with
                          [checked, focused, selected, expanded, disabled]
    GET  /shot            PNG screenshot of the whole virtual screen
    GET  /log?lines=N     tail of the app's stdout/stderr (assertions land here)
    POST /click           name, [role], [index], [contains=1] — activate by
                          accessible name; contains=1 matches a substring
    POST /click-unnamed   [role], [index] — for widgets without a label
    POST /focus           name, [role], [index]
    POST /fill            name, text, [role], [index] — focus, select all, type
    POST /type            text — type into the focused widget
    POST /key             key — xdotool key name, e.g. Return, ctrl+a, Escape
    POST /tap             x, y — pixel click, last resort (prefer /click)
    POST /restart         [wipe=1] — restart the app, optionally with no data

Errors come back as HTTP 409 with the driver's message, which for "not found"
includes the accessibility tree.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gui_driver as g  # noqa: E402

APP = os.environ.get("EXPLORE_APP", "/app/sharedinbox")
PORT = int(os.environ.get("EXPLORE_PORT", "8765"))
LOG = Path("/tmp/app.log")
# /restart?wipe=1 empties these. The app's database lives in path_provider's
# application support directory under ~/.local/share, whose name depends on
# path_provider's app-id lookup; the container belongs to the app alone, so
# wiping the XDG data and cache roots is both simpler and certain. The keyring
# is kept so the Secret Service daemon keeps working; the passwords left in it
# belong to accounts the wiped app no longer knows.
DATA_ROOTS = [Path.home() / ".local/share", Path.home() / ".cache"]
KEEP = {"keyrings"}

_app: subprocess.Popen | None = None


def start_app() -> None:
    global _app
    log = LOG.open("ab")
    _app = subprocess.Popen([APP], stdout=log, stderr=subprocess.STDOUT)


def stop_app() -> None:
    if _app is None or _app.poll() is not None:
        return
    _app.terminate()
    try:
        _app.wait(10)
    except subprocess.TimeoutExpired:
        _app.kill()
        _app.wait()


def _int(params: dict, key: str, default: int = 0) -> int:
    return int(params.get(key, default))


def _role(params: dict) -> str | None:
    return params.get("role") or None


def _contains(params: dict) -> bool:
    return params.get("contains") in ("1", "true", "yes")


# States worth seeing when reading the screen as text; the rest (visible,
# showing, sensitive, ...) hold for nearly every node and only add noise.
_STATES = {
    "checked": "STATE_CHECKED",
    "focused": "STATE_FOCUSED",
    "selected": "STATE_SELECTED",
    "expanded": "STATE_EXPANDED",
}


def _states(node) -> str:
    states = node.getState()
    flags = [label for label, attr in _STATES.items()
             if states.contains(getattr(g.pyatspi, attr))]
    actionable = node.getRoleName() in ("push button", "toggle button", "check box",
                                        "radio button", "text", "password text")
    if actionable and not states.contains(g.pyatspi.STATE_ENABLED):
        flags.append("disabled")
    return f" [{', '.join(flags)}]" if flags else ""


def health(_: dict) -> str:
    running = _app is not None and _app.poll() is None
    code = None if _app is None else _app.poll()
    return f"pid={_app.pid if _app else None} running={running} exit={code}\n"


def tree(params: dict) -> str:
    return g.dump_tree(max_nodes=_int(params, "max", 2000)) + "\n"


def texts(_: dict) -> str:
    app = g._app_root()
    if app is None:
        return "<app not on the accessibility bus>\n"
    lines = [
        f"{node.getRoleName()}{_states(node)}: {node.name.strip()}"
        for node, _ in g._walk(app)
        if (node.name or "").strip()
    ]
    return "\n".join(lines) + "\n"


def log(params: dict) -> str:
    if not LOG.exists():
        return ""
    lines = LOG.read_text(errors="replace").splitlines()
    return "\n".join(lines[-_int(params, "lines", 100):]) + "\n"


def click(params: dict) -> str:
    node = g.click(params["name"], _role(params), index=_int(params, "index"),
                   contains=_contains(params))
    return f"clicked {node.getRoleName()}: {node.name!r}\n"


def click_unnamed(params: dict) -> str:
    node = g.click_unnamed(params.get("role", "push button"), _int(params, "index"))
    return f"clicked unnamed {node.getRoleName()}\n"


def focus(params: dict) -> str:
    node = g.focus(params["name"], _role(params), _int(params, "index"),
                   contains=_contains(params))
    return f"focused {node.getRoleName()}: {node.name!r}\n"


def fill(params: dict) -> str:
    g.fill(params["name"], params["text"], params.get("role", "text"),
           _int(params, "index"), contains=_contains(params))
    return "filled\n"


def type_(params: dict) -> str:
    g.type_text(params["text"])
    return "typed\n"


def key(params: dict) -> str:
    g.press(params["key"])
    return "pressed\n"


def tap(params: dict) -> str:
    subprocess.run(["xdotool", "mousemove", params["x"], params["y"], "click", "1"],
                   check=True)
    return "tapped\n"


def restart(params: dict) -> str:
    stop_app()
    if params.get("wipe") in ("1", "true", "yes"):
        for root in DATA_ROOTS:
            for child in root.glob("*"):
                if child.name in KEEP:
                    continue
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child, ignore_errors=True)
                    continue
                child.unlink(missing_ok=True)
    start_app()
    return "restarted\n" + health(params)


ROUTES = {
    "/health": health, "/tree": tree, "/texts": texts, "/log": log,
    "/click": click, "/click-unnamed": click_unnamed, "/focus": focus,
    "/fill": fill, "/type": type_, "/key": key, "/tap": tap,
    "/restart": restart,
}


class Handler(BaseHTTPRequestHandler):
    def _params(self) -> dict:
        url = urlparse(self.path)
        raw = url.query
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            raw += "&" + self.rfile.read(length).decode()
        return {k: v[-1] for k, v in parse_qs(raw, keep_blank_values=True).items()}

    def _send(self, code: int, body: bytes, ctype: str = "text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self) -> None:
        path = urlparse(self.path).path
        params = self._params()
        if path == "/shot":
            with tempfile.NamedTemporaryFile(suffix=".png") as f:
                g.screenshot(f.name)
                self._send(200, Path(f.name).read_bytes(), "image/png")
            return
        route = ROUTES.get(path)
        if route is None:
            self._send(404, (__doc__ or "").encode())
            return
        try:
            self._send(200, route(params).encode())
        except (g.GuiError, KeyError, ValueError, subprocess.CalledProcessError) as exc:
            self._send(409, f"{type(exc).__name__}: {exc}\n".encode())

    do_GET = _handle
    do_POST = _handle

    def log_message(self, fmt: str, *args) -> None:  # keep the service log quiet
        return


def main() -> None:
    start_app()
    print(f"explore server on :{PORT}, app {APP}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
