# SharedInbox Implementation Plan

## Context

SharedInbox is a JMAP email client (RFC 8621) built from scratch using Kotlin Compose Multiplatform.
The repo is currently empty (README + AGENTS.md only). The goal is a working MVP email client
targeting **Android, Desktop (JVM), and iOS**, tested against a self-hosted **Stalwart Mail**
server, built with **JetBrains Amper** and managed via **Nix flake**.

The app is built **bottom-up, offline-first**. The sync engine and SQLDelight database are fully
working and integration-tested before any UI is written. The UI reads only from the local DB — it
never touches the network directly.

**Multi-account from day one.** The app connects to N JMAP servers simultaneously. Every DB table
carries an `accountId` foreign key. The sync engine runs one `SyncOrchestrator` and one SSE
connection per account. Repositories are always account-scoped. This is baked into the schema from
Phase 3 — retrofitting it later would require a full migration.

---

## Version Baseline

| Tool / Library | Version |
|---|---|
| Kotlin | 2.3.20 |
| Compose Multiplatform | 1.10.3 |
| Amper wrapper | 0.10.0 |
| Ktor | 3.4.2 |
| kotlinx-serialization-json | 1.11.0 |
| kotlinx-coroutines-core | 1.10.2 |
| kotlinx-datetime | 0.7.1 |
| Koin | 4.1.1 |
| SQLDelight | 2.3.2 |
| lifecycle-viewmodel-compose | 2.10.0 |
| Android compileSdk/targetSdk | 36 |
| Android minSdk | 26 |
| JDK | 21 (Temurin) |

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
├── libs.versions.toml             # Central version catalog (project root)
│
├── core/
│   └── module.yaml               # KMP lib: jvm + android + iosArm64 + iosSimulatorArm64 + iosX64
│                                 # JMAP domain models, repository interfaces, no UI/HTTP
│
├── data/
│   └── module.yaml               # KMP lib: same platforms
│                                 # Ktor HTTP, SQLDelight DB, JMAP API impl, sync engine
│
├── ui/
│   └── module.yaml               # KMP lib + Compose enabled
│                                 # Screens, ViewModels, Navigation graph, Koin DI wiring
│
├── android-app/
│   ├── module.yaml               # product: android/app
│   └── src/
│       ├── AndroidManifest.xml
│       └── kotlin/com/sharedinbox/android/MainActivity.kt
│
├── desktop-app/
│   ├── module.yaml               # product: jvm/app
│   └── src/kotlin/com/sharedinbox/desktop/Main.kt
│
├── ios-app/
│   ├── module.yaml               # product: ios/app
│   ├── src/kotlin/com/sharedinbox/ios/MainViewController.kt
│   └── iosApp/                   # Xcode project (Swift glue)
│
└── stalwart-dev/
    └── config.toml               # Minimal Stalwart config for local dev/testing (no Docker)
```

---

## Amper Setup

### Bootstrap via Nix (`flake.nix`)

Amper is not in nixpkgs. Pin it as a `fetchurl` derivation so the binary is hash-verified and
available automatically in `nix develop` — no manual curl/commit step needed:

```nix
amper = pkgs.stdenv.mkDerivation {
  name = "amper";
  src = pkgs.fetchurl {
    url = "https://packages.jetbrains.team/maven/p/amper/amper/org/jetbrains/amper/cli/0.10.0/cli-0.10.0-wrapper";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";  # fill in: nix-prefetch-url <url>
  };
  dontUnpack = true;
  installPhase = ''install -Dm755 $src $out/bin/amper'';
};
```

Add `amper` to `buildInputs`. Get the correct hash once with:

```bash
nix-prefetch-url "https://packages.jetbrains.team/maven/p/amper/amper/org/jetbrains/amper/cli/0.10.0/cli-0.10.0-wrapper"
```

Contributors run `./amper build` (or just `amper build` inside `nix develop`) with no global
install.

### `project.yaml`

```yaml
modules:
  - ./core
  - ./data
  - ./ui
  - ./android-app
  - ./desktop-app
  - ./ios-app
```

### `core/module.yaml`

```yaml
product:
  type: lib
  platforms: [jvm, android, iosArm64, iosSimulatorArm64, iosX64]

dependencies:
  - $libs.coroutines-core
  - $libs.serialization-json
  - $libs.datetime

test-dependencies:
  - org.jetbrains.kotlin:kotlin-test:2.3.20

settings:
  kotlin:
    serialization: json
```

### `data/module.yaml`

Note: `data/build.gradle.kts` sits alongside this file to apply the SQLDelight Gradle plugin
(Gradle-interop mode).

```yaml
product:
  type: lib
  platforms: [jvm, android, iosArm64, iosSimulatorArm64, iosX64]

dependencies:
  - ../core
  - $libs.ktor-client-core
  - $libs.ktor-client-auth
  - $libs.ktor-client-contentneg
  - $libs.ktor-serialization-json
  - $libs.ktor-client-logging
  - $libs.koin-core
  - $libs.sqldelight-runtime
  - $libs.sqldelight-coroutines

dependencies@android:
  - $libs.ktor-client-okhttp
  - $libs.sqldelight-android

dependencies@iosArm64:
  - $libs.ktor-client-darwin
  - $libs.sqldelight-native
dependencies@iosSimulatorArm64:
  - $libs.ktor-client-darwin
  - $libs.sqldelight-native
dependencies@iosX64:
  - $libs.ktor-client-darwin
  - $libs.sqldelight-native

dependencies@jvm:
  - $libs.ktor-client-cio
  - $libs.sqldelight-jvm

settings:
  kotlin:
    serialization: json
```

### `ui/module.yaml`

```yaml
product:
  type: lib
  platforms: [jvm, android, iosArm64, iosSimulatorArm64, iosX64]

dependencies:
  - ../core: exported
  - ../data: exported
  - $compose.foundation: exported
  - $compose.material3: exported
  - $libs.lifecycle-viewmodel
  - $libs.koin-compose
  - $libs.koin-core

dependencies@android:
  - $libs.activity-compose
  - $libs.koin-android

settings:
  compose:
    enabled: true
  kotlin:
    serialization: json
```

### `android-app/module.yaml`

```yaml
product: android/app

dependencies:
  - ../ui

settings:
  android:
    applicationId: com.sharedinbox.app
    namespace: com.sharedinbox.app
    compileSdk: 36
    targetSdk: 36
    minSdk: 26
    versionCode: 1
    versionName: "0.1.0"
  compose:
    enabled: true
  jvm:
    jdk:
      version: 21
```

### `desktop-app/module.yaml`

```yaml
product: jvm/app

dependencies:
  - ../ui

settings:
  compose:
    enabled: true
  jvm:
    mainClass: com.sharedinbox.desktop.MainKt
    jdk:
      version: 21
```

### Amper Quirks to Watch

1. **No single `@ios` platform qualifier** — must list `@iosArm64`, `@iosSimulatorArm64`, `@iosX64`
   separately (or define an `aliases:` key in module.yaml).
2. **SQLDelight Gradle plugin is incompatible** with Amper standalone — use **Gradle-interop mode**
   for the `data` module from the start: place a `build.gradle.kts` alongside `data/module.yaml` to
   apply the SQLDelight plugin.
3. **Amper 0.10 is still experimental** — pin the wrapper version tightly, breaking changes between
   minor versions are possible.
4. **`libs.versions.toml` must be at project root** (not `gradle/`).

---

## Nix Flake (`flake.nix`)

Pins: **JDK 21 Temurin**, **Android SDK (API 36, build-tools 35)** via `android-nixpkgs/stable`,
base channel `nixpkgs/nixos-25.11`.

```nix
{
  description = "SharedInbox dev environment";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    android-nixpkgs = {
      url = "github:tadfisher/android-nixpkgs/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, android-nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          config.android_sdk.accept_license = true;
        };
        androidSdk = android-nixpkgs.sdk.${system} (s: with s; [
          cmdline-tools-latest build-tools-35-0-0 platform-tools
          platforms-android-36 platforms-android-35 emulator
        ]);
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            temurin-bin-21 androidSdk stalwart-mail amper curl unzip git jq
          ];
          shellHook = ''
            export ANDROID_HOME="${androidSdk}/share/android-sdk"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            export JAVA_HOME="${pkgs.temurin-bin-21}"
            export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
          '';
        };
      });
}
```

`.envrc`:
```bash
use flake
```

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
| Navigation | `org.jetbrains.androidx.navigation:navigation-compose:2.10.0` | commonMain |
| DI | `io.insert-koin:koin-{core,compose}:4.1.1` | commonMain |
| ViewModel | `org.jetbrains.androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0` | commonMain |
| Local DB | `app.cash.sqldelight:*:2.3.2` via Gradle-interop mode | all platforms |

**Engine note:** Use Darwin engine on iOS (not CIO) — CIO has known TLS failures on Kotlin/Native.

---

## JMAP Client Layer

### Core domain objects (`core` module)

Key files under `core/src/commonMain/kotlin/com/sharedinbox/core/`:

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
SessionRepository   — discover(hostname): Result<JmapSession>
                      getSession(accountId): JmapSession?
MailboxRepository   — observeMailboxes(accountId): Flow<List<Mailbox>>
                      syncMailboxes(accountId)
EmailRepository     — observeEmails(accountId, mailboxId): Flow
                      syncEmails(accountId, mailboxId)
                      getEmail(accountId, emailId): Result<Email>
                      setKeyword / moveEmail / sendEmail / deleteEmail
                        — all take accountId
TokenStore          — saveTokens(accountId, …) / loadTokens(accountId) / clear(accountId)
                      expect/actual: EncryptedSharedPrefs (Android),
                      Keychain (iOS), file-based (JVM)
```

### SQLDelight schema (`data/src/commonMain/sqldelight/`)

Every table references `account`:

```sql
-- account: one row per configured JMAP server
CREATE TABLE account (
    id           TEXT PRIMARY KEY,  -- local UUID
    display_name TEXT NOT NULL,
    hostname     TEXT NOT NULL,
    username     TEXT NOT NULL,
    jmap_account_id TEXT NOT NULL,  -- remote JMAP accountId from session
    api_url      TEXT NOT NULL,
    event_source_url TEXT NOT NULL,
    added_at     INTEGER NOT NULL
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
- `createHttpClient(): HttpClient` — `expect/actual` per platform
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
- Navigation uses type-safe `@Serializable` sealed `Screen` routes in commonMain.
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

Navigation entry point: `AccountList` (replaces the old single-account `Login` screen).

---

## Phased Implementation

Build order: data layer first, UI last.

| Phase | Scope | Done when |
|---|---|---|
| **0 — Scaffolding** | Directories, module.yamls, `flake.nix` with `stalwart-mail` + Amper via `fetchurl`, `libs.versions.toml`, `stalwart-dev/config.toml` | `./amper build` succeeds; `stalwart-mail --config stalwart-dev/config.toml` starts |
| **1 — Core models** | `@Serializable` data classes, custom `MethodCall` serializer, repository interfaces, unit tests | Serialization round-trips pass against captured Stalwart JSON |
| **2 — Auth & session** | `createHttpClient` expect/actual, session discovery (`/.well-known/jmap`), Basic auth, `TokenStore` expect/actual (keyed by accountId) | Integration test: Stalwart session parsed; tokens stored and retrieved per account |
| **3 — SQLDelight schema** | Gradle-interop mode for `data`; `account` table + all child tables with `account_id` FK + `ON DELETE CASCADE`; driver expect/actual | Schema compiles; insert + query tests pass; cascade delete removes all account data |
| **4 — Account management** | `AccountRepositoryImpl`: add account (discover → auth → insert row), remove account (delete cascades), `observeAccounts()` Flow | Integration test: add two Stalwart accounts; both rows in DB; remove one cascades all its data |
| **5 — Mailbox sync** | `MailboxRepositoryImpl` scoped by accountId; `Mailbox/get` + `Mailbox/changes`; `observeMailboxes(accountId)` Flow | Integration test: mailboxes for both accounts sync independently; survive restart |
| **6 — Email header sync** | `EmailRepositoryImpl` scoped by accountId; `Email/query` + `Email/get` (headers); pagination; `state_token` per account | Integration test: email lists for both accounts in DB; incremental sync fetches only deltas |
| **7 — Email body sync** | On-demand body fetch per account; stored in `email_body(account_id, email_id)`; not re-fetched if already present | Integration test: body available offline after first open |
| **8 — Push / SSE** | `AccountSyncManager` starts one `JmapEventSourceService` + `SyncOrchestrator` per account; reconnect on drop; stops when account removed | Integration test: new email on account A appears in DB; account B unaffected |
| **9 — Mutations** | Keyword set, move, delete, send — all account-scoped; `Identity/get` per account | Integration test: mutations on account A don't affect account B |
| **10 — UI: Accounts + browse** | Koin wiring, `AccountListScreen`, `AddAccountScreen`, `MailboxListScreen`, `EmailListScreen`, `EmailDetailScreen`, Navigation graph, platform entry points | End-to-end: add two accounts, browse each inbox, read email |
| **11 — UI: Compose + Settings** | `ComposeScreen` (account-scoped), `SettingsScreen` (remove account), remove cascades cleanly | Send email; remove one account; other account unaffected |
| **11 — Polish** | Error screens, retry logic, Android WorkManager background sync, desktop tray, accessibility | Production-ready |

---

## Open Decisions

1. **HTML rendering** — Plain-text only for MVP. Evaluate `compose-webview-multiplatform` for Phase
   11.
2. **OAuth2** — HTTP Basic for MVP (Stalwart supports it); OAuth2 post-MVP.
3. **Thread view** — Flat email list per mailbox for MVP; threaded conversation view post-MVP.
4. **iOS Xcode scaffolding** — Verify `./amper init ios/app` generates a working Xcode project
   before starting iOS work (Phase 0).
5. **SQLDelight + Gradle-interop** — Use Gradle-interop mode for `data` from Phase 3 onward:
   `data/build.gradle.kts` applies the SQLDelight plugin; `data/module.yaml` handles everything
   else.
