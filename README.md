# SharedInbox [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](packages/enough_mail/LICENSE)

IMAP/SMTP email client written in [Flutter](https://flutter.dev).

Targets **Android, iOS, and Desktop** (Linux, macOS, Windows).  
Supports **multiple accounts** — each synced independently via IMAP IDLE.

## Design philosophy: offline-first

```
IMAP/SMTP server
       ↓
  AccountSyncManager  ←→  Drift (SQLite, local DB)
                                   ↓
                             UI (reads only from DB)
```

The UI never touches the network. The sync engine runs in the background and writes to a local Drift database. Screens observe reactive streams from that DB.

## Key packages

| Package | Role |
|---|---|
| `enough_mail` (vendored in `packages/`) | IMAP / SMTP / MIME |
| `drift` | Local SQLite ORM |
| `flutter_riverpod` | State management / DI |
| `go_router` | Navigation |

## Building

```bash
# Install dependencies and run code generation
dart pub get
dart run build_runner build --delete-conflicting-outputs

# Run on desktop
flutter run -d linux   # or macos / windows

# Run on Android / iOS
flutter run
```

## Vendored enough_mail

`packages/enough_mail/` is a local copy of [enough_mail](https://github.com/Enough-Software/enough_mail) so it can be modified if needed. It is referenced via a `path:` dependency in `pubspec.yaml`.
