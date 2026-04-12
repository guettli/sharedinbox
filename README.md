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
| 3 — SQLDelight schema | Local DB schema with `account_id` FK on all tables | Pending |
| 4+ — Sync, UI | Account management, mailbox/email sync, SSE push, Compose UI | Pending |

## Build tooling

- [JetBrains Amper](https://github.com/JetBrains/amper) — build system
- [Nix flake](flake.nix) — reproducible dev environment (JDK 21, Android SDK)
- [Stalwart Mail](stalwart-dev/config.toml) — local JMAP server for integration tests (via
  `pkgs.stalwart-mail` in Nix)

## Testing

### Unit tests (no server needed)

```bash
./amper test :core
```

Runs `JmapSerializationTest` — verifies JMAP wire-format serialization round-trips.

### Integration tests (requires Stalwart)

Start the local Stalwart instance in one terminal:

```bash
stalwart-mail --config stalwart-dev/config.toml
```

Then run the integration tests with the required environment variables:

```bash
STALWART_URL=http://localhost:8080 \
STALWART_USER_A=admin \
STALWART_PASS_A=admin \
./amper test :data
```

Runs `SessionRepositoryIntegrationTest` — covers session discovery, redirect handling, bad
credentials, and `TokenStore` round-trips.

Inside `nix develop` all tools (`stalwart-mail`, `amper`, JDK 21) are available automatically.
