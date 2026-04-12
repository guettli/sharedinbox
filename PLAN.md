# SharedInbox Implementation Plan

## Context

SharedInbox is a JMAP email client (RFC 8621) built from scratch using Kotlin Compose Multiplatform. The repo is currently empty (README + AGENTS.md only). The goal is a working MVP email client targeting **Android, Desktop (JVM), and iOS**, tested against a self-hosted **Stalwart Mail** server, built with **JetBrains Amper** and managed via **Nix flake**.

The app is built **bottom-up, offline-first**. The sync engine and SQLDelight database are fully working and integration-tested before any UI is written. The UI reads only from the local DB — it never touches the network directly.

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

Amper is not in nixpkgs. Pin it as a `fetchurl` derivation so the binary is hash-verified and available automatically in `nix develop` — no manual curl/commit step needed:

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

Contributors run `./amper build` (or just `amper build` inside `nix develop`) with no global install.

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

Note: `data/build.gradle.kts` sits alongside this file to apply the SQLDelight Gradle plugin (Gradle-interop mode).

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

1. **No single `@ios` platform qualifier** — must list `@iosArm64`, `@iosSimulatorArm64`, `@iosX64` separately (or define an `aliases:` key in module.yaml).
2. **SQLDelight Gradle plugin is incompatible** with Amper standalone — use **Gradle-interop mode** for the `data` module from the start: place a `build.gradle.kts` alongside `data/module.yaml` to apply the SQLDelight plugin.
3. **Amper 0.10 is still experimental** — pin the wrapper version tightly, breaking changes between minor versions are possible.
4. **`libs.versions.toml` must be at project root** (not `gradle/`).

---

## Nix Flake (`flake.nix`)

Pins: **JDK 21 Temurin**, **Android SDK (API 36, build-tools 35)** via `android-nixpkgs/stable`, base channel `nixpkgs/nixos-25.11`.

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

- `jmap/Session.kt` — `JmapSession`, `JmapAccount`
- `jmap/JmapRequest.kt` — `JmapRequest`, `JmapResponse`, `MethodCall` / `MethodResponse` with custom serializers for the `["name", {...}, "clientId"]` array wire format
- `jmap/mail/Mailbox.kt` — `Mailbox`, `MailboxRights`
- `jmap/mail/Email.kt` — `Email`, `EmailAddress`, `EmailBodyPart`, `EmailBodyValue`
- `jmap/push/StateChange.kt` — SSE push payload

### Repository interfaces (`core`)

```
SessionRepository   — discover(hostname), getSession()
AuthRepository      — authenticate(), isAuthenticated(), logout()
MailboxRepository   — observeMailboxes(): Flow<List<Mailbox>>, syncMailboxes()
EmailRepository     — observeEmails(mailboxId): Flow, syncEmails(), getEmail(),
                      setKeyword(), moveEmail(), sendEmail(), deleteEmail()
TokenStore          — expect/actual: EncryptedSharedPrefs (Android),
                      Keychain (iOS), file-based (JVM)
```

### JMAP API implementation (`data` module)

- `JmapApiClient` — wraps Ktor; single `POST apiUrl` with `JmapRequest` body
- `createHttpClient(): HttpClient` — `expect/actual` per platform
- `JmapEventSourceService` — connects SSE via `client.serverSentEventsSession {}`, dispatches `StateChange` to `SyncOrchestrator`
- `SyncOrchestrator` — tracks JMAP state strings; calls `*/changes` for incremental sync

**Auth:** HTTP Basic via Ktor `basic {}` provider (Stalwart supports this). OAuth2 deferred post-MVP.

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
| Login | `Screen.Login` | Hostname + username + password; session discovery + Basic auth |
| Mailbox List | `Screen.MailboxList` | Unread counts; pull-to-refresh |
| Email List | `Screen.EmailList(mailboxId)` | Subject/from/preview/date; swipe actions |
| Email Detail | `Screen.EmailDetail(emailId)` | Plain-text body (HTML deferred); mark-as-read on open |
| Compose / Reply | `Screen.Compose` | To/CC/Subject/Body; `Email/set create` + blob upload |
| Settings | `Screen.Settings` | Account info; logout |

---

## Phased Implementation

Build order: data layer first, UI last.

| Phase | Scope | Done when |
|---|---|---|
| **0 — Scaffolding** | Directories, module.yamls, `flake.nix` with `stalwart-mail` + Amper via `fetchurl`, `libs.versions.toml`, `stalwart-dev/config.toml` | `./amper build` succeeds; `stalwart-mail --config stalwart-dev/config.toml` starts |
| **1 — Core models** | `@Serializable` data classes, custom `MethodCall` serializer, repository interfaces, unit tests | Serialization round-trips pass against captured Stalwart JSON |
| **2 — Auth & session** | `createHttpClient` expect/actual, session discovery (`/.well-known/jmap`), Basic auth, `TokenStore` expect/actual | Integration test: Stalwart session object fully parsed |
| **3 — SQLDelight schema** | Gradle-interop mode for `data`; schema for `mailbox`, `email_header`, `email_body`, `state_token` tables; migrations; driver expect/actual | Schema compiles; insert + query tests pass on all 3 platforms |
| **4 — Mailbox sync** | `MailboxRepositoryImpl`: `Mailbox/get` + `Mailbox/changes`; writes to DB; `observeMailboxes()` returns DB `Flow` | Integration test: mailboxes persist in DB after sync; survive app restart |
| **5 — Email header sync** | `EmailRepositoryImpl`: `Email/query` + `Email/get` (headers only); pagination; state tracking via `state_token` table | Integration test: email list persists in DB; incremental sync fetches only changes |
| **6 — Email body sync** | On-demand body fetch (`Email/get` with body properties); stored in `email_body` table; `observeEmailBody(id)` Flow | Integration test: body available offline after first fetch |
| **7 — Push / SSE** | `JmapEventSourceService` SSE connection; `StateChange` dispatch to `SyncOrchestrator`; reconnect on drop | Integration test: send email to Stalwart → inbox DB row appears without manual sync |
| **8 — Mutations** | `Email/set` for keywords (read/unread, flagged), move, delete; `Email/set create` + blob upload for send; `Identity/get` | Integration test: mark-as-read, move, delete, send all reflected in DB |
| **9 — UI: Login + browse** | Koin wiring, `LoginScreen`, `MailboxListScreen`, `EmailListScreen`, `EmailDetailScreen`, Navigation graph, platform entry points | End-to-end: login → browse inbox → read email (all from DB) |
| **10 — UI: Compose + Settings** | `ComposeScreen`, `SettingsScreen`, logout | Can send email; logout clears DB and tokens |
| **11 — Polish** | Error screens, retry logic, Android WorkManager background sync, desktop tray, accessibility | Production-ready |

---

## Open Decisions

1. **HTML rendering** — Plain-text only for MVP. Evaluate `compose-webview-multiplatform` for Phase 11.
2. **OAuth2** — HTTP Basic for MVP (Stalwart supports it); OAuth2 post-MVP.
3. **Thread view** — Flat email list per mailbox for MVP; threaded conversation view post-MVP.
4. **iOS Xcode scaffolding** — Verify `./amper init ios/app` generates a working Xcode project before starting iOS work (Phase 0).
5. **SQLDelight + Gradle-interop** — Use Gradle-interop mode for `data` from Phase 3 onward: `data/build.gradle.kts` applies the SQLDelight plugin; `data/module.yaml` handles everything else.
