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

## Phases

| Phase | Scope | Status |
| --- | --- | --- |
| 0 — Scaffold | pubspec, Drift schema, DI, router, enough_mail from pub.dev | Done |
| 1 — Core models | `Account`, `Mailbox`, `Email`, `EmailBody`, repository interfaces | Done |
| 2 — DB layer | Drift tables, `AccountRepositoryImpl`, `MailboxRepositoryImpl`, `EmailRepositoryImpl` | Done |
| 3 — IMAP sync | `connectImap`, `MailboxRepositoryImpl.syncMailboxes`, `EmailRepositoryImpl.syncEmails` | Done |
| 4 — IMAP IDLE | `AccountSyncManager` with exponential-backoff reconnect | Done |
| 5 — SMTP send | `connectSmtp`, `EmailRepositoryImpl.sendEmail` | Done |
| 6 — UI | AccountList, AddAccount, MailboxList, EmailList, EmailDetail, Compose, Settings | Done |
| 7 — Dev tooling | Nix flake, Taskfile, Stalwart dev server, unit + integration tests, CI, pre-commit | Done |
| 8 — UI gaps | Account picker in compose, flag/unflag, move-to-folder, attachment indicators | Done |

## Next candidates

- Search (IMAP `SEARCH` command)
- Thread view (group by `References` / `In-Reply-To`)
- Attachment download + open
- Draft auto-save
