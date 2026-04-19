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
- Sync retries use exponential backoff after failures.

### Cross-protocol

- `sync_log` table records each sync cycle's account, result (ok / error), error
  message, start time, and finish time. Used for debugging and "last synced" UI.

---

## Next steps

### JMAP hardening

- **Body caching during sync**: `syncEmails` currently syncs headers only. Include
  `bodyValues` + `htmlBody`/`textBody` in the `Email/get` properties list so bodies
  are written to `email_bodies` during the sync pass, not just on first open.
- **JMAP send**: implement outgoing mail via `EmailSubmission/set` in addition to the
  current SMTP path.
- **Push instead of polling**: upgrade `_JmapAccountSync._wait()` to use an
  `EventSource` connection to the JMAP push URL when the server advertises push
  capability. Fall back to 30 s polling when push is unavailable.
- **Conflict handling**: pass `ifInState` to `Email/set` in `flushPendingChanges` so
  the server can reject a stale mutation; retry the affected change after re-syncing.

### Shared / cross-protocol

- **Explicit conflict-resolution strategy**: decide and document the policy (last-write-
  wins vs. server-wins) and implement it consistently across both protocols.
