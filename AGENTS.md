# SharedInbox Flutter — Agent Guide

## Code conventions

- No `if` chains where a pattern/match or data-driven approach works.
- Fail loudly — `throw StateError(...)` beats silent fallbacks.
- New source files go under `lib/core/` (interfaces/models), `lib/data/` (implementations), or `lib/ui/` (screens/widgets).

## Drift (DB)

- Schema in `lib/data/db/database.dart`.
- After any schema change run: `dart run build_runner build --delete-conflicting-outputs`
- Generated `database.g.dart` is committed — do not hand-edit it.

## enough_mail (vendored)

- Located at `packages/enough_mail/` — edit freely.
- IMAP client helpers are in `lib/data/imap/imap_client_factory.dart`.

## Running

```bash
# Code generation (must run after schema changes)
dart run build_runner build --delete-conflicting-outputs

# Desktop
flutter run -d linux

# Tests
flutter test
```

## Adding a screen

1. Create `lib/ui/screens/my_screen.dart`.
2. Add a `GoRoute` in `lib/ui/router.dart`.
3. No separate ViewModel file needed — use `ConsumerWidget` / `ConsumerStatefulWidget` directly with Riverpod providers.
