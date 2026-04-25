# Later

Are errors written to syncLog ?

---

Taskfile: Debug logs with start+end timestamp for debugging. Each stdout/stderr in one file. How to
get this?

---

ChangeLog with undo.

Every action should be easily undoable.

Example: I delete an email. An undo should be doable. There are three scenearios: Sync from DB to
Server is currently in action (then wait), Sync from DB to server was not done yet, Sync from DB to
server was done.

---

Goal: When an unhandled exception occurs on a real device, show the user
the full error text so they can copy and send it.

Plan:

1. Wrap main() in runZonedGuarded — catches async exceptions that escape
   Flutter's framework (e.g. in isolates, timers, stream callbacks).

2. Install FlutterError.onError — catches widget build errors, assertion
   failures, and other framework errors.

3. Show a full-screen error dialog — when an exception is caught, call a
   global function that uses a NavigatorKey to push an error screen on top
   of whatever is showing. The screen shows:
   - The exception message
   - The stack trace (scrollable)
   - A "Copy to clipboard" button (Clipboard.setData)
   - A "Dismiss" button

4. Keep it always-on since you want manual reporting from real users.

Key files to change:
- lib/main.dart — add runZonedGuarded, FlutterError.onError, navigatorKey
- lib/ui/widgets/crash_screen.dart — new error display widget

---

Implement thread-view.

First create a plan.

For JMAP this is easy.

But for IMAP?

Threads should be synced to the DB, too. Use JMAP as an example. Then think about getting this data
structure from imap.


---


docs

---

Thread view (group by `References` / `In-Reply-To`)

---

mail-loop.com (anstatt shared inbox).

---

---

full-sync: Imaging the sync got out-of-sync somehow. Provide a way via UI to force a sync. First
create a plan. Avoid downloading big bodies/attachments again.

---

mailcoach.de

---

Try Qwen, vscode plugin

---

After Try Connection, show some matching icon next to the text.

---

---

Test with a Fastmail account

---

scripts/check_coverage.dart
reduce files in _excluded.

---

Renovate: Is there a way to run it outside Github Actions? On cli?

---

Write test which fails, when _excluded contains unknown files.

---

Thread view (group by References / In-Reply-To)

Search (IMAP SEARCH command)

---

List-Unsubscribe email header --> show button.

---
