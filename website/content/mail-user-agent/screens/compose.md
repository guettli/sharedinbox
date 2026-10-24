---
title: 'Compose'
description: 'Write a new email, reply, or forward.'
---

![Compose](/mail-user-agent/screenshots/compose.png)

The **Compose** screen writes a new email — from scratch, as a reply, or as a
forward. Reply / Reply all pre-fills *To*, *Cc*, and *Subject* (`Re:`) from the
original. Forward pre-fills *Subject* (`Fwd:`) and the quoted text, and
attaches the original's attachments (embedded inline images are not carried
over); remove any you do not want to pass on. A file shared to SharedInbox
from another app arrives attached the same way.

**Source:** `lib/ui/screens/compose_screen.dart` — `ComposeScreen`.

## What you can do here

- Pick which account to send from (when more than one is configured).
- Fill in *To*, *Cc*, *Subject* and body.
- Attach files. They are kept with the auto-saved draft (the app keeps its
  own copy), so leaving Compose and reopening the draft brings them back.
  The draft's copy in the server's *Drafts* folder carries them too, and a
  draft started in another mail client comes back with its attachments.
- Tap **Send** — the message is handed to the send queue and delivered as soon
  as the network allows. Failures are surfaced in the Sent Queue.

## Navigation from this screen

- Sent Queue — after Send, if there is a failure to inspect
- [Email Detail](/mail-user-agent/screens/email-detail/) or
  [Email List](/mail-user-agent/screens/email-list/) — AppBar back arrow
