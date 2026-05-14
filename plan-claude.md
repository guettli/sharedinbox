# SharedInbox — Improvement Plan

30 tasks across 7 perspectives. Priority markers: 🔴 high · 🟡 medium · 🟢 nice-to-have.

---

## Group 1: Performance

### P1 — Done: https://codeberg.org/guettli/sharedinbox/pulls/41

### P1 🔴 Replace LIKE-based search with FTS5 virtual table
The current `observeEmails` and search queries use `LIKE '%query%'` which becomes a full-table scan at scale.
Create an `email_fts` FTS5 virtual table (subject, preview, fromJson) populated via trigger or sync-time insert.
Wire `SearchScreen` to query the FTS table instead.
Files: `lib/data/db/database.dart`, `lib/data/repositories/email_repository_impl.dart`.

### P2 🔴 Lazy-load email bodies on scroll (pagination)
`observeThreads` and `observeEmails` return the full list with no limit. As the mailbox grows this streams thousands of rows into memory.
Add a page-size parameter (e.g. 50) with "load more" support in `EmailListScreen`.
The `EmailBodies` table is already separate — never fetch bodies in the list query.
Files: `lib/data/repositories/email_repository_impl.dart`, `lib/ui/screens/email_list_screen.dart`.

### P3 🟡 Defer HTML parsing off the UI thread using an Isolate
`flutter_html` parsing blocks the raster thread for large HTML bodies, causing jank when opening email detail.
Move the HTML→Widget tree conversion (or at minimum the `html_utils.dart` HTML-to-plain step) into a `compute()` call.
Files: `lib/ui/screens/email_detail_screen.dart`, `lib/core/utils/html_utils.dart`.

### P4 — Done: https://codeberg.org/guettli/sharedinbox/pulls/36

### P5 🟢 Cache the formatted date strings in EmailListScreen
`DateFormat('MMM d').format(...)` is called for every email on every rebuild. Compute and cache these in the model layer or inside the list item widget's `build` method using a static cache map.
Files: `lib/ui/screens/email_list_screen.dart`, `lib/core/utils/format_utils.dart`.

---

## Group 2: Reliability & Resilience

### R1 — Done: https://codeberg.org/guettli/sharedinbox/pulls/20

### R2 — Done: https://codeberg.org/guettli/sharedinbox/pulls/22

### R3 — Done: https://codeberg.org/guettli/sharedinbox/pulls/35

### R4 — Done: https://codeberg.org/guettli/sharedinbox/pulls/23

### R5 — Done: https://codeberg.org/guettli/sharedinbox/pulls/45

### R6 — Done: https://codeberg.org/guettli/sharedinbox/pulls/24

---

## Group 3: Security

### S1 🔴 Optional SQLCipher encryption for the Drift database
Emails cached locally are plaintext. Users on shared or rooted devices are exposed.
Add an opt-in "Encrypt local storage" setting using `drift`'s `encrypted` backend (`sqflite_cipher` / `sqlcipher_flutter_libs`).
Store the database key in `flutter_secure_storage` (already present).
Files: `lib/data/db/database.dart`, `pubspec.yaml`, a new settings toggle.

### S2 — Done: https://codeberg.org/guettli/sharedinbox/pulls/25

### S3 🟡 Enforce certificate pinning for known providers (opt-in)
Auto-discovered accounts for major providers (Gmail, Fastmail, Proton) could be pinned to their known CA hierarchy.
Implement as an opt-in per-account setting; only applies when the account is auto-discovered via `AccountDiscoveryService`.
Files: `lib/core/services/account_discovery_service.dart`, `lib/data/imap/imap_client_factory.dart`.

### S4 🟢 Audit and restrict external link handling in HTML emails
`flutter_html` passes `<a href>` clicks to `url_launcher` without a prompt.
Before launching, show a confirmation dialog with the destination URL so phishing links are visible.
Files: `lib/ui/screens/email_detail_screen.dart`.

---

## Group 4: User Experience

### U1 — Done: https://codeberg.org/guettli/sharedinbox/pulls/26

### U2 — Done: https://codeberg.org/guettli/sharedinbox/pulls/27

### U3 🟡 Add "Recent searches" history to SearchScreen
The search bar clears on navigation. Store the last 10 search terms in a local DB table and show them as chips below the search field when the field is focused but empty.
Files: `lib/ui/screens/search_screen.dart`, `lib/data/db/database.dart`.

### U4 — Done: https://codeberg.org/guettli/sharedinbox/pulls/28

### U5 — Already implemented (Dismissible archive/delete swipes with undo, found in email_list_screen.dart)

### U6 — Done: https://codeberg.org/guettli/sharedinbox/pulls/29

### U7 🟢 Onboarding walkthrough for first-time users
The app opens directly to an empty account list with only a `+` button. First-time users have no guidance.
Add a one-time welcome card or bottom-sheet with the three-step flow: Add account → wait for sync → open inbox.
Files: `lib/ui/screens/account_list_screen.dart`.

### U8 🟢 "Mark all as read" action in mailbox
Power users managing high-volume mailboxes need bulk read marking. Add a "Mark all as read" option in the mailbox overflow menu.
Files: `lib/ui/screens/email_list_screen.dart`, `lib/core/repositories/email_repository.dart`, `lib/data/repositories/email_repository_impl.dart`.

---

## Group 5: Testing

### T1 — Done: https://codeberg.org/guettli/sharedinbox/pulls/30

### T2 — Done: https://codeberg.org/guettli/sharedinbox/pulls/31

### T3 — Done: https://codeberg.org/guettli/sharedinbox/pulls/43

### T3 🟡 Contract tests for all Repository interfaces
The interfaces in `core/repositories/` have no shared contract test suite. Concrete impls can silently diverge.
Add a shared `EmailRepositoryContract` abstract test class; run it against both `EmailRepositoryImpl` and any future mock/fake. Mirror this for `MailboxRepository` and `AccountRepository`.
Files: `test/unit/` (new contract test files).

### T4 — Done: https://codeberg.org/guettli/sharedinbox/pulls/32

### T5 🟢 Snapshot / golden tests for key email list states
The email list has multiple states: loading, empty, normal, selection mode, search active, error banner.
Add golden tests using `matchesGoldenFile` for each state so visual regressions surface in CI.
Files: `test/widget/email_list_screen_test.dart`.

---

## Group 6: Architecture & Code Quality

### A1 — Done: https://codeberg.org/guettli/sharedinbox/pulls/39

### A2 — Done: https://codeberg.org/guettli/sharedinbox/pulls/33

### A3 — Done: https://codeberg.org/guettli/sharedinbox/pulls/46

### A4 🟡 Replace raw JSON strings in DB with structured encoding
`fromJson`, `toAddresses`, `ccJson`, `references` are stored as raw JSON strings parsed on every model conversion.
Create typed value classes with `fromJson`/`toJson` in `core/models/email.dart` and add a `TypeConverter` in the Drift schema so the DB layer owns the serialisation.
Files: `lib/data/db/database.dart`, `lib/core/models/email.dart`, `lib/data/repositories/email_repository_impl.dart`.

### A5 🟢 Enforce layer boundaries via lint custom rules or barrel imports
The `ui/` layer directly imports `data/` concrete classes in several screens (e.g. `drift` types leak through).
Add a custom `analysis_options.yaml` rule or a CI lint step that flags any `ui/` import of `data/` (only `core/` interfaces are allowed from UI).
Files: `analysis_options.yaml`, CI config.

---

## Group 7: Developer Experience

### D1 🔴 CI matrix for macOS and Windows builds
The CI currently tests Linux and Android. The macOS and Windows targets are "scaffolded" and may have accumulated silent breakage.
Add `flutter build macos --debug` and `flutter build windows --debug` jobs to the CI workflow with the same failure threshold as Linux.
Files: `.github/workflows/ci.yml` (or Codeberg equivalent).

### D2 — Done: https://codeberg.org/guettli/sharedinbox/pulls/34

### D3 🟢 Document the sync protocol in a SYNC.md architecture doc
`DB-SYNC.md` exists but focuses on the DB schema. The IMAP IDLE loop, exponential backoff, pending-change queue, and undo cancel logic are spread across four files with no single reference.
Write `SYNC.md` that describes the full lifecycle of an email action from UI tap to server confirmation.
Files: `SYNC.md` (new).
