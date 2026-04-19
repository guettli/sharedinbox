# DB Sync Status

This document covers the mail-to-database sync layer only, not the UI.

## Implemented features

### JMAP

- JMAP accounts can be stored in the database.
- JMAP endpoint discovery is implemented.
- JMAP connection testing is implemented.

### IMAP

- Background sync starts automatically for IMAP accounts.
- Mailbox lists and mailbox counters are synced into the local database.
- Email headers, flags, and attachment metadata are pulled from IMAP into the local database.
- Email bodies are fetched on demand and cached locally.
- User-triggered changes are sent to the server immediately: seen, flagged, move, delete, and send.
- Sent messages are appended to the Sent folder after SMTP delivery.
- Sync retries use exponential backoff after failures.

---

## Plan

Goal: make bidirectional DB↔JMAP sync easy and correct. JMAP is the preferred protocol
long-term because its state-based change tracking is cleaner than IMAP's UID/MODSEQ model.
All DB foundations are protocol-agnostic so IMAP can use the same tables later.

### Step 1 — `sync_state` table `[x]`

A single table that stores the server-side state token per (account, resource type).
For JMAP this is the opaque `state` string returned by `Mailbox/get` and `Email/get`.
For IMAP it will hold a JSON checkpoint (last UID, MODSEQ) per mailbox.

Schema:

```sql
sync_state (
  account_id    TEXT     NOT NULL,
  resource_type TEXT     NOT NULL,   -- e.g. "Mailbox", "Email", "INBOX"
  state         TEXT     NOT NULL,   -- JMAP state string or IMAP checkpoint JSON
  synced_at     DATETIME NOT NULL,
  PRIMARY KEY (account_id, resource_type)
)
```

### Step 2 — `pending_changes` table `[ ]`

Protocol-agnostic outbound queue. Any local mutation (flag, move, delete) is written
here first. A sync worker drains the queue and sends to server. Enables offline-first.

Schema:

```sql
pending_changes (
  id            INTEGER  PRIMARY KEY AUTOINCREMENT,
  account_id    TEXT     NOT NULL,
  resource_type TEXT     NOT NULL,   -- "Email"
  resource_id   TEXT     NOT NULL,   -- local email id
  change_type   TEXT     NOT NULL,   -- "flag_seen" | "flag_flagged" | "move" | "delete"
  payload       TEXT     NOT NULL,   -- JSON, e.g. {"seen": true} or {"dest": "Archive"}
  created_at    DATETIME NOT NULL,
  attempts      INTEGER  NOT NULL DEFAULT 0,
  last_error    TEXT
)
```

### Step 3 — JMAP session client `[ ]`

Implement `JmapSession`: parse the JMAP Session object from `GET {jmapUrl}`,
extract `apiUrl`, primary `accountId`, and capabilities. Store nothing extra in the
DB (re-fetch session on start). Provide a `call(methodCalls)` helper that POSTs to
`apiUrl` and decodes responses.

### Step 4 — JMAP Mailbox sync `[ ]`

Implement `syncMailboxes(accountId)` for JMAP:

- First run: `Mailbox/get` → upsert all mailboxes, persist state in `sync_state`.
- Subsequent runs: `Mailbox/changes` using stored state → apply additions, updates,
  removals, then update state.

Reuse the existing `Mailboxes` table. No new DB columns needed.

### Step 5 — JMAP Email sync `[ ]`

Implement `syncEmails(accountId, mailboxId)` for JMAP:

- First run: `Email/query` (sorted by receivedAt desc, limit 500) + `Email/get` for
  the returned ids → upsert into `Emails`, persist state.
- Subsequent runs: `Email/changes` using stored state → fetch new/changed via
  `Email/get`, delete removed rows, update state.

No new DB columns needed beyond `sync_state`.

### Step 6 — JMAP background sync worker `[ ]`

Add JMAP handling to `AccountSyncManager`:

- When a JMAP account appears, start a `_JmapAccountSync` loop.
- Loop: session → syncMailboxes → syncEmails for each mailbox → wait (poll or
  EventSource if server supports it) → repeat.
- Reuse the existing exponential backoff pattern from `_AccountSync`.

### Step 7 — JMAP outbound changes `[ ]`

Wire local mutations (flag, move, delete) for JMAP accounts into `pending_changes`
instead of direct server calls. Add a queue-draining step at the start of each sync
loop that issues `Email/set` for queued changes and removes them on success.

---

## Missing features (to be addressed after the plan above)


### JMAP missing features

- Everything in the plan above (Steps 3–7).
- No conflict handling (deferred; JMAP's `ifInState` provides the hook for it later).
- No sync log in database (deferred).

### IMAP missing features

- Background sync refreshes only INBOX; other folders need the same treatment.
- No incremental sync checkpoints (will use `sync_state` once Step 1 is done).
- No durable outbound queue (will use `pending_changes` once Step 2 is done).
- No full reconciliation for remote deletions.
- No explicit conflict-resolution strategy.
- No sync log or audit trail.

## Current summary

- IMAP: partially implemented and already usable, but not full bidirectional sync.
- JMAP: account setup exists, but actual sync is still missing.
- Plan above targets JMAP first; IMAP improvements follow naturally once the shared
  DB foundations (Steps 1–2) are in place.
