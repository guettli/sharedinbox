#!/usr/bin/env python3
"""Drive the *packaged* Linux release and assert it actually works.

Run by GuiTestRelease in ci/main.go against a release installed with mise —
the same bytes a user gets — not against a build of the working tree. Source
level tests cannot cover this: `integration_test/` builds its own binary, so a
bug introduced while *packaging* is invisible to it.

That is not hypothetical. The bundle shipped without assets/changelog.txt, so
the ChangeLog screen failed at runtime with 'Unable to load asset' while every
source test stayed green, CI was green, and the smoke test (does the process
survive 12 seconds?) was green too. See #932. The changelog assertion below is
that regression, pinned.

Assertions run through the accessibility tree, so this doubles as an
accessibility test: a control that ships without a semantic label cannot be
found here and fails the run.
"""
from __future__ import annotations

import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gui_driver as g  # noqa: E402

SHOTS = os.environ.get("GUI_SHOT_DIR", "/shots")
RELEASE_VERSION = os.environ.get("RELEASE_VERSION", "")
STALWART_READY = os.environ.get("STALWART_READY", "") == "1"


def shot(name: str) -> None:
    path = os.path.join(SHOTS, f"{name}.png")
    try:
        g.screenshot(path)
        print(f"    (screenshot: {path})")
    except Exception as exc:  # never fail a test because a screenshot failed
        print(f"    (screenshot failed: {exc})")


def step(msg: str) -> None:
    print(f"==> {msg}", flush=True)


def open_drawer() -> None:
    """Open the navigation drawer and wait until it is actually open.

    The app-bar icon has no accessible name, so it is reached positionally.
    Waiting for the drawer's own landmark instead of sleeping keeps this
    deterministic: clicking during a route transition otherwise hits a node
    that is on its way out.
    """
    g.click_unnamed("push button", 0)
    g.wait_for("Navigation menu", contains=True)


def back_to_home() -> None:
    g.click_unnamed("push button", 0)  # app-bar back arrow
    g.assert_text("Welcome to sharedinbox.de")


def ensure_home(attempts: int = 5) -> None:
    """Return to the home screen whatever state the app is in.

    Without this one failure cascades: a test that aborts mid-flow leaves the
    app on some other route, and every later test fails for a reason that has
    nothing to do with what it checks — which buries the real failure.
    """
    for _ in range(attempts):
        if g.find_containing("Welcome to sharedinbox.de") is not None:
            return
        try:
            g.press("Escape")   # dismiss a drawer or dialog
            time.sleep(0.6)
            if g.find_containing("Welcome to sharedinbox.de") is not None:
                return
            g.click_unnamed("push button", 0)  # back arrow on a sub-route
        except Exception:
            pass
        time.sleep(1.2)
    raise g.GuiError(
        "could not get back to the home screen\n\n" + g.dump_tree()
    )


def test_welcome_screen() -> None:
    step("welcome screen renders with reachable controls")
    g.assert_text("Welcome to sharedinbox.de")
    g.assert_text("Connect your IMAP or JMAP email account")
    # Present *and* enabled — a disabled primary action would still "render".
    g.wait_for("Add account", "push button")
    shot("01-welcome")


def test_changelog_screen() -> None:
    """Regression guard for #932: the changelog asset must ship in the bundle."""
    step("changelog screen loads its bundled asset")
    open_drawer()
    g.click("ChangeLog", "push button")

    # The failure mode this pins: the screen renders, but with an error where
    # the history should be. Asserting only that the screen opened would pass.
    g.assert_absent("Error loading changelog")
    g.assert_text("Installed:")
    shot("02-changelog")

    if RELEASE_VERSION:
        step(f"running build identifies itself as release {RELEASE_VERSION}")
        g.assert_text(f"Running release {RELEASE_VERSION}")

    back_to_home()


def test_about_screen() -> None:
    """The packaged build reports a real version and commit.

    The About table's row labels ('App Version', 'Git Commit') are rendered as
    Markdown and never reach the accessibility tree — a screen reader gets the
    values without knowing what they mean. The values themselves are links, so
    that is what is asserted here; the missing labels are an accessibility bug
    to fix in the app, not something to work around by loosening this test.
    """
    step("about screen reports a version and a commit")
    open_drawer()
    g.click("About", "push button")
    g.wait_for("Copy info", "push button")

    links = [(n.name or "").strip() for n, _ in g._walk(g._app_root())
             if n.getRoleName() == "link"]

    # A release build carries the auto-incrementing build number, so the
    # version reads "0.1.1+1790673397". Without --build-number it would be a
    # bare "0.1.1+", which is the regression this pins.
    version = next((l for l in links if re.fullmatch(r"\d+\.\d+\.\d+\+\d+", l)), None)
    if version is None:
        bare = [l for l in links if l.rstrip().endswith("+")]
        raise g.GuiError(
            f"no version link of the form X.Y.Z+<build number>; links were {links}"
            + (f"\n{bare!r} has an empty build number — the build ran without "
               "--build-number" if bare else "")
        )

    commit = next((l for l in links if re.fullmatch(r"[0-9a-f]{7,40}", l)), None)
    if commit is None:
        raise g.GuiError(f"no git commit link on the About screen; links were {links}")

    print(f"    version {version}, commit {commit}")
    shot("03-about")
    back_to_home()


def test_imap_reaches_server() -> None:
    """The packaged binary can open an IMAP connection to a real server.

    Scoped to IMAP on purpose. The app always attempts STARTTLS on SMTP even
    with the SSL switch off, and the dev Stalwart presents a self-signed
    certificate, so completing account creation through the GUI fails on SMTP
    alone. Asserting that the failure is SMTP-only proves IMAP got through.
    """
    step("packaged binary reaches the IMAP server")
    open_drawer()
    g.click("Add account", "push button")
    g.fill("Email address", "alice@example.com")
    g.click("Continue", "push button")
    g.click("IMAP / SMTP", "push button")

    g.fill("Display name", "Alice")
    g.fill("Password", "secret", role="password text")
    g.fill("Host", "localhost", index=0)   # IMAP, forwarded to Stalwart
    g.fill("Port", "1430", index=0)
    g.fill("Host", "localhost", index=1)   # SMTP
    g.fill("Port", "1025", index=1)

    # Plaintext is only permitted for localhost (see isLocalhost in
    # lib/core/utils/host_utils.dart), which is why the forwards exist.
    import pyatspi
    for i in range(len(g.find_all("SSL/TLS"))):
        node = g.find_all("SSL/TLS")[i]
        if node.getState().contains(pyatspi.STATE_CHECKED):
            g.click("SSL/TLS", "toggle button", index=i)
            time.sleep(0.5)

    g.click("Try connection", "push button")
    time.sleep(12)
    shot("04-connection")

    names = [n.name for n, _ in g._walk(g._app_root()) if (n.name or "").strip()]
    errors = [n for n in names if "Exception:" in n or "Connection failed" in n]
    imap_errors = [e for e in errors if "IMAP:" in e]
    if imap_errors:
        raise g.GuiError(
            "IMAP connection failed — the packaged binary could not reach the "
            f"server:\n  {imap_errors[0]}"
        )
    print("    IMAP reached the server (no IMAP error reported)")
    if errors:
        print(f"    SMTP, as expected in this environment: {errors[-1][:90]}…")


def main() -> int:
    tests = [test_welcome_screen, test_changelog_screen, test_about_screen]
    if STALWART_READY:
        tests.append(test_imap_reaches_server)
    else:
        print("(skipping the IMAP test: STALWART_READY is not set)")

    failures = []
    for test in tests:
        try:
            ensure_home()
            test()
        except Exception as exc:
            failures.append((test.__name__, exc))
            print(f"FAIL {test.__name__}: {exc}", flush=True)
            shot(f"FAILED-{test.__name__}")

    print()
    if failures:
        print(f"{len(failures)} of {len(tests)} GUI tests failed:")
        for name, _ in failures:
            print(f"  - {name}")
        return 1
    print(f"All {len(tests)} GUI tests passed against the packaged release.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
