---
title: 'Compose'
description: 'Write a new email, reply, or forward.'
---

![Compose](/mail-user-agent/screenshots/compose.png)

The **Compose** screen writes a new email — from scratch, as a reply, or as a
forward. Reply / Reply all pre-fills *To*, *Cc*, and *Subject* (`Re:`) from the
original.

**Source:** `lib/ui/screens/compose_screen.dart` — `ComposeScreen`.

## What you can do here

- Pick which account to send from (when more than one is configured).
- Fill in *To*, *Cc*, *Subject* and body.
- Attach files.
- Tap **Send** — the message is handed to the send queue and delivered as soon
  as the network allows. Failures are surfaced in the Sent Queue.

## Navigation from this screen

- Sent Queue — after Send, if there is a failure to inspect
- [Email Detail](/mail-user-agent/screens/email-detail/) or
  [Email List](/mail-user-agent/screens/email-list/) — AppBar back arrow
