# SharedInbox [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

JMAP email client written using [Kotlin Compose
Multiplatform](https://kotlinlang.org/compose-multiplatform/).

Targets **Android, Desktop (JVM), and iOS**. Tested against [Stalwart Mail](https://stalw.art).

Supports **multiple JMAP accounts** simultaneously — connect to N servers at once, each synced
independently.

## Design philosophy: offline-first

The app is built bottom-up. The sync engine and local database are fully working and tested before
any UI is written. The UI reads exclusively from the local SQLDelight database — it never touches
the network directly. The sync layer runs independently in the background.

```text
Network (JMAP server)
       ↓
  Sync engine  ←→  SQLDelight (local DB)
                          ↓
                        UI (read-only from DB)
```

## Build tooling

- [JetBrains Amper](https://github.com/JetBrains/amper) — build system
- [Nix flake](flake.nix) — reproducible dev environment (JDK 21, Android SDK)
- [Stalwart Mail](stalwart-dev/config.toml) — local JMAP server for integration tests (via
  `pkgs.stalwart-mail` in Nix)
