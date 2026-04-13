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

## Current status

| Phase | Scope | Status |
| --- | --- | --- |
| 0 — Scaffolding | Module layout, Nix flake, Amper, Stalwart dev config | Done |
| 1 — Core models | `@Serializable` data classes, JMAP wire format, repository interfaces | Done |
| 2 — Auth & session | Session discovery, Basic auth, `TokenStore` (JVM: file-based) | Done |
| 3 — SQLDelight schema | Local DB schema with `account_id` FK on all tables | Done |
| 4 — Account management | `AccountRepositoryImpl`: add/remove accounts, `observeAccounts()` Flow | Done |
| 5 — Mailbox sync | `MailboxRepositoryImpl`, `JmapApiClient`, full + incremental sync | Done |
| 6+ — Email sync, UI | Email header/body sync, SSE push, Compose UI | Pending |

## Build tooling

- [JetBrains Amper](https://github.com/JetBrains/amper) — build system
- [Nix flake](flake.nix) — reproducible dev environment (JDK 21, Android SDK)
- [Stalwart Mail](stalwart-dev/config.toml) — local JMAP server for integration tests (via
  `pkgs.stalwart-mail` in Nix)
- [Kotlin Multiplatform](https://kotlinlang.org/multiplatform/) /
  [Compose Multiplatform](https://kotlinlang.org/compose-multiplatform/)
- [SQLDelight](https://cashapp.github.io/sqldelight/) — local persistence

## Testing

### Unit tests (no server needed)

```bash
amper test -m core -p jvm
```

Runs `JmapSerializationTest` — verifies JMAP wire-format serialization round-trips.
The `-p jvm` flag skips Android/iOS compilation (which takes several minutes) since
these are pure-logic tests that only need the JVM target.

### Integration tests (requires Stalwart)

```bash
stalwart-dev/test
```

Starts Stalwart in the background, runs the JVM integration tests, then shuts it down.
`STALWART_URL`, `STALWART_USER_A`, and `STALWART_PASS_A` are already exported by
the shell hook — no manual env vars needed. Two clones on the same machine get
different ports and different `/tmp/stalwart-dev-PORT` data directories, so their
test runs never conflict.
