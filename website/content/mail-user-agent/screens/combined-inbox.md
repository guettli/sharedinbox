---
title: 'Combined Inbox'
description: 'One list of the newest unread mail across every configured account.'
---

![Combined Inbox](/mail-user-agent/screenshots/combined-inbox.png)

The **Combined Inbox** is the app's start screen. It merges the newest emails
from every configured account into a single thread list, sorted by date. When
more than one account is configured, each row shows a small chip with the
account name so senders from different mailboxes are easy to tell apart.

**Source:** `lib/ui/screens/combined_inbox_screen.dart` — `CombinedInboxScreen`.

## What you can do here

- Tap a thread to open it — one-message threads open the
  [Email Detail](/mail-user-agent/screens/email-detail/), multi-message threads
  open the Thread Detail.
- Tap the floating **edit** button to open [Compose](/mail-user-agent/screens/compose/).
- Tap the AppBar search icon to open Search.
- Long-press a thread to enter selection mode; the selection bottom bar lets
  you star, move, snooze (via the [Snooze Picker](/mail-user-agent/screens/snooze-picker/))
  or delete every selected thread at once.

## Navigation from this screen

- [Email Detail](/mail-user-agent/screens/email-detail/) — single-message threads
- [Compose](/mail-user-agent/screens/compose/) — floating action button
- [Snooze Picker](/mail-user-agent/screens/snooze-picker/) — selection bottom
  bar → Snooze
- [Account List](/mail-user-agent/screens/account-list/) — drawer → *Manage
  accounts*
