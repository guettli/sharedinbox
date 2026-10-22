#!/usr/bin/env python3
"""HTTP control API for exploratory testing of the Linux debug build.

Runs inside the ExploreLinux Dagger service (ci/main.go), after
explore_entrypoint.sh has started Xvfb and the accessibility bus. It owns the
app process and wraps scripts/gui_driver.py, so an agent on the host — which
has no Flutter SDK, no X server and no AT-SPI — can drive the app with curl:

    curl -s localhost:8765/texts
    curl -s localhost:8765/click --data-urlencode name='Add account'
    curl -s localhost:8765/shot -o shot.png

Every endpoint takes its parameters as query string or form body, GET or POST.
Form values are URL-decoded, so send them with --data-urlencode: with plain -d
a "+" arrives as a space and "&" splits the value. Any unknown path, e.g.
GET /, returns this text. See EXPLORATORY-TESTING.md for the workflow.

    GET  /health          app pid, running, exit code
    GET  /texts           what is on screen, flat, one node per line:
                          role [checked, focused, selected, expanded,
                          disabled, read-only]: name, plus the content of
                          text nodes
    GET  /tree?max=N      the same nodes with their hierarchy (default 2000)
    GET  /shot            PNG screenshot of the whole virtual screen
    GET  /log?lines=N     tail of the app's stdout/stderr (assertions land here)
    POST /click           name, [role], [index], [contains=1], [force=1],
                          [timeout]
                          activate by accessible name; contains=1 matches a
                          substring, index picks among matches in tree order,
                          force=1 clicks a node reported as disabled
    POST /click-unnamed   [role], [index] — for widgets without a label
    POST /focus           name, [role], [index], [contains=1], [timeout]
    POST /fill            name, text, [role], [index], [contains=1], [timeout]
                          focus, select all, type
    POST /type            text — type into the focused widget
    POST /key             key — xdotool key name, e.g. Return, ctrl+a, Escape
    POST /tap             x, y — pixel click, last resort (prefer /click)
    POST /press           x, y, [ms] — hold the button for ms (default 800,
                          at most 10000): a long press, e.g. to select a mail
    POST /drag            x, y, to_x, to_y, [ms], [hold=1] — press, move,
                          release over ms (default 400): a swipe, e.g. a list
                          row's actions. hold=1 keeps the button down (take a
                          /shot); the next /drag goes on from where it is and
                          ignores its x, y; /tap and /press refuse meanwhile
    POST /restart         [wipe=1] — restart the app; wipe=1 also removes its
                          data and the keyring, like a fresh install

A lookup waits up to `timeout` seconds (default 20) for its node. Only one
request at a time talks to the accessibility bus, so a long wait blocks the
other GUI calls (refused as "busy" after 30 s); /health, /log and /shot always
answer, and /restart does not wait for the bus. Driver
errors come back as HTTP 409 with the message, which for "not found" includes
the accessibility tree (truncated at 400 nodes); anything unexpected is a 500
with the traceback.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
# wiping the XDG data and cache roots is both simpler and certain. That
# includes ~/.local/share/keyrings: the keyring holds the account passwords
# and the database cipher key, so keeping it would not be a fresh install.
DATA_ROOTS = [Path.home() / ".local/share", Path.home() / ".cache"]
KEYRING_PASSWORD = b"explore"

_app: subprocess.Popen | None = None


def start_keyring() -> None:
    """(Re)start the Secret Service flutter_secure_storage writes to.

    --replace takes over the bus name from a running daemon, so this also
    serves a wipe: the new daemon starts from the now-empty keyrings directory.
    """
    subprocess.run(
        ["gnome-keyring-daemon", "--replace", "--unlock", "--components=secrets"],
        input=KEYRING_PASSWORD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        check=True,
    )


def start_app() -> None:
    global _app
    # The child keeps its own copy of the descriptor.
    with LOG.open("ab") as log:
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


def wipe_data() -> list[str]:
    """Remove everything under DATA_ROOTS; return what could not be removed."""
    failures: list[str] = []

    def record(_func, path, exc) -> None:
        failures.append(f"{path}: {exc}")

    for root in DATA_ROOTS:
        for child in root.glob("*"):
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child, onexc=record)
                continue
            try:
                child.unlink()
            except OSError as exc:
                failures.append(f"{child}: {exc}")
    return failures


def _int(params: dict, key: str, default: int) -> int:
    return int(params.get(key, default))


def _role(params: dict) -> str | None:
    return params.get("role") or None


def _flag(params: dict, key: str) -> bool:
    return params.get(key) in ("1", "true", "yes")


def _contains(params: dict) -> bool:
    return _flag(params, "contains")


def _timeout(params: dict) -> float:
    return float(params.get("timeout", g.DEFAULT_TIMEOUT))


# States worth seeing when reading the screen as text; the rest (visible,
# showing, sensitive, ...) hold for nearly every node and only add noise.
_STATES = {
    "checked": "STATE_CHECKED",
    "focused": "STATE_FOCUSED",
    "selected": "STATE_SELECTED",
    "expanded": "STATE_EXPANDED",
}
_ACTIONABLE = {"push button", "toggle button", "check box", "radio button",
               "text", "password text"}


def _states(node) -> str:
    states = node.getState()
    flags = [label for label, attr in _STATES.items()
             if states.contains(getattr(g.pyatspi, attr))]
    if node.getRoleName() in _ACTIONABLE and not states.contains(g.pyatspi.STATE_ENABLED):
        # Selectable but non-editable text (the mail body) also reports itself
        # as not enabled; calling that "disabled" would read like a bug.
        is_text = node.getRoleName() == "text"
        flags.append("read-only" if is_text and not states.contains(g.pyatspi.STATE_EDITABLE)
                     else "disabled")
    return f" [{', '.join(flags)}]" if flags else ""


def _content(node) -> str:
    """Text a node shows but does not carry in its name.

    A SelectableText (the plain-text mail body on Linux) or a filled text
    field has no accessible name; its text is only on the Text interface.
    """
    if node.getRoleName() == "password text":
        return ""
    try:
        text = node.queryText()
    except NotImplementedError:
        return ""
    return text.getText(0, -1).strip()


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
    lines = []
    for node, _depth in g._walk(app):
        name = (node.name or "").strip()
        content = _content(node)
        if not name and not content:
            continue
        line = f"{node.getRoleName()}{_states(node)}: {name}"
        if content and content != name:
            line += f" = {content!r}"
        lines.append(line)
    return "\n".join(lines) + "\n"


def log(params: dict) -> str:
    if not LOG.exists():
        return ""
    lines = LOG.read_text(errors="replace").splitlines()
    return "\n".join(lines[-max(1, _int(params, "lines", 100)):]) + "\n"


def click(params: dict) -> str:
    node = g.click(params["name"], _role(params), _timeout(params),
                   index=_int(params, "index", 0), contains=_contains(params),
                   force=_flag(params, "force"))
    return f"clicked {node.getRoleName()}: {node.name!r}\n"


def click_unnamed(params: dict) -> str:
    node = g.click_unnamed(params.get("role", "push button"), _int(params, "index", 0))
    return f"clicked unnamed {node.getRoleName()}\n"


def focus(params: dict) -> str:
    node = g.focus(params["name"], _role(params), _int(params, "index", 0),
                   contains=_contains(params), timeout=_timeout(params))
    return f"focused {node.getRoleName()}: {node.name!r}\n"


def fill(params: dict) -> str:
    g.fill(params["name"], params["text"], params.get("role", "text"),
           _int(params, "index", 0), contains=_contains(params),
           timeout=_timeout(params))
    return "filled\n"


def type_(params: dict) -> str:
    g.type_text(params["text"])
    return "typed\n"


def key(params: dict) -> str:
    g.press(params["key"])
    return "pressed\n"


def _pixels(params: dict, *keys: str) -> list[str]:
    # Whole non-negative pixels only: anything else is a caller mistake, and a
    # value starting with "-" would be read by xdotool as an option.
    values = [params[k] for k in keys]
    if not all(v.isdigit() for v in values):
        raise ValueError(f"{', '.join(keys)} must be non-negative integers, got {values!r}")
    return values


def _xdotool(*args: str) -> None:
    subprocess.run(["xdotool", *args], check=True)


def _ms(params: dict, default: int) -> float:
    # Seconds to hold or move for. Capped well below GUI_LOCK_WAIT: the gesture
    # holds the bus lock, and every other GUI call waits for it.
    return min(max(0, _int(params, "ms", default)), 10_000) / 1000


# Where a /drag with hold=1 left the button down, or None. The next /drag
# goes on from there instead of pressing again; /tap and /press refuse
# until it is released, since their own click would let go of it unseen.
_held_at: tuple[int, int] | None = None


def _refuse_while_held() -> None:
    if _held_at is not None:
        raise g.GuiError(
            "the button is held by a /drag with hold=1; finish it with a /drag "
            "without hold (or /restart) first"
        )


def tap(params: dict) -> str:
    x, y = _pixels(params, "x", "y")
    _refuse_while_held()
    _xdotool("mousemove", x, y, "click", "1")
    return "tapped\n"


def press(params: dict) -> str:
    x, y = _pixels(params, "x", "y")
    _refuse_while_held()
    _xdotool("mousemove", x, y, "mousedown", "1")
    try:
        time.sleep(_ms(params, 800))
    finally:
        _xdotool("mouseup", "1")
    return "long-pressed\n"


def drag(params: dict) -> str:
    global _held_at
    to_x, to_y = (int(v) for v in _pixels(params, "to_x", "to_y"))
    if _held_at is None:
        x, y = (int(v) for v in _pixels(params, "x", "y"))
        _xdotool("mousemove", str(x), str(y), "mousedown", "1")
    else:
        x, y = _held_at
    _held_at = (x, y)
    # Flutter only sees a drag when the pointer moves while down, so walk
    # there in steps rather than jumping: one jump reads as a tap elsewhere.
    steps = 10
    pause = _ms(params, 400) / steps
    try:
        for i in range(1, steps + 1):
            time.sleep(pause)
            _held_at = (x + (to_x - x) * i // steps, y + (to_y - y) * i // steps)
            _xdotool("mousemove", *map(str, _held_at))
    finally:
        if not _flag(params, "hold"):
            _xdotool("mouseup", "1")
            _held_at = None
    return "dragged, button still down\n" if _held_at else "dragged\n"


def restart(params: dict) -> str:
    global _held_at
    # Unconditionally: a /drag may be setting _held_at right now (restart
    # does not take the bus lock), and a spare mouseup is harmless.
    _xdotool("mouseup", "1")
    _held_at = None
    stop_app()
    if _flag(params, "wipe"):
        failures = wipe_data()
        if failures:
            raise g.GuiError("wipe incomplete, app not restarted:\n" + "\n".join(failures))
        start_keyring()
    start_app()
    return "restarted\n" + health(params)


# Requests are served on their own threads, but only one at a time may talk to
# the accessibility bus. A slow lookup then blocks the other GUI routes, but not
# the ones below: /health, /log and /shot show what the app is doing, and
# /restart (which does not touch the bus) kills it, which also ends a stuck
# walk. A lookup itself is bounded by its timeout, checked per node.
_GUI_LOCK = threading.Lock()
# Restarts must not overlap either: two would start two apps, one orphaned.
_RESTART_LOCK = threading.Lock()
LOCK_FREE = {"/health", "/log", "/shot"}
# A GUI call that cannot get the bus within this long is refused rather than
# queued: run later, it would act on whatever screen is up by then.
GUI_LOCK_WAIT = 30.0

ROUTES = {
    "/health": health, "/tree": tree, "/texts": texts, "/log": log,
    "/click": click, "/click-unnamed": click_unnamed, "/focus": focus,
    "/fill": fill, "/type": type_, "/key": key, "/tap": tap,
    "/press": press, "/drag": drag,
    "/restart": restart,
}


def screenshot(_: dict) -> bytes:
    with tempfile.NamedTemporaryFile(suffix=".png") as f:
        g.screenshot(f.name)
        return Path(f.name).read_bytes()


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
        # Every failure must reach the caller as a response: an exception that
        # escapes here drops the connection, and `curl -s` then shows nothing.
        try:
            path = urlparse(self.path).path
            params = self._params()
            if path == "/shot":
                self._send(200, screenshot(params), "image/png")
                return
            route = ROUTES.get(path)
            if route is None:
                self._send(404, (__doc__ or "").encode())
                return
            if path in LOCK_FREE:
                body = route(params)
            elif path == "/restart":
                with _RESTART_LOCK:
                    body = route(params)
            else:
                if not _GUI_LOCK.acquire(timeout=GUI_LOCK_WAIT):
                    raise g.GuiError(
                        f"busy: another call has held the accessibility bus for "
                        f"over {GUI_LOCK_WAIT:.0f}s; check /shot and /log, or /restart"
                    )
                try:
                    body = route(params)
                finally:
                    _GUI_LOCK.release()
            self._send(200, body.encode())
        except (g.GuiError, KeyError, ValueError, subprocess.CalledProcessError) as exc:
            self._send(409, f"{type(exc).__name__}: {exc}\n".encode())
        except Exception:  # noqa: BLE001 — e.g. GLib.GError when a node vanishes mid-walk
            self._send(500, traceback.format_exc().encode())

    do_GET = _handle
    do_POST = _handle

    def log_message(self, fmt: str, *args) -> None:  # keep the service log quiet
        return


def main() -> None:
    start_keyring()
    start_app()
    print(f"explore server on :{PORT}, app {APP}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
