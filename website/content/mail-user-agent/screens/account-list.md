---
title: 'Account List'
description: 'Every configured IMAP/JMAP account. Titled "sharedinbox.de" in the AppBar.'
---

![Account List](/mail-user-agent/screenshots/account-list.png)

The **Account List** — reached via the drawer as *Manage accounts* — shows
every configured email account with its display name, address, and protocol
(IMAP or JMAP). This is where you add a new account or open one to edit or
remove it.

**Source:** `lib/ui/screens/account_list_screen.dart` — `AccountListScreen`.

## What you can do here

- Tap **+** to add a new account (opens Add Account).
- Tap an account row to open its Account Home.
- Long-press an account for the per-account action menu (Edit, Sync log,
  Delete, …).

## Navigation from this screen

- Add Account — floating action button
- Account Home — tap an account
- [Combined Inbox](/mail-user-agent/screens/combined-inbox/) — drawer
