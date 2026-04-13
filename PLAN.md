# SharedInbox Implementation Plan

## Context

SharedInbox is a JMAP email client (RFC 8621) built from scratch using Kotlin Compose Multiplatform.
The goal is a working MVP email client targeting **Android, Desktop (JVM), and iOS**, tested against
a self-hosted **Stalwart Mail** server, built with **JetBrains Amper** and managed via **Nix flake**.

Phases 0–2 are complete: scaffolding, core models, auth/session discovery, and `TokenStore`.

---

## Project Layout

```
sharedinbox/
├── flake.nix
├── flake.lock
├── .envrc                         # direnv: use flake
├── project.yaml                   # Amper multi-module root
├── amper                          # Amper wrapper (provided via Nix fetchurl, not curl)
├── amper.bat
├── gradlew                        # Gradle wrapper — used only by codegen/
├── gradle/wrapper/                # Gradle wrapper jar + properties
├── libs.versions.toml             # Central version catalog (project root)
│
├── codegen/                       # Standalone Gradle project — SQLDelight code generation only
│   ├── build.gradle.kts           # Applies SQLDelight plugin; task generateAndCopy
│   └── settings.gradle.kts
│
├── core/
│   └── module.yaml               # KMP lib: jvm + android + iosArm64 + iosSimulatorArm64 + iosX64
│                                 # JMAP domain models, repository interfaces, no UI/HTTP
│
├── data/
│   ├── module.yaml               # KMP lib: same platforms
│   │                             # Ktor HTTP, SQLDelight DB, JMAP API impl, sync engine
│   └── src/
│       ├── de/sharedinbox/data/  # Common Kotlin sources
│       ├── sqldelight/de/sharedinbox/data/db/  # .sq schema files
│       └── generated/de/sharedinbox/data/db/  # SQLDelight-generated Kotlin (committed)
│
├── ui/
│   └── module.yaml               # KMP lib + Compose enabled
│                                 # Screens, ViewModels, Navigation graph, Koin DI wiring
│
├── android-app/
│   ├── module.yaml               # product: android/app
│   └── src/
│       ├── AndroidManifest.xml
│       └── de/sharedinbox/android/MainActivity.kt
│
├── desktop-app/
│   ├── module.yaml               # product: jvm/app
│   └── src/de/sharedinbox/desktop/Main.kt
│
├── ios-app/
│   ├── module.yaml               # product: ios/app
│   ├── src/de/sharedinbox/ios/MainViewController.kt
│   └── iosApp/                   # Xcode project (Swift glue)
│
└── stalwart-dev/
    ├── config.toml               # Minimal Stalwart config for local dev/testing (no Docker)
    ├── start                     # Starts Stalwart with the local config
    └── test.sh                   # Starts Stalwart, runs JVM integration tests, stops it
```

---

## Amper Quirks

1. **No single `@ios` platform qualifier** — must list `@iosArm64`, `@iosSimulatorArm64`, `@iosX64`
   separately (or define an `aliases:` key in module.yaml).
2. **SQLDelight Gradle plugin is incompatible** with Amper standalone — `data/build.gradle.kts` is
   ignored entirely. Code generation runs via the standalone `codegen/` Gradle project:
   `./gradlew --project-dir codegen generateAndCopy`. Generated files are committed to
   `data/src/generated/` so fresh clones build without needing to run codegen first.
   `stalwart-dev/test.sh` auto-regenerates when any `.sq` file changes.
3. **Amper 0.10 is still experimental** — pin the wrapper version tightly, breaking changes between
   minor versions are possible.
4. **`libs.versions.toml` must be at project root** (not `gradle/`).
5. **`kotlin.time.Clock`** — `kotlinx-datetime 0.7.1` has no `Clock` class; use `kotlin.time.Clock`
   from the stdlib instead.

---

## Key Libraries

| Purpose | Library | Scope |
|---|---|---|
| HTTP | `io.ktor:ktor-client-{core,auth,content-negotiation,logging}:3.4.2` | commonMain |
| HTTP engine | `ktor-client-okhttp` / `ktor-client-darwin` / `ktor-client-cio` | per platform |
| SSE/Push | Included in `ktor-client-core` — `client.serverSentEventsSession {}` | commonMain |
| JSON | `org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0` | commonMain |
| Coroutines | `org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2` | commonMain |
| DateTime | `org.jetbrains.kotlinx:kotlinx-datetime:0.7.1` | commonMain |
| Navigation | `org.jetbrains.androidx.navigation3:navigation3-ui:1.0.0-alpha05` + `lifecycle-viewmodel-navigation3` | commonMain |
| DI | `io.insert-koin:koin-{core,compose}:4.1.1` | commonMain |
| ViewModel | `org.jetbrains.androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0` | commonMain |
| Local DB | `app.cash.sqldelight:*:2.3.2` via Gradle-interop mode | all platforms |

**Engine note:** Use Darwin engine on iOS (not CIO) — CIO has known TLS failures on Kotlin/Native.

---

## JMAP Client Layer

### Core domain objects (`core` module)

Key files under `core/src/de/sharedinbox/core/`:

- `account/Account.kt` — `Account` (local record: id, displayName, hostname, username,
  jmapAccountId)
- `jmap/Session.kt` — `JmapSession`, `JmapAccount`
- `jmap/JmapRequest.kt` — `JmapRequest`, `JmapResponse`, `MethodCall` / `MethodResponse` with custom
  serializers for the `["name", {...}, "clientId"]` array wire format
- `jmap/mail/Mailbox.kt` — `Mailbox`, `MailboxRights`
- `jmap/mail/Email.kt` — `Email`, `EmailAddress`, `EmailBodyPart`, `EmailBodyValue`
- `jmap/push/StateChange.kt` — SSE push payload

`Account` is the local concept (one row per configured server). `jmapAccountId` is the remote JMAP
`accountId` returned by the session resource.

### Repository interfaces (`core`)

All repositories are **account-scoped** — every method takes or implies an `accountId`.

```
AccountRepository   — observeAccounts(): Flow<List<Account>>
                      addAccount(hostname, username, password): Result<Account>
                      removeAccount(accountId)
SessionRepository   — discover(baseUrl, username, password): Result<JmapSession>
                      getSession(accountId): JmapSession?
MailboxRepository   — observeMailboxes(accountId): Flow<List<Mailbox>>
                      syncMailboxes(accountId)
EmailRepository     — observeEmails(accountId, mailboxId): Flow
                      syncEmails(accountId, mailboxId)
                      getEmail(accountId, emailId): Result<Email>
                      setKeyword / moveEmail / sendEmail / deleteEmail
                        — all take accountId
TokenStore          — saveCredentials(accountId, username, password)
                      loadCredentials(accountId): StoredCredentials?
                      clearCredentials(accountId)
                      implementations: EncryptedSharedPrefs (Android),
                      Keychain (iOS), file-based (JVM)
```

### SQLDelight schema (`data/src/sqldelight/de/sharedinbox/data/db/`)

Every table references `account`:

```sql
-- account: one row per configured JMAP server
CREATE TABLE account (
    id               TEXT PRIMARY KEY,  -- local UUID
    display_name     TEXT NOT NULL,
    base_url         TEXT NOT NULL,
    username         TEXT NOT NULL,
    jmap_account_id  TEXT NOT NULL,  -- remote JMAP accountId from session
    api_url          TEXT NOT NULL,
    upload_url       TEXT NOT NULL,
    download_url     TEXT NOT NULL,
    event_source_url TEXT NOT NULL,
    added_at         INTEGER NOT NULL
);

-- mailbox: scoped to account
CREATE TABLE mailbox (
    id           TEXT NOT NULL,
    account_id   TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    role         TEXT,
    parent_id    TEXT,
    sort_order   INTEGER NOT NULL DEFAULT 0,
    unread_emails INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (id, account_id)
);

-- email_header: scoped to account
CREATE TABLE email_header (
    id           TEXT NOT NULL,
    account_id   TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    thread_id    TEXT NOT NULL,
    mailbox_id   TEXT NOT NULL,
    subject      TEXT,
    from_address TEXT,
    received_at  INTEGER NOT NULL,
    keywords     TEXT NOT NULL DEFAULT '',  -- JSON array: ["$seen","$flagged"]
    has_attachment INTEGER NOT NULL DEFAULT 0,
    preview      TEXT,
    PRIMARY KEY (id, account_id)
);

-- email_body: fetched on demand
CREATE TABLE email_body (
    email_id     TEXT NOT NULL,
    account_id   TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    text_body    TEXT,
    html_body    TEXT,
    PRIMARY KEY (email_id, account_id)
);

-- state_token: JMAP incremental sync cursors
CREATE TABLE state_token (
    account_id   TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
    type_name    TEXT NOT NULL,  -- "Mailbox", "Email", etc.
    state        TEXT NOT NULL,
    PRIMARY KEY (account_id, type_name)
);
```

Deleting an account cascades to all its mailboxes, emails, bodies, and state tokens.

### JMAP API implementation (`data` module)

- `JmapApiClient` — wraps Ktor; single `POST apiUrl` with `JmapRequest` body; one instance per
  account
- `createHttpClient(username, password): HttpClient` — plain function; engine auto-detected from classpath (no expect/actual needed)
- `AccountSyncManager` — owns a `Map<accountId, SyncOrchestrator>`; starts/stops orchestrators as
  accounts are added/removed
- `SyncOrchestrator(accountId)` — reads/writes `state_token` for its account; calls `*/changes` for
  incremental sync
- `JmapEventSourceService(accountId)` — one SSE connection per account; dispatches `StateChange` to
  its `SyncOrchestrator`; reconnects on drop

**Auth:** HTTP Basic via Ktor `basic {}` provider (Stalwart supports this). OAuth2 deferred
post-MVP.

---

## App Architecture

```text
Network (JMAP server / Stalwart)
       ↓
  data module: Sync engine + JmapApiClient + JmapEventSourceService (SSE)
       ↓  ↑
  SQLDelight (local DB — mailbox, email_header, email_body, state_token tables)
       ↓
  data module: Repository Flow queries (UI-facing)
       ↓
  ui module: Compose screens + ViewModels (read DB only, never network)
       ↓
Platform shell (android-app / desktop-app / ios-app)
```

- UI reads exclusively from SQLDelight `Flow` queries — never calls the network directly.
- Sync engine runs independently; SSE push triggers incremental `*/changes` calls.
- Each ViewModel exposes `StateFlow<UiState>` and receives intents via `fun onIntent(intent)`.
- Navigation uses Navigation 3: `@Serializable` sealed `Screen` routes implement `NavKey`; `NavDisplay` + `entryProvider` replace `NavHost`.
- Koin DI: `dataModule` + `uiModule` started from each platform entry point.

---

## Screen List (MVP)

| Screen | Route | Notes |
|---|---|---|
| Account List | `Screen.AccountList` | All configured accounts with unread totals; "Add account" button; entry point on first launch |
| Add Account | `Screen.AddAccount` | Hostname + username + password; session discovery + Basic auth; writes `account` row |
| Mailbox List | `Screen.MailboxList(accountId)` | Mailboxes for one account with unread counts; pull-to-refresh |
| Email List | `Screen.EmailList(accountId, mailboxId)` | Subject/from/preview/date; swipe actions |
| Email Detail | `Screen.EmailDetail(accountId, emailId)` | Plain-text body (HTML deferred); mark-as-read on open |
| Compose / Reply | `Screen.Compose(accountId)` | To/CC/Subject/Body; `Email/set create` + blob upload |
| Settings | `Screen.Settings` | Manage accounts (remove); app preferences |

Navigation entry point: `AccountList`.

---

## Phased Implementation

Build order: data layer first, UI last.

| Phase | Scope | Done when |
|---|---|---|
| **0 — Scaffolding** ✓ | Directories, module.yamls, `flake.nix` with `stalwart-mail` + Amper via `fetchurl`, `libs.versions.toml`, `stalwart-dev/config.toml` | `./amper build` succeeds; `stalwart-mail --config stalwart-dev/config.toml` starts |
| **1 — Core models** ✓ | `@Serializable` data classes, custom `MethodCall` serializer, repository interfaces, unit tests | Serialization round-trips pass against captured Stalwart JSON |
| **2 — Auth & session** ✓ | `createHttpClient` expect/actual, session discovery (`/.well-known/jmap`), Basic auth, `TokenStore` expect/actual (keyed by accountId) | Integration test: Stalwart session parsed; tokens stored and retrieved per account |
| **3 — SQLDelight schema** ✓ | Standalone `codegen/` Gradle project for SQLDelight generation; `account` table + all child tables with `account_id` FK + `ON DELETE CASCADE`; driver expect/actual; generated code committed to `data/src/generated/` | Schema compiles; insert + query tests pass; cascade delete removes all account data |
| **4 — Account management** ✓ | `AccountRepositoryImpl`: add account (discover → auth → insert row), remove account (delete cascades), `observeAccounts()` Flow; `FileTokenStore` (JVM) | Integration test: add two Stalwart accounts; both rows in DB; remove one cascades all its data |
| **5 — Mailbox sync** ✓ | `MailboxRepositoryImpl` scoped by accountId; `Mailbox/get` + `Mailbox/changes`; `observeMailboxes(accountId)` Flow; `JmapApiClient` for JMAP POST calls | Integration test: mailboxes for both accounts sync independently; incremental sync idempotent; cascade delete on account removal |
| **6 — Email header sync** | `EmailRepositoryImpl` scoped by accountId; `Email/query` + `Email/get` (headers); pagination; `state_token` per account | Integration test: email lists for both accounts in DB; incremental sync fetches only deltas |
| **7 — Email body sync** | On-demand body fetch per account; stored in `email_body(account_id, email_id)`; not re-fetched if already present | Integration test: body available offline after first open |
| **8 — Push / SSE** | `AccountSyncManager` starts one `JmapEventSourceService` + `SyncOrchestrator` per account; reconnect on drop; stops when account removed | Integration test: new email on account A appears in DB; account B unaffected |
| **9 — Mutations** | Keyword set, move, delete, send — all account-scoped; `Identity/get` per account | Integration test: mutations on account A don't affect account B |
| **10 — UI: Accounts + browse** | Koin wiring, `AccountListScreen`, `AddAccountScreen`, `MailboxListScreen`, `EmailListScreen`, `EmailDetailScreen`, Navigation graph, platform entry points | End-to-end: add two accounts, browse each inbox, read email |
| **11 — UI: Compose + Settings** | `ComposeScreen` (account-scoped), `SettingsScreen` (remove account), remove cascades cleanly | Send email; remove one account; other account unaffected |
| **12 — Polish** | Error screens, retry logic, Android WorkManager background sync, desktop tray, accessibility | Production-ready |

---

## Open Decisions

1. **HTML rendering** — Plain-text only for MVP. Evaluate `compose-webview-multiplatform` for Phase
   11.
2. **OAuth2** — HTTP Basic for MVP (Stalwart supports it); OAuth2 post-MVP.
3. **Thread view** — Flat email list per mailbox for MVP; threaded conversation view post-MVP.
