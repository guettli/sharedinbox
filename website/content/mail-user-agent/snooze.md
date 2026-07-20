---
title: 'Snooze'
description: 'How the Snooze feature works and where the data is stored.'
---

Snoozing hides a thread from your inbox until a chosen time, then puts it back.
It works offline-first: the local state changes immediately, and the server is
updated on the next sync.

## User flow

1. Open [Email Detail](/mail-user-agent/screens/email-detail/) — or long-press
   threads in [Combined Inbox](/mail-user-agent/screens/combined-inbox/) or
   [Email List](/mail-user-agent/screens/email-list/) to enter selection mode.
2. Choose **Snooze**. The
   [Snooze Picker](/mail-user-agent/screens/snooze-picker/) opens with quick
   options (*This evening*, *Tomorrow morning*, *Next week*) and a
   *Pick date & time…* fallback.
3. The email is moved to the **Snoozed** folder immediately, and a snackbar
   shows *"Snoozed until …"* with an **Undo** action.
4. When the chosen time passes, the next sync cycle moves the email back to
   the INBOX of the same account.

The whole flow is offline-safe: if the device is disconnected when you snooze,
the local move happens instantly and the server update is queued. Waking up
also happens locally — the sync engine simply flushes the queued *unsnooze*
whenever it reconnects.

## Where the data lives

Snooze state is stored in three places.

### 1. Local database (Drift / SQLite)

The `emails` table gains two extra columns per row when a message is snoozed
(see `lib/data/db/database.dart`):

| Column | Meaning |
| --- | --- |
| `snoozed_until` | UTC timestamp when the message should reappear. `NULL` for un-snoozed rows. |
| `snoozed_from_mailbox_path` | Mailbox the message was in before it was moved to Snoozed. Kept for the Undo Log, so a wake-up entry can show where the message came from. |

A partial index (`emails_snoozed_until`) makes the wake-up query cheap:

```sql
CREATE INDEX emails_snoozed_until
  ON emails (account_id, snoozed_until)
  WHERE snoozed_until IS NOT NULL;
```

At the same time, the row's `mailbox_path` is set to the account's **Snoozed**
mailbox so the thread disappears from every other folder view.

### 2. Local pending-change queue

Every snooze also enqueues a row in the `pending_changes` table with
`change_type = 'snooze'` and a JSON payload:

```json
{
  "uid": 1234,
  "src": "INBOX",
  "dest": "Snoozed",
  "until": "2026-07-20T08:00:00.000Z"
}
```

Wake-ups enqueue an equivalent `unsnooze` change with `dest = "INBOX"`. The
sync engine flushes these on the next connection.

### 3. Server

The server side is protocol-specific:

**IMAP.** The mail is IMAP-MOVEd into a mailbox named `Snoozed` (auto-created
if missing) and tagged with a keyword flag of the form `snz:<timestamp>` so
the wake time survives a fresh install and a full re-sync. Unsnooze removes
every `snz:*` keyword and IMAP-MOVEs the message back to INBOX.

**JMAP.** The mail is moved via `Email/set` between mailbox IDs — into a
mailbox with role `snoozed` (created on demand with `Mailbox/set`), and back
to the account's inbox on unsnooze. The `snz:<timestamp>` keyword is added
and removed alongside the move.

## Waking up

The wake-up runs at the start of every sync cycle
(`AccountSyncManager._sync` → `EmailRepository.wakeUpEmails`):

1. Select every email in the account whose `snoozed_until <= now`.
2. For each match, enqueue an `unsnooze` pending change with the account's
   INBOX as the destination and optimistically move the local row into INBOX,
   clearing `snoozed_until` and `snoozed_from_mailbox_path`.
3. The pending-change flush that runs right after `wakeUpEmails` pushes the
   move to the server.

Emails always wake up into the current INBOX, regardless of which folder they
were snoozed from — this matches the "get back to inbox, moved by app"
behaviour agreed for the feature.

## Where to look in the code

| Concern | File |
| --- | --- |
| Schema (`snoozed_until`, `snoozed_from_mailbox_path`) | `lib/data/db/database.dart` |
| Snooze / unsnooze / wake-up logic | `lib/data/repositories/email_repository_impl.dart` — `snoozeEmail`, `wakeUpEmails`, `_applyPendingChangeImap`, JMAP branch under `case 'snooze'` |
| Repository interface | `lib/core/repositories/email_repository.dart` — `snoozeEmail`, `wakeUpEmails` |
| UI trigger from a single message | `lib/ui/screens/email_detail_screen.dart` — `_snooze` |
| UI trigger from a selection | `lib/ui/screens/email_action_helpers.dart` — `batchSnooze` |
| Bottom sheet | `lib/ui/widgets/snooze_picker.dart` — `SnoozePicker` |
| Sync-cycle wake-up call | `lib/core/sync/account_sync_manager.dart` — `_sync` |
