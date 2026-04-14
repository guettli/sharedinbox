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

## Platform support

The desktop app (Linux, macOS, Windows) is the only supported target today. The project is
structured with Kotlin Compose Multiplatform so that Android and iOS can be added later without
architectural changes — the modules `android-app` and `ios-app` already exist and share the same
UI and sync engine.

## Current status

| Phase | Scope | Status |
| --- | --- | --- |
| 0 — Scaffolding | Module layout, Nix flake, Amper, Stalwart dev config | Done |
| 1 — Core models | `@Serializable` data classes, JMAP wire format, repository interfaces | Done |
| 2 — Auth & session | Session discovery, Basic auth, `TokenStore` (JVM: file-based) | Done |
| 3 — SQLDelight schema | Local DB schema with `account_id` FK on all tables | Done |
| 4 — Account management | `AccountRepositoryImpl`: add/remove accounts, `observeAccounts()` Flow | Done |
| 5 — Mailbox sync | `MailboxRepositoryImpl`, `JmapApiClient`, full + incremental sync | Done |
| 6 — Email header sync | `EmailRepositoryImpl.syncEmails` + `observeEmails`: `Email/query`, `Email/get`, `Email/changes` | Done |
| 7 — Email body sync | `EmailRepositoryImpl.getEmail`: on-demand body fetch, cached in `email_body` | Done |
| 8 — Push / SSE | `AccountSyncManager`: one SSE connection per account, exponential-backoff reconnect | Done |
| 9 — Mutations | `setKeyword`, `moveEmail`, `deleteEmail`, `sendEmail` (with `EmailSubmission/set` fallback) | Done |
| 10 — UI | Koin DI, Compose screens, Navigation, platform entry points | Done |
| 11 — Compose + Settings | `ComposeScreen`, `SettingsScreen`, send + remove account | Done |
| 12 — Polish | Error handling, background sync, desktop tray, WorkManager, SSE wiring | Done |

## Build tooling and known gotchas

- [JetBrains Amper](https://github.com/JetBrains/amper) — build system
- [Nix flake](flake.nix) — reproducible dev environment (JDK 21, Android SDK)
- [Stalwart Mail](stalwart-dev/config.toml) — local JMAP server for integration tests (via
  `pkgs.stalwart-mail` in Nix)
- [Kotlin Multiplatform](https://kotlinlang.org/multiplatform/) /
  [Compose Multiplatform](https://kotlinlang.org/compose-multiplatform/)
- [SQLDelight](https://cashapp.github.io/sqldelight/) — local persistence

### Amper quirks

1. **No single `@ios` qualifier** — list `@iosArm64`, `@iosSimulatorArm64`, `@iosX64` separately in
   `module.yaml`; there is no shorthand `@ios`.
2. **SQLDelight Gradle plugin is incompatible with Amper** — code generation runs via the standalone
   `codegen/` Gradle project (`./gradlew --project-dir codegen generateAndCopy`). Generated files
   are committed to `data/src/generated/` so fresh clones build without running codegen first.
   `stalwart-dev/test.sh` auto-regenerates when any `.sq` file changes.
3. **Pin the Amper wrapper version tightly** — 0.10 is still experimental; minor versions can break.
4. **`libs.versions.toml` must be at the project root**, not under `gradle/`.
5. **No `kotlin.time.Clock` in `kotlinx-datetime`** — `0.7.1` omits it; use `kotlin.time.Clock`
   from the stdlib instead.

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

## Running the app

### As a developer

**Prerequisite:** [Nix](https://nixos.org/download) with flakes enabled.

```bash
git clone https://github.com/yourorg/sharedinbox
cd sharedinbox
nix develop        # installs JDK 21, Amper, Android SDK, Stalwart — takes a few minutes once
amper run -m desktop-app
```

`nix develop` sets up the entire toolchain in an isolated shell. No system-wide installs.
Subsequent `nix develop` invocations are instant (everything is cached in the Nix store).

For Android, connect a device or start an emulator, then:

```bash
amper run -m android-app
```

### As a user

Download the latest release from the
[Releases page](https://github.com/yourorg/sharedinbox/releases).

#### Option A — Native installer (recommended, no JRE needed)

| Platform | File | Install |
| --- | --- | --- |
| Linux | `SharedInbox-x.y.z.deb` | `sudo dpkg -i SharedInbox-x.y.z.deb` |
| macOS | `SharedInbox-x.y.z.dmg` | Open and drag to Applications |
| Windows | `SharedInbox-x.y.z.msi` | Double-click and follow the wizard |

The installer bundles a trimmed JRE — nothing else needs to be installed.

#### Option B — Fat JAR (requires JRE 21)

If you already have [Java 21](https://adoptium.net) installed:

```bash
java -jar sharedinbox-x.y.z-linux.jar   # or -macos / -windows
```

Download the JAR that matches your OS — each bundles the platform-specific
native rendering library.
