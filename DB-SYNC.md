# DB Sync Status

This document covers the mail-to-database sync layer only, not the UI.

## Implemented features

### JMAP

- JMAP accounts can be stored in the database.
- JMAP endpoint discovery is implemented.
- JMAP connection testing is implemented.
- `sync_state` table stores server-side state tokens per (account, resource type).
- `pending_changes` table provides a protocol-agnostic outbound mutation queue.
- `JmapClient` fetches the JMAP Session object, extracts `apiUrl` and `accountId`,
  and provides a `call()` helper for API requests.
- `syncMailboxes` for JMAP: first run uses `Mailbox/get`; subsequent runs use
  `Mailbox/changes` with the stored state token.
- `syncEmails` for JMAP: first run uses `Email/query` + `Email/get`; subsequent runs
  use `Email/changes`. Chains both calls in a single API request via `#ids` back-reference.
- `Email/query` pagination: cursor-based loop with `position` offset and `calculateTotal`
  handles mailboxes larger than 500 emails.
- JMAP background sync worker (`_JmapAccountSync`): session → flush outbound queue →
  syncMailboxes → syncEmails per mailbox → 30 s poll → repeat. Exponential backoff
  5–300 s on failure.
- Local mutations (flag, move, delete) on JMAP accounts are written to `pending_changes`
  with an optimistic local update. `flushPendingChanges` drains the queue via `Email/set`
  at the start of each sync cycle.
- Email bodies are fetched on demand via `Email/get` with `bodyValues` and cached in
  `email_bodies` so subsequent opens are instant.
- `syncEmails` fetches `bodyValues` during the sync pass so bodies are cached without
  a separate on-demand fetch.
- `flushPendingChanges` passes `ifInState` to every `Email/set`; a `stateMismatch`
  response clears the local checkpoint and triggers a full re-sync before retrying.
- **JMAP send**: outgoing mail uses `EmailSubmission/set` when the server advertises
  the submission capability; falls back to SMTP otherwise.
- **JMAP push**: `_JmapAccountSync._wait()` subscribes to the server's SSE
  `eventSourceUrl` via `watchJmapPush`; falls back to 30 s polling when push
  is unavailable or the server does not advertise the URL.
- `notUpdated`/`notDestroyed` per-item errors from `Email/set` are treated as
  permanent failures and discarded immediately (no retry).

### IMAP

- Background sync starts automatically for IMAP accounts.
- Mailbox lists and mailbox counters are synced into the local database.
- Email headers, flags, and attachment metadata are pulled from IMAP into the local database.
- Email bodies are fetched on demand and cached locally.
- All mailboxes (not just INBOX) are synced each cycle.
- Incremental sync: `(lastUid, uidValidity)` checkpoint stored in `sync_state`; only
  new UIDs are fetched on subsequent runs; UID-validity change triggers a full re-scan.
- Deletion reconciliation: server UID set is compared against local rows; any email
  absent from the server is removed from the local DB.
- Local mutations (flag, move, delete) are written to `pending_changes` with an
  optimistic local update; `flushPendingChanges` drains the queue over a single
  IMAP connection at the start of each sync cycle.
- Sent messages are appended to the Sent folder after SMTP delivery.
- IMAP move remap: after a `MOVE` is flushed, the local row id is rewritten in
  place using the RFC 4315 `COPYUID` response code (UIDPLUS); if the server
  doesn't support UIDPLUS, the new UID is looked up via `UID SEARCH HEADER
  Message-ID …` in the destination mailbox. Cached bodies (`email_bodies`),
  threads, queued pending changes, and undo entries follow the new id.
  Deletion reconciliation skips rows whose `move`/`snooze`/`unsnooze` is still
  in `pending_changes` so the optimistic local move isn't wiped mid-flight.
- Sync retries use exponential backoff after failures.

### Cross-protocol

- `sync_log` table records each sync cycle's account, result (ok / error), error
  message, start time, and finish time. Used for debugging and "last synced" UI.
- **Conflict-resolution policy: server-wins.** The next sync cycle always
  overwrites local state with server values. Outbound mutations in
  `pending_changes` are retried up to 5 times before being evicted, preventing
  unbounded queue growth. Permanent per-item JMAP errors (`notFound`,
  `forbidden`) are discarded immediately; transient errors (network, 500)
  are retried up to the limit.
- Integration test (`test/integration/concurrent_sync_test.dart`) concurrently
  syncs an IMAP account (alice) and a JMAP account (bob) against a real Stalwart
  server and verifies the Drift DB cache is consistent (no duplicates, correct
  counts, no pending changes).

---

## Next steps

All planned sync-layer features are implemented. Possible future work:

- **IMAP CONDSTORE / QRESYNC**: use `MODSEQ` for faster incremental sync on
  servers that support RFC 7162.
- **JMAP blob expiry**: detect and re-fetch body blobs that the server has
  purged (currently the cache is assumed permanent).
- **Offline compose queue**: surface `pending_changes` failures in the UI so
  the user can retry or discard stuck outbound mutations.
