# SharedInbox — Agent Guide

## General

- Avoid conditions. Try to avoid "if". Try to make things straight forward. When tools are required,
  add them with the matching tool (Nix for example). Fail if tools are not available instead of
  working around that.

## Code conventions

- Use `kotlin.time.Clock` (stdlib), not `kotlinx.datetime.Clock` — the latter does not exist in
  `kotlinx-datetime 0.7.1`.
- New Kotlin source files go under `data/src/de/sharedinbox/data/` (common) or
  `data/src@jvm/de/sharedinbox/data/` (JVM-only).
- Test files go under `data/test@jvm/de/sharedinbox/data/`.

## SQLDelight

- `.sq` schema files live in `data/src/sqldelight/de/sharedinbox/data/db/`.
- Generated Kotlin is committed to `data/src/generated/` — do not hand-edit those files.
- To regenerate after schema changes: `./gradlew --project-dir codegen generateAndCopy`
- `stalwart-dev/test.sh` auto-regenerates when any `.sq` file is newer than the generated DB class.

## Running tests

```bash
# Unit tests (no server needed)
amper test -m core -p jvm

# Integration tests (starts/stops Stalwart automatically)
stalwart-dev/test.sh
```

Both commands must be run inside `nix develop` so `STALWART_PORT`, `STALWART_URL`,
`STALWART_USER_A/B`, and `STALWART_PASS_A/B` are set.

## Stalwart dev server

- Binary: `stalwart` (not `stalwart-mail`)
- Config: `stalwart-dev/config.toml`
- Readiness probe: `GET /.well-known/jmap` (no `-f`; any HTTP response means it is up)
- Two test accounts are pre-configured: admin (STALWART_USER_A / STALWART_PASS_A) and
  alice (STALWART_USER_B / STALWART_PASS_B). Values are exported by the Nix shell hook.
