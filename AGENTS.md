# SharedInbox — Agent Guide

## General

- Avoid conditions. Try to avoid "if". Try to make things straight forward. When tools are required,
  add them with the matching tool (Nix for example). Fail if tools are not available instead of
  working around that.

## Tools

- Use nix flake to install dependencies
- Use JetBrains [Amper](https://github.com/JetBrains/amper)
- Use [Kotlin Multiplatform](https://kotlinlang.org/multiplatform/)
- Use [Compose Multiplatform](https://kotlinlang.org/compose-multiplatform/)
- Use [SQLDelight](https://cashapp.github.io/sqldelight/) for local persistence

## Architecture principles

- **Offline-first**: build bottom-up. Complete and test each layer before starting the next.
- **Layer order**: core models → auth/session → local DB schema → sync engine → UI
- **UI is read-only**: screens read from the SQLDelight database only — never from the network
  directly
- **Sync is independent**: the sync engine runs in the background and writes to the DB; the UI
  observes DB queries as `Flow`
- **Multi-account from day one**: every DB table has an `accountId` foreign key; the sync engine
  runs one `SyncOrchestrator` and one SSE connection per account; repositories are always
  account-scoped
- Do not start UI work until the sync layer has integration tests passing against a local Stalwart
  Mail instance

## SQLDelight + Amper

SQLDelight's Gradle plugin is incompatible with Amper standalone. Use **Gradle-interop mode** for
the `data` module: place a `build.gradle.kts` alongside `module.yaml` to apply the SQLDelight
plugin. This is the supported escape hatch — do not skip SQLDelight or defer it.
