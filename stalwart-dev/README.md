# stalwart-dev — local Stalwart for probing server behavior

Several sync-engine fixes turned on *how a real JMAP server actually behaves*,
not on what the RFC says — and the cheapest way to settle those questions is to
ask a throwaway Stalwart directly. Examples this answered:

- `Email/changes` honours `maxChanges` / `hasMoreChanges` and does **not**
  degrade to `cannotCalculateChanges` (#968).
- `Email/get` with `ids: []` returns the Email `state`, even on an empty
  mailbox (#973).
- `Email/get` populates `notFound` for ids the server no longer has, including
  alongside the body-fetch options (#980).
- `Email/query` `anchor`/`anchorOffset` resumes correctly where `position`
  skips messages after a deletion; a deleted anchor returns `anchorNotFound`;
  `queryState` changes when the result set shifts (#1020).
- `maxObjectsInGet` is 500, so the 50-id `Email/get` batch is safely under it.

## 1. Start a throwaway Stalwart

`config.toml` here defines test accounts `alice@example.com` / `bob@example.com`,
both with password `secret`.

On a **codeN seat**, docker is root-only, so start it on `tc` as root and map a
local port (nothing else needs the container — delete it when done):

Double quotes so `$HOME` expands **locally** to your seat's home (the repo
lives at `$HOME/sharedinbox` on tc); everything else is literal:

```
ssh root@tc "docker run -d --name sbprobe --entrypoint stalwart \
  -p 127.0.0.1:18080:8080 \
  -v $HOME/sharedinbox/stalwart-dev/config.toml:/etc/stalwart/config.toml:ro \
  -v /tmp/sbprobe:/tmp/stalwart:rw \
  docker.io/stalwartlabs/stalwart:v0.14.1 --config /etc/stalwart/config.toml"
# … probe (below) …
ssh root@tc "docker rm -f sbprobe; rm -rf /tmp/sbprobe"
```

(Using single quotes here would expand `$HOME` on the *remote* side as root —
`/home/root/sharedinbox` — and the mount would fail.)

Inside `nix develop` (with a container runtime and Flutter SDK), the existing
`./start` script does the same with random ports — see its header.

## 2. Probe it

`jmap_probe.py` is dependency-free (stdlib only). With no `--call` it prints a
session summary (apiUrl, accountId, `maxObjectsInGet`) and runs a read-only
demo:

```
python3 stalwart-dev/jmap_probe.py http://127.0.0.1:18080 alice@example.com secret
```

Pass `--call METHOD ARGS_JSON` (repeatable) to ask a specific question;
`accountId` is injected for you:

```
python3 stalwart-dev/jmap_probe.py http://127.0.0.1:18080 alice@example.com secret \
  --call Email/changes '{"sinceState":"s0","maxChanges":2}' \
  --call Email/get '{"ids":[],"fetchTextBodyValues":true}'
```

To reproduce the examples at the top, create a few messages first (an
`Email/set` `--call` with a `create` object) and then query/change against them.

Two limitations, fine for a dev probe: the `using` set is core+mail, so a
`--call` to a submission/sieve/vacation method is rejected; and an `apiUrl` the
server reports on a *different host* is followed only by path (re-joined to the
base URL you passed).

## 3. Drive the Android app against it

For end-to-end / exploratory testing, point the installed app
(`de.sharedinbox.mua`) on a USB-connected device — `adb devices` to confirm one
is attached — at the throwaway Stalwart and click through it from the shell. No
Flutter SDK needed; this drives the already-installed app.

**Publish every protocol port, not just JMAP** — the device needs IMAP and SMTP
too (ManageSieve only if you test filters):

```
ssh root@tc "docker run -d --name sbdevice --entrypoint stalwart \
  -p 127.0.0.1:8080:8080 -p 127.0.0.1:1430:1430 \
  -p 127.0.0.1:1025:1025 -p 127.0.0.1:4190:4190 \
  -v $HOME/sharedinbox/stalwart-dev/config.toml:/etc/stalwart/config.toml:ro \
  -v /tmp/sbdevice:/tmp/stalwart:rw \
  docker.io/stalwartlabs/stalwart:v0.14.1 --config /etc/stalwart/config.toml"
```

**Bridge the ports onto the device** with `adb reverse`, so the app reaches the
server at `localhost` *on the device* (adb forwards each back to tc):

```
for p in 1430 1025 4190 8080; do adb reverse "tcp:$p" "tcp:$p"; done
```

**Seed some mail** from the seat — the host can reach the published port on
`127.0.0.1` directly (plaintext submission; `config.toml` allows it):

```
python3 - <<'PY'
import smtplib
from email.message import EmailMessage
m = EmailMessage()
m["From"], m["To"], m["Subject"] = "bob@example.com", "alice@example.com", "hello"
m.set_content("body")
s = smtplib.SMTP("127.0.0.1", 1025)
s.login("bob@example.com", "secret")
s.send_message(m)
s.quit()
PY
```

**Add the account in the app.** The simplest reliable path is **JMAP**:
*+ → type `alice@example.com` → Continue → Use JMAP instead*, with API URL
`http://localhost:8080/.well-known/jmap`, username blank, password `secret`.

IMAP/SMTP uses the same screen under *IMAP / SMTP*: a *Display name* (required),
host `localhost`, IMAP port `1430`, SMTP port `1025`, and **turn SSL/TLS off on
both** — the defaults are 993/465 with SSL on (implicit TLS), which this
plaintext dev server does not speak. Heads-up: against this server the SMTP leg
of *Try connection* currently fails with a *TLS certificate error on
`localhost:1025`* (the port advertises STARTTLS with a self-signed cert). IMAP
connects fine, so if you hit that, use JMAP — it has no such step.

**Click through it from the shell.** The Flutter app exposes its full semantics
tree, so `uiautomator` gives real tap targets — no pixel-hunting. Dump the tree
and print each tappable widget as `x,y<TAB>label` (screen-centre coordinates):

```
adb shell uiautomator dump /sdcard/ui.xml >/dev/null
adb pull /sdcard/ui.xml /tmp/ui.xml >/dev/null
python3 - <<'PY'
import html, re
for n in re.findall(r'<node[^>]*>', open('/tmp/ui.xml').read()):
    t = re.search(r'text="([^"]*)"', n)
    c = re.search(r'content-desc="([^"]*)"', n)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    label = html.unescape((t.group(1) if t else "") or (c.group(1) if c else ""))
    if b and (label or 'clickable="true"' in n):
        x1, y1, x2, y2 = map(int, b.groups())
        print(f"{(x1 + x2) // 2},{(y1 + y2) // 2}\t{label[:60]}")
PY
adb shell input tap <x> <y>           # tap a widget by those coordinates
adb shell input text 'hello'          # type into the focused field (ASCII only)
adb exec-out screencap -p > shot.png  # screenshot the current screen
```

Gotchas worth knowing up front:

- `adb shell input text` cannot type non-ASCII (e.g. `é`) and splits on spaces —
  escape spaces as `%s` (`input text 'a%sb'`). Clear a field by focusing it,
  `input keyevent 123` (move-to-end), then repeated `input keyevent 67` (delete).
- Re-dump after anything that opens the keyboard: it shifts the layout, so cached
  coordinates go stale.
- The app logs to `logcat` under the `flutter` tag with a `[SharedInbox]`
  prefix — follow sync/connection state with `adb logcat -s flutter:I` (or
  `adb logcat | grep SharedInbox`). The in-app *Application log* shows the same.
  (The add-account *Try connection* path is the exception — it reports only in
  the UI, so read its result from a `uiautomator` dump or screenshot.)

**Clean up** when done:

```
ssh root@tc "docker rm -f sbdevice; rm -rf /tmp/sbdevice"
adb reverse --remove-all
```
