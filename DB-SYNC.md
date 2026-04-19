# DB Sync Status

This document covers the mail-to-database sync layer only, not the UI.

## Implemented features

### IMAP

- Background sync starts automatically for IMAP accounts.
- Mailbox lists and mailbox counters are synced into the local database.
- Email headers, flags, and attachment metadata are pulled from IMAP into the local database.
- Email bodies are fetched on demand and cached locally.
- User-triggered changes are sent to the server immediately: seen, flagged, move, delete, and send.
- Sent messages are appended to the Sent folder after SMTP delivery.
- Sync retries use exponential backoff after failures.

### JMAP

- JMAP accounts can be stored in the database.
- JMAP endpoint discovery is implemented.
- JMAP connection testing is implemented.

## Missing features

### IMAP

- No general outbound DB-to-IMAP sync queue for arbitrary local database changes.
- Background sync currently refreshes only INBOX, not all folders.
- No persisted sync log or audit trail in the database.
- No explicit conflict-resolution strategy such as revisions, merge rules, or retryable pending operations.
- No full reconciliation for remote deletions, mailbox removals, or stale local rows.
- No incremental sync checkpoints such as last synced UID, MODSEQ, or similar state.
- No durable offline-first sync state tracking.

### JMAP

- No JMAP mailbox sync into the local database.
- No JMAP email sync into the local database.
- No DB-to-JMAP change propagation.
- No background JMAP sync worker.
- No JMAP conflict handling.
- No JMAP sync log in the database.

## Current summary

- IMAP: partially implemented and already usable, but not full bidirectional sync.
- JMAP: account setup exists, but actual sync is still missing.
