---
title: 'Email Detail'
description: 'A single email: headers, body, attachments and per-message actions.'
---

![Email Detail](/mail-user-agent/screenshots/email-detail.png)

The **Email Detail** shows one message: sender, recipients, subject, body, and
attachments. Opening the screen also marks the message as read.

**Source:** `lib/ui/screens/email_detail_screen.dart` — `EmailDetailScreen`.

## What you can do here

- **Reply / Reply all** — opens [Compose](/mail-user-agent/screens/compose/)
  prefilled from the original.
- **Forward** (overflow menu) — downloads the attachments, then opens
  [Compose](/mail-user-agent/screens/compose/) with the quoted message and the
  attachments already attached. One that cannot be downloaded is left out and
  named in a warning.
- **Star / unstar** — the amber star icon in the AppBar; synced to the server.
- **Move** — opens a folder-picker bottom sheet. IMAP MOVE is queued if the
  device is offline.
- **Snooze** — opens the [Snooze Picker](/mail-user-agent/screens/snooze-picker/);
  see [Snooze](/mail-user-agent/snooze/) for the full mechanics.
- **Delete** — expunges on the server and removes the local row.
- **Add note** — attaches a local note to the message.
- **Raw Email / Mail Structure** — diagnostic views of headers and MIME parts.
- Tap a sender or recipient to open **Address Emails** (all messages to/from
  that address on the current account).

## When the body cannot be loaded

Offline, a message whose body was never downloaded shows "This message could
not be opened" with a Retry button. Actions that need only the message itself
still work and are queued like everywhere else: archive, move, snooze, delete,
star, mark as spam, mark as unread. Reply opens Compose without the quoted
text and says so. Forward, Select text, Mail Headers and Mail Structure need
the body: they show a message saying it is not available instead of doing
nothing.

## Navigation from this screen

- [Compose](/mail-user-agent/screens/compose/) — Reply, Reply all, Forward
- [Snooze Picker](/mail-user-agent/screens/snooze-picker/) →
  [Snooze](/mail-user-agent/snooze/)
- Move-to-folder picker
- [Email List](/mail-user-agent/screens/email-list/) — AppBar back arrow
