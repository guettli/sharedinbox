# SharedInbox [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](packages/enough_mail/LICENSE)

IMAP/SMTP email client written in [Flutter](https://flutter.dev).

Targets **Android, iOS, and Desktop** (Linux done; macOS, Windows, Android, iOS scaffolded).  
Supports **multiple accounts** — each synced independently via IMAP IDLE.

## Design philosophy: offline-first

```text
IMAP/SMTP server
       ↓
  AccountSyncManager  ←→  Drift (SQLite, local DB)
  (IMAP IDLE per account)         ↓
                            UI (reads only from DB)
```

The UI never touches the network. The sync engine runs in the background and writes to a local [Drift](https://drift.simonbinder.eu/) database. Screens observe reactive streams from that DB.

## Platform support

| Platform | Status |
| --- | --- |
| Linux desktop | Working (`task run`) |
| Android | APK builds (`task build-android`) |
| macOS desktop | Scaffolded |
| Windows desktop | Scaffolded |
| iOS | Scaffolded |

## Key packages

| Package | Role |
| --- | --- |
| [`enough_mail`](https://pub.dev/packages/enough_mail) | IMAP / SMTP / MIME |
| `drift` | Local SQLite ORM (offline-first store) |
| `flutter_riverpod` | State management / DI |
| `go_router` | Navigation |
| `flutter_secure_storage` | Password storage |

---

## For users

Download the latest release from the [Releases page](https://github.com/guettli/sharedinbox3/releases) *(not yet published)*.

Run the app, tap **+**, and enter your IMAP/SMTP server details. The app syncs your INBOX in the background using IMAP IDLE and works offline — the network is only needed during initial sync and when sending mail.

---

## For developers

### Prerequisites

[Nix](https://nixos.org/download) with flakes enabled, and [direnv](https://direnv.net/).

```bash
# One-time: allow direnv in this directory
direnv allow
```

`direnv` loads the Nix flake automatically — no manual `nix develop` needed after that. The flake pins **Flutter 3.41.6**, Android SDK, Stalwart mail server (for integration tests), and all Linux desktop build tools (GTK3, clang, cmake).

### First-time setup

```bash
# Generate the Drift database layer (required before first build)
task codegen

# Verify everything compiles and tests pass
task check
```

### Daily workflow

```bash
task analyze          # flutter analyze (uses analysis_options.yaml)
task test             # pure-Dart unit tests — fast, no device
task test-flutter     # Flutter widget tests
task integration      # IMAP/SMTP integration tests via local Stalwart server
task run              # flutter run -d linux
task analyze-fix      # dart fix --apply
```

`task check` runs `analyze` + `test` in parallel — use it before every commit.

### After changing the DB schema

Edit `lib/data/db/database.dart`, then:

```bash
task codegen   # regenerates lib/data/db/database.g.dart
```

`database.g.dart` is git-ignored; every developer must regenerate it after cloning or pulling schema changes.

### Integration tests

```bash
task integration
```

Starts a local [Stalwart](https://stalw.art) mail server on random ports, runs the tests in `test/integration/`, then stops it. No manual setup needed — Stalwart is provided by the Nix flake.

### Adding a screen

1. Create `lib/ui/screens/my_screen.dart` — extend `ConsumerWidget`.
2. Add a `GoRoute` in `lib/ui/router.dart`.
3. Read from Riverpod providers in `lib/di.dart`; never call the network directly from UI.

### Project layout

```text
lib/
  core/
    models/          — plain Dart data classes (Account, Email, Mailbox, …)
    repositories/    — abstract interfaces
    sync/            — AccountSyncManager (IMAP IDLE + backoff)
    utils/           — htmlToPlain, fmtSize (pure functions, unit-tested)
  data/
    db/              — Drift schema + generated code
    imap/            — connectImap / connectSmtp helpers
    repositories/    — concrete implementations
  ui/
    screens/         — one file per screen
    router.dart      — go_router route tree
  di.dart            — Riverpod providers
  main.dart          — entry point

packages/
  enough_mail/       — vendored IMAP/SMTP library (editable)

stalwart-dev/        — local mail server config + start/test scripts
test/
  unit/              — pure-Dart unit tests (no device)
  integration/       — IMAP/SMTP tests against local Stalwart
```

---

## Working features

- **Multiple accounts** — add any number of IMAP/SMTP accounts; each syncs independently
- **IMAP IDLE** — background sync with push-like latency; exponential backoff (5 s → 5 min) on error
- **Mailbox list** — shows all folders with unread / total counts
- **Email list** — sender, subject, date; bold for unread; manual sync button
- **Email detail** — renders plain text; falls back to HTML→plain conversion; marks as read on open; shows attachment names and sizes
- **Reply / Reply all** — pre-fills To, Subject (`Re:`), Cc from original
- **Compose** — To, Cc, Subject, Body fields; sends via SMTP
- **Flag / unflag** — star button in detail view; amber star indicator in list; synced to server
- **Move to folder** — bottom-sheet folder picker; moves on server via IMAP MOVE
- **Attachment indicators** — paperclip icon in email list; filename + size in detail
- **Delete email** — removes from server (IMAP expunge) and local DB
- **Settings** — list and remove accounts
- **Offline-first** — all reads come from local Drift/SQLite DB; network only for sync and send
