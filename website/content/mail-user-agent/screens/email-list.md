---
title: 'Email List'
description: 'Threads in a single mailbox on a single account.'
---

![Email List](/mail-user-agent/screenshots/email-list.png)

The **Email List** shows every thread inside a single mailbox on a single
account. Reached by tapping a folder in the
[Mailbox List](/mail-user-agent/screens/mailbox-list/), or via the folder tree
in the drawer.

**Source:** `lib/ui/screens/email_list_screen.dart` — `EmailListScreen`.

## What you can do here

- Tap a thread to open [Email Detail](/mail-user-agent/screens/email-detail/)
  (or the Thread Detail for multi-message threads).
- Pull-to-refresh triggers a manual sync of this mailbox.
- Long-press a thread to enter selection mode, then use the bottom bar to
  star, move, snooze (via the [Snooze Picker](/mail-user-agent/screens/snooze-picker/)),
  or delete every selected thread.
- The floating **edit** button opens [Compose](/mail-user-agent/screens/compose/)
  prefilled with the current account.

## Navigation from this screen

- [Email Detail](/mail-user-agent/screens/email-detail/)
- [Compose](/mail-user-agent/screens/compose/)
- [Snooze Picker](/mail-user-agent/screens/snooze-picker/)
- [Mailbox List](/mail-user-agent/screens/mailbox-list/) — AppBar back arrow
