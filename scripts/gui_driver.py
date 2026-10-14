#!/usr/bin/env python3
"""Drive the packaged Linux app through its accessibility tree.

Why AT-SPI and not screenshots
------------------------------
The release bundle is a stripped `--release` build: there is no VM service, so
`flutter drive` and the integration_test harness cannot attach to it. They test
the *source tree*; this tests the *artifact users install*. That gap is real —
it is how a packaging bug shipped a build whose ChangeLog screen could not load
its asset while every source-level test stayed green (#932).

The remaining options for driving a stripped binary are pixel coordinates, OCR,
and the accessibility tree. The accessibility tree wins on every axis: exact
strings instead of OCR guesses, real roles so a label cannot be mistaken for a
button, widget states (is it actually *enabled*?), and `doAction` instead of
computing a pixel centre and hoping nothing overlaps it.

It also pays for itself twice: a suite driven through the accessibility tree is
an accessibility regression test. A button that ships without a semantic label
cannot be found here, so the test fails — which is exactly what a screen-reader
user would experience.

Requirements (see GuiTestRelease in ci/main.go for the container recipe):
  * at-spi2-core, python3-pyatspi, libglib2.0-bin, gsettings-desktop-schemas,
    dconf-service
  * a session bus (dbus-daemon) shared by the app and this process
  * org.gnome.desktop.a11y.applications screen-reader-enabled = true, which is
    what makes Flutter build its semantics tree at all
"""
from __future__ import annotations

import subprocess
import sys
import time

import pyatspi

# Flutter exposes plain text as `panel` nodes with the text as the accessible
# name, so a text assertion has to consider every role rather than a label role.
DEFAULT_TIMEOUT = 20.0
POLL_INTERVAL = 0.4


class GuiError(AssertionError):
    """A driving or assertion failure, reported with the tree for context."""


def _app_root(app_name: str = "sharedinbox"):
    desktop = pyatspi.Registry.getDesktop(0)
    for app in desktop:
        if app is not None and (app.name or "") == app_name:
            return app
    return None


def _walk(node, depth: int = 0, max_depth: int = 40):
    """Yield (node, depth) for the whole subtree.

    The depth limit is deliberately generous: Flutter's widgets sit roughly
    nine levels below the GTK frame, and a tighter limit silently truncates the
    tree just above them — which looks exactly like "the app exposes nothing".
    """
    if depth > max_depth:
        return
    for child in node:
        if child is None:
            continue
        yield child, depth
        yield from _walk(child, depth + 1, max_depth)


def dump_tree(app_name: str = "sharedinbox", max_nodes: int = 400) -> str:
    """Render the accessibility tree. Used for diagnosis and failure output."""
    app = _app_root(app_name)
    if app is None:
        return f"<no application named {app_name!r} on the accessibility bus>"
    lines = [f"APP: {app.name}"]
    for i, (node, depth) in enumerate(_walk(app)):
        if i >= max_nodes:
            lines.append("  ... (truncated)")
            break
        name = (node.name or "").strip()
        role = node.getRoleName()
        lines.append("  " * depth + f"- {role}" + (f": {name!r}" if name else ""))
    return "\n".join(lines)


def find_all(name: str, role: str | None = None, app_name: str = "sharedinbox") -> list:
    """Every node whose accessible name matches exactly, in tree order.

    Forms repeat labels: the account form has two fields called 'Host' and two
    called 'Port', one pair under IMAP and one under SMTP. Tree order matches
    visual order, so the index selects between them.
    """
    app = _app_root(app_name)
    if app is None:
        return []
    return [
        node for node, _ in _walk(app)
        if (node.name or "").strip() == name and (role is None or node.getRoleName() == role)
    ]


def find(name: str, role: str | None = None, app_name: str = "sharedinbox", index: int = 0):
    """Return the index-th node whose accessible name matches exactly."""
    matches = find_all(name, role, app_name)
    return matches[index] if len(matches) > index else None


def find_containing(substring: str, role: str | None = None, app_name: str = "sharedinbox"):
    """Return the first node whose accessible name contains `substring`."""
    app = _app_root(app_name)
    if app is None:
        return None
    for node, _ in _walk(app):
        if substring in (node.name or "") and (role is None or node.getRoleName() == role):
            return node
    return None


def wait_for(name: str, role: str | None = None, timeout: float = DEFAULT_TIMEOUT,
             contains: bool = False, index: int = 0):
    """Block until a matching node appears, or raise with the tree attached."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        node = (find_containing(name, role) if contains
                else find(name, role, index=index))
        if node is not None:
            return node
        time.sleep(POLL_INTERVAL)
    how = "containing" if contains else "named"
    raise GuiError(
        f"timed out after {timeout:.0f}s waiting for a node {how} {name!r}"
        + (f" with role {role!r}" if role else "")
        + "\n\nAccessibility tree was:\n" + dump_tree()
    )


def assert_text(substring: str, timeout: float = DEFAULT_TIMEOUT) -> None:
    """Assert some node's accessible name contains `substring`."""
    wait_for(substring, timeout=timeout, contains=True)


def assert_absent(substring: str) -> None:
    node = find_containing(substring)
    if node is not None:
        raise GuiError(
            f"expected no node containing {substring!r}, found "
            f"{node.getRoleName()} {node.name!r}\n\n" + dump_tree()
        )


def click(name: str, role: str | None = None, timeout: float = DEFAULT_TIMEOUT,
          index: int = 0):
    """Activate a widget through its own action, not a pixel coordinate."""
    node = wait_for(name, role, timeout, index=index)
    states = node.getState()
    if not states.contains(pyatspi.STATE_ENABLED):
        raise GuiError(f"{name!r} is present but not enabled; cannot click it")
    action = node.queryAction()
    names = [action.getName(i) for i in range(action.nActions)]
    # Flutter names its primary action "Tap"; GTK widgets use "click".
    for candidate in ("Tap", "click", "activate", "press"):
        if candidate in names:
            action.doAction(names.index(candidate))
            return node
    if names:
        action.doAction(0)
        return node
    raise GuiError(f"{name!r} exposes no actions (roles={node.getRoleName()})")


def click_unnamed(role: str = "push button", index: int = 0):
    """Activate the index-th widget of `role` that has no accessible name.

    Needed only for the app-bar icon buttons (drawer, search, back), which ship
    without semantic labels — a screen-reader user hears nothing useful for
    them either. Prefer click() by name everywhere else; every use of this
    function marks a widget that ought to have a label.
    """
    app = _app_root()
    if app is None:
        raise GuiError("application is not on the accessibility bus")
    matches = [
        node for node, _ in _walk(app)
        if node.getRoleName() == role and not (node.name or "").strip()
    ]
    if len(matches) <= index:
        raise GuiError(
            f"wanted unnamed {role} #{index}, found {len(matches)}\n\n" + dump_tree()
        )
    matches[index].queryAction().doAction(0)
    return matches[index]


def focus(name: str, role: str | None = None, index: int = 0):
    node = wait_for(name, role, index=index)
    action = node.queryAction()
    names = [action.getName(i) for i in range(action.nActions)]
    if "Focus" in names:
        action.doAction(names.index("Focus"))
    else:
        node.queryComponent().grabFocus()
    return node


def fill(name: str, text: str, role: str | None = "text", index: int = 0) -> None:
    """Focus a field and replace its contents."""
    focus(name, role, index=index)
    press("ctrl+a")
    type_text(text)


def type_text(text: str) -> None:
    """Type into whatever currently has focus.

    Flutter's text fields do not implement the EditableText interface, so
    synthetic key events are the only route. xdotool talks to the same X server,
    and the app receives them exactly as it would a real keyboard.
    """
    subprocess.run(["xdotool", "type", "--delay", "40", text], check=True)


def press(key: str) -> None:
    subprocess.run(["xdotool", "key", key], check=True)


def screenshot(path: str) -> None:
    subprocess.run(["import", "-window", "root", path], check=True)


def main(argv: list[str]) -> int:
    """Small CLI, for exploring a running app by hand."""
    if len(argv) < 2:
        print(__doc__)
        print("usage: gui_driver.py dump|click|find|type|screenshot [args]")
        return 2
    cmd = argv[1]
    if cmd == "dump":
        print(dump_tree())
    elif cmd == "find":
        node = find_containing(argv[2])
        print(f"{node.getRoleName()}: {node.name!r}" if node else "NOT FOUND")
    elif cmd == "click":
        node = click(argv[2], argv[3] if len(argv) > 3 else None)
        print(f"clicked {node.getRoleName()}: {node.name!r}")
    elif cmd == "type":
        type_text(argv[2])
    elif cmd == "screenshot":
        screenshot(argv[2])
    else:
        print(f"unknown command {cmd!r}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
