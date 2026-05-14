# Email Sync Architecture

This document describes the full lifecycle of an email action — from the moment the user taps
a button to server confirmation — covering the IMAP IDLE loop, JMAP push/poll, the pending-change
queue, exponential backoff, and the undo/cancel mechanism.

For the database schema and protocol-level implementation details see [DB-SYNC.md](DB-SYNC.md).

---

## 1. Components

| Component | File | Role |
|-----------|------|------|
| `AccountSyncManager` | `lib/core/sync/account_sync_manager.dart` | Owns one `_SyncLoop` per account; starts, stops, and wakes sync loops |
| `_AccountSync` | same file | IMAP sync loop (IDLE + incremental fetch) |
| `_JmapAccountSync` | same file | JMAP sync loop (SSE push + poll fallback) |
| `EmailRepositoryImpl` | `lib/data/repositories/email_repository_impl.dart` | All DB reads/writes and network calls |
| `pending_changes` table | `lib/data/db/database.dart` | Protocol-agnostic outbound mutation queue |
| `UndoService` | `lib/core/services/undo_service.dart` | Persisted undo history; cancel-or-reverse logic |

---

## 2. Lifecycle of an email mutation (e.g. "Mark as read")

```
User taps "Mark as read"
        │
        ▼
EmailRepository.setFlag(id, seen: true)
        │
        ├─ 1. Write optimistic update to local DB
        │      emails.is_seen = true
        │
        └─ 2. Insert row into pending_changes
               { type: 'flag_seen', email_id: id, payload: {seen: true} }
               (IMAP: includes uid + mailboxPath for the STORE command)
               (JMAP: includes just the flag map for Email/set)

[UI immediately reflects the change via Drift's reactive streams]

        │
        ▼ (next sync cycle, triggered by IMAP IDLE / JMAP push / wakeUp)
_SyncLoop._flush() / flushPendingChanges()
        │
        ├─ IMAP: open connection → STORE uid +FLAGS (\Seen) → close
        │
        └─ JMAP: Email/set { update: { id: { keywords: { "$seen": true } } } }
               If stateMismatch → clear checkpoint → full re-sync

        │
        ▼
pending_changes row deleted on success
(on permanent error: retry count incremented; evicted after 5 failures)
```

---

## 3. IMAP sync loop

The IMAP loop runs one coroutine per account (`_AccountSync`):

```
start()
  │
  ▼
[forever loop]
  ├─ flushPendingChanges()   ← drain outbound queue first
  ├─ syncMailboxes()         ← detect new/removed mailboxes
  ├─ for each mailbox:
  │    syncEmails()          ← incremental: fetch only UIDs > lastUid
  │                             deletion reconciliation: remove rows
  │                             whose UID is absent from the server
  └─ _idle()                 ← IMAP IDLE for up to 25 min (RFC 2177)
       │                        Wakes on: server EXISTS/EXPUNGE/FLAGS
       │                        or syncNow() signal from UI
       └─ repeat
```

**Incremental sync checkpoint** — `sync_state` table stores `(accountId, mailbox, lastUid, uidValidity)`.
On each run, only UIDs greater than `lastUid` are fetched. If `uidValidity` changes the full
folder is re-scanned and the checkpoint is reset.

**IDLE cap** — IDLE sessions are limited to 25 minutes per the RFC. The loop also wakes
immediately if `syncNow()` is called (e.g. user pulls-to-refresh).

---

## 4. JMAP sync loop

The JMAP loop (`_JmapAccountSync`) follows a similar structure but uses HTTP:

```
start()
  │
  ▼
[forever loop]
  ├─ flushPendingChanges()   ← Email/set for queued mutations
  ├─ syncMailboxes()         ← Mailbox/get or Mailbox/changes
  ├─ for each mailbox:
  │    syncEmails()          ← Email/query + Email/get (first run)
  │                             Email/changes (subsequent runs, state token)
  └─ _wait()
       ├─ If server advertises eventSourceUrl: subscribe to SSE push
       │    wake on "Email" change event
       └─ Otherwise: sleep 30 s (poll fallback)
```

**State tokens** — each `Mailbox/changes` / `Email/changes` call uses the server-provided
`state` token stored in `sync_state`. A `stateMismatch` error clears the token and triggers
a full re-fetch.

**JMAP send** — outgoing mail uses `EmailSubmission/set` when the server advertises the
`urn:ietf:params:jmap:submission` capability; falls back to SMTP otherwise.

---

## 5. Exponential backoff

Both loops share the same backoff policy:

| Outcome | Backoff |
|---------|---------|
| Sync succeeded | Reset to 5 s |
| Network / server error | Double previous backoff, capped at 900 s (15 min) |

The backoff counter (`_backoffSeconds`) is per-account and per-process; it resets to 5 s
on the next successful cycle.

The last error message is written to `sync_log` and surfaced in the UI via
`syncLastErrorProvider` (the red `MaterialBanner` in the email list).

---

## 6. Pending-change queue

`pending_changes` is a protocol-agnostic table that stores every outbound mutation before it
reaches the server:

| Column | Description |
|--------|-------------|
| `id` | Auto-increment primary key |
| `email_id` | The email being mutated |
| `type` | `flag_seen`, `flag_flagged`, `move`, `delete`, `snooze` |
| `payload` | JSON-encoded protocol-specific arguments |
| `retry_count` | Incremented on each failed flush attempt |
| `created_at` | For ordering and debug |

**Optimistic UI** — every mutation writes the local change first, then inserts into
`pending_changes`. The Drift reactive stream delivers the update to the UI before
the network round-trip completes.

**Conflict resolution** — the server always wins. On the next sync cycle the server's
state overwrites local rows. Outbound mutations are retried up to 5 times; after that
they are evicted and a `FailedMutation` record is created. Permanent per-item JMAP
errors (`notFound`, `forbidden`) skip the retry counter and evict immediately.

---

## 7. Undo and cancel

When the user triggers an undoable action the UI calls:
```
ref.read(undoServiceProvider.notifier).pushAction(UndoAction(...))
```

`UndoService` persists the action to the `undo_actions` table (max 10 entries, FIFO).
A `SnackBar` with an **Undo** button appears for a few seconds.

When the user taps Undo, `UndoService.undo()` executes this sequence for each affected email:

```
1. cancelPendingChange(id, originalType)
      └─ Deletes the pending_changes row if it has not been flushed yet.
         Returns true if cancelled, false if the server already processed it.

2. If the email row was hard-deleted (DELETE action):
      restoreEmails([original])
         └─ Re-inserts the row with its pre-deletion state,
            placed in the correct mailbox (source if cancelled, dest otherwise).

3. moveEmail(id, sourceMailboxPath)
      └─ Optimistic local move back to the original folder.
         If step 1 returned false (already sent to server), this enqueues
         a reverse-move in pending_changes so the server move is undone too.

4. If step 1 returned true (cancelled before flush):
      cancelPendingChange(id, 'move')
         └─ The reverse-move from step 3 is redundant; remove it.
```

The net result is: if the mutation was still in the queue it is silently cancelled with no
server round-trip; if it had already been flushed, a compensating move is queued.

---

## 8. Key invariants

- **Order**: pending changes are flushed before syncing. This prevents the server from
  overwriting an optimistic local state that the server hasn't seen yet.
- **Idempotency**: `flushPendingChanges` is safe to call multiple times. Each row is
  deleted only after the server acknowledges the change.
- **No silent data loss**: permanent server errors surface as `FailedMutation` records
  visible in the UI (Settings → Failed mutations).
- **UI layer isolation**: `lib/ui/` never imports `lib/data/`; all interaction goes
  through `core/` interfaces. The `check-layers` Taskfile task enforces this.
