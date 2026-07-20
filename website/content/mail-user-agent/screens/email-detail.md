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

## Navigation from this screen

- [Compose](/mail-user-agent/screens/compose/) — Reply, Reply all, Forward
- [Snooze Picker](/mail-user-agent/screens/snooze-picker/) →
  [Snooze](/mail-user-agent/snooze/)
- Move-to-folder picker
- [Email List](/mail-user-agent/screens/email-list/) — AppBar back arrow
