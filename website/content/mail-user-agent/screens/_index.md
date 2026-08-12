---
title: 'Screens'
description: 'Every screen in the sharedinbox.de mail client, with its canonical name.'
---

Every screen in the app has one canonical name. Use that name when you file a
bug or ask a coding agent to change something — it maps directly to a source
file under `lib/ui/screens/` and a widget class in that file.

## Mail

| Screen | Source file | Reached from |
| --- | --- | --- |
| [Combined Inbox](/mail-user-agent/screens/combined-inbox/) | `combined_inbox_screen.dart` | Drawer → *Combined Inbox* (start screen) |
| [Email List](/mail-user-agent/screens/email-list/) | `email_list_screen.dart` | [Mailbox List](/mail-user-agent/screens/mailbox-list/) → tap a folder |
| Thread Detail | `thread_detail_screen.dart` | [Email List](/mail-user-agent/screens/email-list/) → tap a thread with more than one message |
| [Email Detail](/mail-user-agent/screens/email-detail/) | `email_detail_screen.dart` | [Email List](/mail-user-agent/screens/email-list/) → tap a single-message thread |
| [Compose](/mail-user-agent/screens/compose/) | `compose_screen.dart` | Floating "edit" button on any inbox / Reply / Reply all |
| Search | `search_screen.dart` | AppBar search icon on [Combined Inbox](/mail-user-agent/screens/combined-inbox/) or an account view |
| Address Emails | `address_emails_screen.dart` | Tap a sender or recipient chip in [Email Detail](/mail-user-agent/screens/email-detail/) |

## Pickers and dialogs

These aren't full screens — they're bottom sheets — but they get their own
name so bug reports can be specific.

| Surface | Source file | Opened from |
| --- | --- | --- |
| [Snooze Picker](/mail-user-agent/screens/snooze-picker/) | `widgets/snooze_picker.dart` | *Snooze* menu in [Email Detail](/mail-user-agent/screens/email-detail/) or selection bottom bar in [Email List](/mail-user-agent/screens/email-list/) |
| Move-to-folder picker | `email_detail_screen.dart` (inline) | *Move* menu in [Email Detail](/mail-user-agent/screens/email-detail/) |

## Accounts and settings

| Screen | Source file | Reached from |
| --- | --- | --- |
| [Account List (Manage accounts)](/mail-user-agent/screens/account-list/) | `account_list_screen.dart` | Drawer → *Manage accounts* |
| Account Home | `account_home_screen.dart` | Drawer → account name |
| Add Account | `add_account_screen.dart` | Drawer → *Add account* |
| Edit Account | `edit_account_screen.dart` | Account Home → *Edit* |
| Receive Accounts | `account_receive_screen.dart` | Drawer → *Receive accounts* |
| Send Accounts | `account_send_screen.dart` | Account Home → *Send accounts* |
| Account Compare | `account_compare_screen.dart` | Account Home → *Compare to …* |
| [Mailbox List (Folders)](/mail-user-agent/screens/mailbox-list/) | `mailbox_list_screen.dart` | Account Home → *Folders* |
| User Preferences | `user_preferences_screen.dart` | Drawer → *Preferences* |
| Push Settings | `push_settings_screen.dart` | Preferences → *UnifiedPush* |
| Trusted Image Senders | `trusted_image_senders_screen.dart` | Preferences → *Trusted image senders* |

## Diagnostics

| Screen | Source file | Reached from |
| --- | --- | --- |
| Sent Queue | `sent_queue_screen.dart` | Drawer → *Sent Queue* |
| Outbox | `outbox_screen.dart` | Account Home → *Outbox* |
| Undo Log | `undo_log_screen.dart` | Drawer → *Undo Log* |
| Undo Log Detail | `undo_log_detail_screen.dart` | Undo Log → tap an entry |
| Application Log | `app_log_screen.dart` | Drawer → *Application Log* |
| Sync Log | `sync_log_screen.dart` | Account Home → *Sync log* |
| Sync State | `sync_state_screen.dart` | Account Home → *Sync state* |
| Message Debug | `message_debug_screen.dart` | *Message debug* action from a message |
| Bug Report | `bug_report_screen.dart` | *Report bug* action |
| Crash | `crash_screen.dart` | Shown after a fatal error |

## Filters (Sieve)

| Screen | Source file | Reached from |
| --- | --- | --- |
| Sieve Scripts | `sieve_scripts_screen.dart` | Account Home → *Remote email filters* / *Local email filters* |
| Sieve Script Edit | `sieve_script_edit_screen.dart` | Sieve Scripts → tap a script or "+" |

## Info

| Screen | Source file | Reached from |
| --- | --- | --- |
| About | `about_screen.dart` | Drawer → *About* |
| ChangeLog | `changelog_screen.dart` | Drawer → *ChangeLog* |
