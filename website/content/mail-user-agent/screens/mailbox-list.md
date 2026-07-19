---
title: 'Mailbox List'
description: 'Every folder on a single account, with unread and total counts.'
---

![Mailbox List](/mail-user-agent/screenshots/mailbox-list.png)

The **Mailbox List** — labelled *Folders* in the AppBar — shows every mailbox
on a single account, with the unread and total message count next to each
folder name. Special roles (Inbox, Sent, Drafts, Trash, Snoozed) are marked so
they're easy to find.

**Source:** `lib/ui/screens/mailbox_list_screen.dart` — `MailboxListScreen`.

## What you can do here

- Tap a folder to open its [Email List](/mail-user-agent/screens/email-list/).
- Long-press a folder for *Rename*, *Move*, or *Delete*.
- Create a new folder via the AppBar action.

## Navigation from this screen

- [Email List](/mail-user-agent/screens/email-list/) — tap a folder
- Account Home — AppBar back arrow
