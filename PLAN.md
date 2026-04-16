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
| 0 — Scaffold | pubspec, Drift schema, DI, router, enough_mail vendored | Done |
| 1 — Core models | `Account`, `Mailbox`, `Email`, `EmailBody`, repository interfaces | Done |
| 2 — DB layer | Drift tables, `AccountRepositoryImpl`, `MailboxRepositoryImpl`, `EmailRepositoryImpl` | Done |
| 3 — IMAP sync | `connectImap`, `MailboxRepositoryImpl.syncMailboxes`, `EmailRepositoryImpl.syncEmails` | Done |
| 4 — IMAP IDLE | `AccountSyncManager` with exponential-backoff reconnect | Done |
| 5 — SMTP send | `connectSmtp`, `EmailRepositoryImpl.sendEmail` | Done |
| 6 — UI | All screens: AccountList, AddAccount, MailboxList, EmailList, EmailDetail, Compose, Settings | Done |
| 7 — Dev tooling | Nix flake, `.envrc`, Taskfile, Stalwart dev server (IMAP+SMTP), integration tests | Done |
| 8 — Code-gen | Run `task codegen` to generate `database.g.dart` and Riverpod providers | Pending |
| 9 — Platform targets | Android, iOS, Linux, macOS, Windows entry points | Pending |
| 10 — Polish | Reply prefill, attachment open, thread view, search | Next |

## Next candidates

- Reply-with-prefill (subject/body/from populated from original email)
- Thread view (group by `References` / `In-Reply-To`)
- Search (IMAP `SEARCH` command)
- Attachment download + open
- Draft auto-save
