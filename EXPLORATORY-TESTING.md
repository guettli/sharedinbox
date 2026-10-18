# Exploratory testing (agent-driven)

Exploratory testing means using the app the way a user would, without a script.
You decide what to try next from what you just saw. Regression tests check
behaviour someone already thought of. Exploratory testing finds the behaviour
nobody thought of. Each bug it finds should end up as a regression test, so the
two work together.

This page explains how an agent without a Flutter SDK, display or phone can
explore the app on a seat or worker:

- run a **debug Linux build** on a virtual desktop next to a throwaway
  **Stalwart** mail server,
- drive it through an **HTTP API** that reads and operates the app's
  accessibility tree.

Both run in one Dagger service, so nothing has to be installed on the host.

## Why Linux, and why the accessibility tree

Most bugs are not platform-specific: sync, the database, protocol handling and
widget logic run the same on every platform. The Linux build is fast to
rebuild, needs no reinstall (on Android every Dagger debug APK has a fresh
signing key) and runs headless. Use a real device only for Android-specific
behaviour such as the IME, background sync, notifications, permissions or share
intents. That setup is in `stalwart-dev/README.md`, section 3.

Flutter draws every pixel itself, so to X11 the app is one opaque window.
Clicking coordinates with `xdotool` and reading screenshots is brittle. The
service drives the app through AT-SPI instead, using the same driver as the
release GUI test (`scripts/gui_driver.py`). It finds widgets by their
accessible name and role, reads their state (checked, focused, disabled) and
activates them through their own actions. As a side effect, a control the API
cannot find because it has no label is an accessibility bug in its own right.

## Start it

On a `tc` seat, with the Dagger engine reachable as described in `AGENTS.md`,
start the service in the background. It keeps running until you stop it.

```bash
task explore-linux
# = dagger call -m ci --source=. explore-linux up \
#     --ports 8765:8765 --ports 21430:1430 --ports 21025:1025 --ports 28080:8080
```

The first run compiles the debug build, which takes a few minutes. After that
the build is cached until `lib/`, `linux/`, `assets/` or `pubspec.*` change.
Wait until the API answers:

```bash
until curl -sf localhost:8765/health; do sleep 3; done
```

| Host port | What |
|---|---|
| 8765 | Driving API (`scripts/explore_server.py`) |
| 21430 | Stalwart IMAP |
| 21025 | Stalwart SMTP |
| 28080 | Stalwart JMAP |

The host ports are offset so they do not collide with `task stalwart` or a
probe container. `dagger up` binds them on **all interfaces**, and the API has
no authentication. Use only the test accounts below, never real credentials.

To test a code change, stop the `dagger call … up` process and start it again.
Only the changed layers rebuild. The app's data does not survive a restart of
the service.

## The API

All parameters can go in the query string or a form body, with GET or POST. For
the full list, see the docstring of `scripts/explore_server.py` (or `GET /` on
any unknown path).

```bash
A=localhost:8765; c(){ curl -s "$A/$1" "${@:2}"; }

c texts                                   # what is on screen, one node per line
c tree                                    # the same, with hierarchy
c shot -o /tmp/screen.png                 # screenshot (then view the PNG)
c log -d lines=50                         # app stdout/stderr: assertions, exceptions
c click -d name='Add account'             # exact accessible name
c click -d name=SSL/TLS -d contains=1 -d index=1   # substring, 2nd match
c fill --data-urlencode name='Email address' -d text=bob@example.com
c fill -d name=Password -d text=secret --data-urlencode role='password text'
c key -d key=Escape                       # xdotool key names: Return, ctrl+a, …
c restart -d wipe=1                       # fresh install: no accounts, no data
```

How to read the output:

- `texts` prints `role [states]: name`. States are `checked`, `focused`,
  `selected`, `expanded` and `disabled`. A list tile's name merges all of its
  texts (sender, subject, preview, date, separated by newlines), so match it
  with `contains=1`.
- Repeated labels, such as the two `Host` fields (IMAP and SMTP), are told
  apart with `index`, in tree order, which matches visual order.
- A failed lookup returns HTTP 409 with the whole tree attached.
- `click-unnamed` presses a button that has no label. Every time you need it,
  you have found a missing semantic label.
- Text goes in through synthetic key events (`xdotool`) into the focused field,
  because Flutter text fields do not implement the AT-SPI text-editing
  interface.

## Recipes

**Add the test account.** The Stalwart in the service has `alice@example.com`
and `bob@example.com`, both with password `secret`. The app allows plaintext
IMAP and SMTP only to `localhost`, so the service forwards localhost:1430 and
localhost:1025 to Stalwart. Inside the app, use those ports, not the offset
host ports.

```bash
c click -d name='Add account'
c fill --data-urlencode name='Email address' -d text=bob@example.com
c click -d name=Continue                        # auto-detect fails, as expected
c click --data-urlencode name='IMAP / SMTP'
c fill --data-urlencode name='Display name' -d text=Bob
c fill -d name=Password -d text=secret --data-urlencode role='password text'
c fill -d name=Host -d text=localhost -d index=0; c fill -d name=Port -d text=1430 -d index=0
c fill -d name=Host -d text=localhost -d index=1; c fill -d name=Port -d text=1025 -d index=1
c click -d name=SSL/TLS -d contains=1 -d index=0
c click -d name=SSL/TLS -d contains=1 -d index=1
c click -d name=Save
```

**Seed mail** from the host through the SMTP forward, as Alice:

```python
import smtplib
from email.message import EmailMessage

m = EmailMessage()
m["From"], m["To"], m["Subject"] = "alice@example.com", "bob@example.com", "Hello"
m.set_content("Body")
with smtplib.SMTP("localhost", 21025) as s:
    s.login("alice@example.com", "secret")
    s.send_message(m)
```

**Check what the server really has.** When the app shows something surprising,
compare it with the server before you blame the UI:

```bash
python3 stalwart-dev/jmap_probe.py http://127.0.0.1:28080 bob@example.com secret \
  --call Email/query '{"sort":[{"property":"receivedAt","isAscending":false}]}'
```

IMAP is available too, at `localhost:21430` (plaintext).

## A session

1. **Pick a charter**, one sentence on what to explore: "replying with
   attachments", "what happens offline", "a long thread". A charter keeps the
   session from turning into a random walk.
2. **Use the app.** After each step, read `texts` and look at a screenshot when
   layout matters. Keep an eye on `log`: a debug build reports framework
   assertions and uncaught exceptions there, even when the screen looks fine.
3. **Question everything you see.** Does the label match the state? Is the date
   right? Does the server agree? Is a button offered that does nothing here?
4. **For each finding:** reproduce it, confirm it against the server, and
   search the open issues for duplicates. Then write a failing unit or widget
   test, fix the bug, and open one PR per finding.
5. **Report what you left alone**, such as minor issues and environment quirks,
   so the next session does not rediscover them.

## Gotchas

- **Killing the service:** `pkill -f "explore-linux up"` also matches the shell
  running the `pkill`. Use `pgrep -f "[e]xplore-linux up" | xargs -r kill`.
- **Software rendering:** the debug build under Xvfb is noticeably slower than a
  release build. Give a screen a second or two after a click before you read
  it.
- **Window size:** the window is 1280×800 on a 1280×900 screen. The black strip
  at the bottom of screenshots is the empty part of the screen, not a bug.
- **ManageSieve:** the log reports a failed ManageSieve probe on port 4190. The
  dev Stalwart offers STARTTLS there without a usable certificate. This is
  expected and does not stop mail from working.
