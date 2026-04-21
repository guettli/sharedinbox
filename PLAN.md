# SharedInbox Flutter — Plan

## Architecture

```text
IMAP/SMTP server
       ↓
  AccountSyncManager (IMAP IDLE per account)
       ↓  writes
  Drift (SQLite, local DB)
       ↓  reads
  UI (Riverpod + go_router)
```

UI never touches the network. The sync layer runs independently.

## Next

- [ ] Per-mailbox sync log — current log aggregates all mailboxes; break down fetched/skipped per mailbox path so a stale checkpoint for one folder is immediately visible
- [ ] IMAP trace logging — add `logRequests`/`logResponses` to `connectImap` for debug builds; essential to verify what `UID SEARCH ALL` actually returns from the server
- [ ] Thread view (group by `References` / `In-Reply-To`)
- [ ] Attachment download + open
