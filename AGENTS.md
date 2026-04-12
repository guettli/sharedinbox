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

## Architecture

See [PLAN.md](PLAN.md) for the full implementation plan, layer order, DB schema, and screen list.

Key constraints to enforce:

- **UI is read-only from DB** — screens never call the network directly
- **Multi-account from day one** — every DB table has an `account_id` FK; every repository method
  is account-scoped
- **Do not start UI work** until sync layer integration tests pass against local Stalwart

## SQLDelight + Amper

SQLDelight's Gradle plugin is incompatible with Amper standalone. Use **Gradle-interop mode** for
the `data` module: place a `build.gradle.kts` alongside `module.yaml` to apply the SQLDelight
plugin. This is the supported escape hatch — do not skip SQLDelight or defer it.

## Testing

### Unit tests

```bash
./amper test :core
```

### Integration tests (requires Stalwart)

```bash
# Terminal 1
stalwart-mail --config stalwart-dev/config.toml

# Terminal 2
STALWART_URL=http://localhost:8080 STALWART_USER_A=admin STALWART_PASS_A=admin \
./amper test :data
```

All tools are available in `nix develop` — no manual installs needed.
