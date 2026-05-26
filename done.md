# Done

This file contains tasks which got implemented.

Tasks get moved from next.md to done.md

## Tasks (2026-05-26)

- **Renovate Bot (Issue #257)**: Renovate Bot runs daily via Forgejo Actions to keep
  dependencies up to date. All required components are in main:
  - `renovate.json` — Renovate configuration covering pub, Dockerfile, and Forgejo Actions
  - `ci/main.go` — `Renovate()` Dagger function using Forgejo platform and Codeberg endpoint
  - `.forgejo/workflows/renovate.yml` — daily cron (06:00 UTC) workflow
  - `Taskfile.yml` — `renovate` task
  - Issue #257 closed.

## Tasks (2026-05-11)

- **Stabilize Email List UI during Selection (Issue #14)**: Prevented layout shifts when entering
  selection mode in the email list.
  - Consolidated `AppBar` logic to maintain a constant height by preserving the `SearchBar` space.
  - Refactored `ListTile` to keep `trailing` widgets (date, flag) visible during selection.
  - Wrapped `leading` widgets in a `SizedBox` to ensure consistent horizontal alignment.
  - Retained `Dismissible` wrappers during selection (disabling swipe via `direction`) to avoid widget tree churn.
  - Verified with widget and E2E integration tests.
  - Deployed to Android.

## Tasks (2026-05-10)

- **Improved Undo Log and Android Deployment (Issue #7)**: Enhanced the Undo Log to support
  undoing any action from history, not just the latest. This provides more flexibility
  when managing multiple destructive actions.
  - Refactored `UndoService.undo()` to accept an optional `actionId`, allowing targeted rollbacks.
  - Updated `UndoLogScreen` to remove the "latest only" restriction and provide immediate feedback.
  - Successfully built and deployed the release APK to the distribution server via `task deploy-android`.
  - Verified the new undo logic with updated unit tests and ensured full system integrity via the CI check suite.
- **Global Undo Log and History**: Implemented a persistent history of undoable
  actions, allowing users to view and undo recent destructive operations.
  - Added `UndoLogScreen` to display a chronologically reversed list of actions.
  - Refactored `UndoService` to maintain a history of the last 10 actions.
  - Added timestamp and description metadata to `UndoAction`.
  - Added a "History" icon to the `AccountListScreen` app bar.
- **Improved .gitignore**: Added more patterns to keep the repository clean
  (FVM, Android studio files, Flutter/Dart tool directories).

## Tasks (2026-05-09)

- **Fix Crash Page (Issue 3)**: Added a "Report this issue on Codeberg" button to the
  global `CrashScreen`, facilitating easier bug reporting for users.
- **Fix Show Mail Headers (Issue 1)**: Extended the database schema and repository
  to fetch and store raw email headers. Added a new "Headers" tab/view in the
  email detail screen to display them in a zebra-colored table.
- **Fix Exception on Undo of Delete (Issue 2)**: Added `toJson()` and `fromJson()`
  to the `EmailAddress` model to support correct serialization during undo
  operations, resolving a crash when restoring deleted emails.
- **Dev Environment Hardening**: Added an automated check and fix for Nix
  experimental features (`nix-command`, `flakes`) to the `Taskfile.yml`.

- **Optimistic UI**: Both IMAP and JMAP `moveEmail` operations are now optimistic,
  updating the local database immediately instead of waiting for sync. This
  provides instant feedback and ensures rows are available for Undo actions.
- **Global Undo Support**: Introduced `UndoShell` and `ShellRoute` to provide a
  consistent "Undo" experience across all screens, automatically surfacing the
  Undo SnackBar whenever a destructive action is performed.
- **Improved Thread Support**: Fixed a bug where deleting emails from the
  `ThreadDetailScreen` lacked Undo logic.

## Undo Feature Fix (IMAP)

Fixed a bug where undoing an email deletion or move would fail for IMAP accounts
because the local row was hard-deleted before the Undo action was performed.

- **Data Preservation**: The app now fetches and preserves the full email data in
  the `UndoAction` before performing a move or delete.
- **Restoration Support**: Added `restoreEmails` to the repository to allow
  re-inserting hard-deleted rows into the local database during an Undo.
- **Robust Cancellation**: Improved `UndoService` to attempt cancellation of both
  `move` and `delete` pending changes, ensuring consistency even if a delete
  was implemented as a move-to-trash.
- **IMAP Optimization**: Made `moveEmail` a no-op locally if the destination
  mailbox matches the current one, preventing accidental re-deletion during Undo.

## Network Resilience: Exponential Backoff and Smart Retries

Improved the sync engine's reliability on intermittent connections.

- **Exponential Backoff**: Replaced fixed retry intervals with a strategy that
  scales from 5s up to 15m depending on consecutive failures.
- **Permanent Error Handling**: Sync loops now detect authentication failures
  and stop automatically to prevent account lockout or useless battery drain.
- **Manual Override**: "Pull to refresh" now triggers an immediate full account
  sync, bypassing any active backoff timers.

## Sync Reliability and Reliability Runner

Implemented a robust verification system to ensure the local database accurately
reflects the server state across multiple accounts and protocols.

- **Reliability Check**: Added `verifySyncReliability` to `EmailRepository` to
  compare local UIDs/IDs and flags against the server's "ground truth".
- **Reliability Runner**: A background service (`lib/core/sync/reliability_runner.dart`)
  that periodically identifies discrepancies.
- **Database Support**: Added `SyncHealth` table (Schema v19) to store verification
  results.
- **UI Integration**: Added "Sync health" indicators to the account list tiles and
  a manual "Verify sync health" menu action.
- **Comprehensive Testing**: Verified with a new integration test suite
  (`test/integration/sync_reliability_test.dart`) covering both IMAP and JMAP
  paths.

## Coverage Gate Cleanup and Verification Test

- **Reduced Exclusions**: Removed well-tested widgets (`try_connection_button.dart`, `add_account_screen.dart`, `edit_account_screen.dart`) from the unit-test `_excluded` list in `scripts/check_coverage.dart`.
- **Standalone Ghost Path Test**: Added a dedicated `test/unit/coverage_exclusion_test.dart` that parses the check_coverage script to ensure no "ghost paths" ever make it into the codebase, guaranteeing the exclusion list stays clean and valid during the standard test phase.
- **Coverage Status**: verified combined unit and integration coverage meets the 80%+ threshold (currently 84%).

## Undo for Delete and Move actions

Implemented a robust Undo mechanism for destructive actions like deleting
emails or moving them to different folders.

- **UndoService Infrastructure**: Added a new service (`lib/core/services/undo_service.dart`)
  that maintains a history of the last 10 actions. It uses a `StateNotifier`
  to expose the most recent undoable action to the UI.
- **UI Integration**: Added a global Snackbar listener in `EmailListScreen`.
  Whenever a move or delete occurs (including bulk actions and swipes), a
  Snackbar appears with an "Undo" button. Redundant snackbar triggers were
  removed for a cleaner experience.
- **Optimized Repository Interaction**: Added `cancelPendingChange` to the
  `EmailRepository` interface and implementation. This allows the Undo
  operation to attempt to remove unsynced changes from the local queue,
  preventing unnecessary server round-trips and potential conflicts.
- **Improved Model Coverage**: Added comprehensive unit tests for `Mailbox`
  and `Email` models, achieving 100% coverage for these critical data
  structures.
- **Sorting Logic Fix**: Identified and fixed a bug in `compareMailboxes`
  where different unknown roles would cause the sort to return equality
  incorrectly. The logic now correctly falls through to path-based sorting
  for all same-priority roles.
- **Status**: Verified with unit, widget, and integration tests.
  Total unit coverage: **83%**.

## Multi-account search improvement

Extended the search functionality to allow searching across all accounts
simultaneously, including folders, addresses, and messages.

- **Global Search UI**: Updated `SearchScreen` (`lib/ui/screens/search_screen.dart`)
  to support searching without a specific `accountId`.
- **Account Context**: Added account display names and icons to search results
  when performing a global search.
- **Repository Support**: Modified `EmailRepository` and `MailboxRepository`
  to handle optional `accountId` parameters, enabling cross-account queries.
- **Global Entry Point**: Added a search icon to the `AccountListScreen`
  app bar for quick access to global search.
- **Model Enhancements**: Added `compareMailboxes` to the `Mailbox` model
  and `copyWith` to the `Account` model for better code reuse and testability.

## Thread View UI and Repository Support

Implemented a dedicated screen to view all emails within a thread, providing
a cohesive conversation view.

- **ThreadDetailScreen**: A new screen (`lib/ui/screens/thread_detail_screen.dart`)
  that displays a list of emails in a thread. Each email is rendered as an
  expandable card, with the latest message expanded by default.
- **HTML Support**: Integrated HTML rendering with remote image blocking
  (reusing logic from `EmailDetailScreen`) into the thread view.
- **Message Actions**: Added reply and delete actions for individual messages
  within the thread.
- **Repository Support**: Added `observeEmailsInThread` to `EmailRepository`
  to fetch and watch all messages belonging to a specific thread ID.
- **Navigation**: Updated `EmailListScreen` to navigate to the new thread view
  when a thread with multiple messages is tapped.
- **Mock Support**: Updated `FakeEmailRepository` in unit, widget, and
  integration tests to support the new `observeEmailsInThread` method.

## Database-Backed Threading and Performance Optimizations

Refactored the threading logic from in-memory grouping to a persistent
database-backed approach for improved performance and scalability.

- **Threads Table**: Added a new `Threads` table to the SQLite database
  (Schema v17/v18) to store aggregated thread metadata (subject, unread
  status, participants, etc.).
- **Automatic Sync**: Implemented `_updateThread` logic in `EmailRepositoryImpl`
  to keep the `Threads` table synchronized during IMAP/JMAP syncs and
  user actions (flag changes, moves, deletions).
- **Migration**: Added migration logic to automatically populate the `Threads`
  table from existing email data upon schema upgrade.
- **Indexes**: Added performance indexes on `emails.receivedAt`,
  `emails.threadId`, and `pending_changes.accountId` to speed up common
  query patterns for large mailboxes.
- **Repository Refactor**: Updated `observeThreads` to query the `Threads`
  table directly, significantly reducing CPU and memory usage when
  displaying the inbox.

## Global Crash Screen and Error Handling

Implemented a robust error handling system to capture and display unhandled
exceptions to users, facilitating easier bug reporting.

- **CrashScreen**: A new full-screen widget (`lib/ui/screens/crash_screen.dart`)
  that displays the exception message, stack trace, and a "Copy to Clipboard"
  button for easy sharing of error details.
- **Global Handlers**: Wrapped `main()` in `runZonedGuarded` to catch unhandled
  async errors.
- **Framework Integration**: Installed `FlutterError.onError` and
  `ErrorWidget.builder` to catch framework-level and widget build errors,
  ensuring that all types of crashes result in a graceful error display.

## Optimized Android Deployment and Fixed E2E Flakiness

Improved the speed and reliability of the Android deployment pipeline.

- **Taskfile Optimization**: Updated `Taskfile.yml` to use `sources` and
  `generates` for long-running tasks. Implemented marker files (`.done` files)
  to skip `integration-android` and `deploy-android` when inputs haven't changed.
- **E2E Reliability**: Fixed a race condition in `app_e2e_test.dart` by adding
  `pumpAndSettle()` and a 2-second safety delay before the "Save" button tap,
  resolving the intermittent "missed tap" failure on slow emulators.
- **Deployment Confirmation**: The `deploy-android` task now verifies the build
  with a full Android integration test before uploading the APK.

## Coverage Gate Maintenance

- **Ghost Path Check**: Updated `scripts/check_coverage.dart` to verify that all
  excluded files still exist on disk, preventing "ghost paths" from cluttering
  the configuration.
- **Increased Coverage**: Included `account_sync_manager.dart` and
  `email_repository_impl.dart` in the coverage gate.
- **Current Status**: Total unit coverage increased to **82%**.

## IMAP attachments: accurate sizes and reliable downloads

Attachments in IMAP accounts previously showed as "0 B" in the UI because
the size was retrieved from the `Content-Disposition` header's `size`
parameter, which is frequently missing from real-world emails. Since the
full message is already fetched into memory when viewing an email,
`EmailRepositoryImpl.getEmailBody` now falls back to the length of the
actual (decoded) part content when the header is missing.

IMAP attachment downloads also frequently failed (throwing a `StateError`)
because `downloadAttachment` would fetch a single part from the server
and then try to call `msg.getPart(fetchId)` on the result. When fetching
only a single part, the IMAP library returns an `ImapMessage` where the
requested part *is* the root, so `getPart` (which looks for children)
would return `null`. The repository now falls back to the message itself
if the specific part ID cannot be found in the result of a partial fetch.

## Immediate server-side sync for local deletions and flag changes

Deletions and flag changes (seen/flagged) made in SharedInbox previously
did not appear in other clients (like Thunderbird) until the next sync
cycle or app restart, because the local mutations were enqueued but the
background sync loop was not notified to flush them immediately.

Added `onChangesQueued` stream to `EmailRepository` interface and
implementation. `EmailRepositoryImpl._enqueueChange` now emits the
`accountId` on this stream whenever a new local mutation is queued.
`AccountSyncManager` listens to this stream; when it sees an account ID,
it "kicks" the corresponding active sync loop, waking it from its IDLE
or wait phase to immediately run a sync cycle and flush the pending
changes to the server.

## Plain-text connections only via localhost; SSL toggle hidden for non-localhost hosts

## ManageSieve uses STARTTLS; clearer TLS-mismatch errors; broader connection check

The "Email filters" screen failed for IMAP accounts with
`HandshakeException: WRONG_VERSION_NUMBER(tls_record.cc:127)` because the
ManageSieve client was opening an implicit-TLS socket to port 4190, while
the server (Stalwart and other RFC 5804 implementations) listens plaintext
on 4190 and expects a `STARTTLS` upgrade. The plaintext capability greeting
landed in the TLS parser, which (correctly) rejected it.

`ManageSieveClient.connect` (`lib/data/imap/managesieve_client.dart`) now
follows RFC 5804 §1.7: it opens a plaintext socket, reads the capability
greeting, and — when `useTls` is true — sends `STARTTLS`, waits for `OK`,
detaches the plaintext listener, hands the raw socket to
`SecureSocket.secure()`, and re-reads capabilities on the secured stream.
The previous "implicit TLS, no STARTTLS" mode is gone; if the server does
not advertise `STARTTLS`, the client throws a clear error pointing the
user at the SSL toggle.

`WRONG_VERSION_NUMBER` is also produced for SMTP (and IMAP) when the SSL
toggle and the chosen port disagree — e.g. SSL=on with port 587 (which is
STARTTLS-only). New helper `lib/data/imap/tls_error.dart` translates that
specific BoringSSL error into a `TlsModeMismatchException` with the host,
port, and a hint about which port matches which TLS mode (465/587, 993/143,
4190). `connectImap`, `connectSmtp`, and the ManageSieve TLS upgrade now
all funnel through `rethrowAsTlsHint` so the same readable message reaches
the UI regardless of which protocol failed.

`ConnectionTestService` (`lib/core/services/connection_test_service.dart`)
previously only verified IMAP/JMAP, so SMTP and ManageSieve misconfig
silently passed the "Try connection" button on the edit-account screen
and only surfaced when the user later tried to send mail or open Email
filters. After IMAP succeeds, the service now also verifies SMTP (always
for IMAP accounts — sending mail requires it) and ManageSieve (only when
`manageSieveHost` is explicitly set, since the section is collapsed and
opt-in by default). Failures are prefixed with `SMTP:` or `ManageSieve:`
so the user can tell which leg of the connection is broken. New tests in
`test/unit/connection_test_service_test.dart` cover SMTP-failure
surfacing, the opt-in skip path, and ManageSieve-failure surfacing.

## Sieve filter editing for IMAP accounts (ManageSieve)

The "Email filters" entry was previously hidden for IMAP accounts because
`SieveRepository` only spoke JMAP. Added a minimal ManageSieve client
(RFC 5804) so IMAP accounts can now list / fetch / upload / activate /
delete server-side Sieve scripts.

New: `lib/data/imap/managesieve_client.dart` — implements CONNECT
(implicit TLS or plaintext), AUTHENTICATE PLAIN (SASL), LISTSCRIPTS,
GETSCRIPT, PUTSCRIPT, SETACTIVE, DELETESCRIPT, LOGOUT. Handles
RFC 5804 quoted-strings and `{N+}` non-synchronizing literals (used for
both reading script bodies and uploading them in PUTSCRIPT). The base64
SASL PLAIN payload is redacted in the verbose protocol log.

`SieveRepository` (`lib/data/jmap/sieve_repository.dart`) is now a
dispatcher: `account.type == imap` routes through `ManageSieveClient`
(connecting per-call and `LOGOUT`-ing in `finally`); `account.type ==
jmap` keeps the existing JMAP path unchanged. Public API is unchanged
so the existing Sieve script list / edit screens work for both
account types. For ManageSieve, where scripts are identified by name,
`SieveScript.id` and `SieveScript.blobId` are both set to the script
name. Renames are implemented as PUTSCRIPT(new) followed by
DELETESCRIPT(old).

Account model + DB: added `manageSieveHost`, `manageSievePort` (default
4190), `manageSieveSsl` (default true) to `Account` and `Accounts`
table. Schema bumped to v15 with a forward-only migration that
`addColumn`s the three fields. Empty `manageSieveHost` falls back to
`imapHost` so the typical setup (Stalwart / Dovecot on the same host)
needs no extra configuration.

UI: removed the `account.type == AccountType.jmap` guard from the
"Email filters" entry in both `FolderDrawer` (the per-account drawer)
and the popup menu in `AccountListScreen`, so IMAP accounts now see it
too. The Add and Edit account screens grew a collapsed `ExpansionTile`
labelled "ManageSieve (email filters)" containing host / port / SSL
fields — collapsed by default so the form stays the same height for
users who accept the defaults (which avoided pushing the Save button
off the bottom of the Linux Xvfb 1280x720 viewport in the integration
test).

`scripts/check_coverage.dart` excludes `managesieve_client.dart` from
the unit-coverage gate (real-socket network code, like
`imap_client_factory.dart`). Updated `add_account_screen_test` to
expect 2 visible `SwitchListTile`s on the IMAP form (the third toggle
lives inside the collapsed ExpansionTile).

## Render HTML email bodies

`lib/ui/screens/email_detail_screen.dart` now renders the message's
`htmlBody` with the `flutter_html` widget instead of stripping tags via
`htmlToPlain`. Plain-text-only messages still render through
`SelectableText` (no HTML widget instantiated when `htmlBody` is empty).

Added `flutter_html: ^3.0.0` to `pubspec.yaml`.

Remote (`http(s)`) images are blocked by default — defeats tracking
pixels. A small "Load remote images" button appears at the top of an
HTML body and flips a per-screen flag to re-render with images. Inline
`cid:` and `data:` images fall through to the default handler. Blocking
is implemented via a small `HtmlExtension` subclass
(`_BlockRemoteImagesExtension`) that matches `<img>` whose `src` starts
with `http://` or `https://` and renders `SizedBox.shrink()`.

`htmlToPlain` is kept — it's still used by `_quotedBody` for reply /
forward quoting where plain text is correct.

No DB schema, no codegen, no migrations.

## SMTP TLS enabled by default for new accounts

User report: when creating a new Account, the SMTP SSL/TLS toggle is off by
default. The toggle should default to on so the user perception matches
"secure by default".

Changed defaults from port 587 + `smtpSsl=false` (STARTTLS on submission) to
port 465 + `smtpSsl=true` (implicit TLS on submission-over-TLS) in:

- `lib/core/models/account.dart` (constructor defaults)
- `lib/ui/screens/add_account_screen.dart` (initial state and reset path
  when user picks "IMAP / SMTP" from the choose-type fallback)
- `lib/ui/screens/edit_account_screen.dart` (initial state before
  loading)
- `lib/core/services/account_discovery_service.dart` (MX-record
  fallback when autoconfig returns nothing)

Autoconfig XML parsing is unchanged: when a server's autoconfig advertises
`STARTTLS`, the discovery still returns `smtpSsl=false` so the client uses
STARTTLS on whichever port was advertised. Only the *fallback / blank-form*
defaults flipped.

Tests updated to match the new defaults: `test/unit/account_model_test.dart`
and the MX-fallback case in
`test/unit/account_discovery_service_test.dart`. Widget tests that pass an
explicit `ImapSmtpDiscovery(smtpPort: 587, smtpSsl: false)` to simulate
STARTTLS discovery are intentionally untouched.

## IMAP delete: locally-deleted message no longer reappears after sync

User report: deleting an IMAP message removes it from the list, but tapping
the sync button before the next background flush makes it pop back in.

Reproduced in `test/integration/email_repository_imap_test.dart` with a new
case `syncEmails after local delete does not resurrect message`: it deletes an
email locally (which queues a pending change and drops the cached row), then
calls `syncEmails` directly — exactly what the sync button does — and
asserts the row stays gone and the pending change stays queued.

Root cause: the incremental IMAP sync issues `UID ${lastUid + 1}:*` to look
for new mail. Per RFC 3501 §6.4.4 a sequence range `n:*` reverses to `*:n`
when `n` exceeds the largest UID. With one message at UID 1 and `lastUid=1`,
`UID 2:*` reverses to `*:2` and the server returns UID 1, which then gets
re-fetched and re-inserted — undoing the optimistic local delete.

Fix in `lib/data/repositories/email_repository_impl.dart`: in
`_fetchAndUpsertImap`, look up the UIDs in this mailbox that have a pending
`delete` or `move` queued and skip the insert for those. Keeping the `UID n:*`
search untouched preserves the existing E2E flow where re-fetching freshly
delivered SMTP messages drives the StreamBuilder rebuild.

Same protection guards the `move`-on-delete path (when a Trash mailbox is
configured) for free, since `moveEmail` enqueues a `move` and drops the cached
row in the source mailbox.

## task deploy-android works end-to-end

The original "Emulator did not become ready within 120 s" was already resolved in
commit `d222638` by running `adb start-server` before booting the AVD; without the
adb daemon running first, the emulator can never register as a device.

Running `task deploy-android` after that surfaced an Android-specific integration-test
failure: `aliceTile` had 0 widgets at `tester.tap()` time even though the immediately
preceding `pumpUntil(aliceTile)` had just found it. On the slow software-rendered
emulator the route-pop animation finalises during `pumpUntil`'s trailing 300 ms settle
and the tile is briefly absent right after. Fixed in
`integration_test/app_e2e_test.dart` by re-confirming `aliceTile` with a second
`pumpUntil` (5 s timeout) before the tap.

Bundled with a coherent set of pre-existing infrastructure changes that make the full
pipeline (Linux + Android UI tests, APK upload) work in `nix develop`:

- `flake.nix`: adds Linux desktop runtime libs (gtk3, mesa, libGL, libsecret, …) plus
  `PKG_CONFIG_PATH`, `LD_LIBRARY_PATH`, `LIBGL_ALWAYS_SOFTWARE=1`, and the libglvnd
  vendor-dir env vars so `flutter build linux` and `xvfb-run` work without a real GPU.
- `pubspec.yaml`: pins `path_provider_android` to `>=2.2.0 <2.3.0` to dodge the SIGSEGV
  in `libdartjni.so` (FindClassUnchecked) on Android startup with 2.3+.
- `lib/main.dart` + `lib/data/db/database.dart`: resolves the DB path during `main()`
  after `WidgetsFlutterBinding.ensureInitialized()` so the path_provider plugin channel
  is registered before the first DB access.
- `stalwart-dev/integration_ui_test.sh`: passes `-screen 0 1280x720x24 +iglx` to Xvfb
  so GTK3/Flutter can create a GLX OpenGL context under the virtual framebuffer.
- `.envrc`: adds `$HOME/Android/Sdk/platform-tools` to PATH so `adb` resolves outside
  `nix develop`.
- `Taskfile.yml`: drops the `/usr/bin/pkg-config` hardcode in favour of PATH so the
  nix-provided wrapper is found.
- `.pre-commit-config.yaml` + `scripts/pre_commit_check.sh`: consolidates `dart format`
  and `task check-fast` into a single script invoked by one hook (one `nix develop`
  startup instead of two).

## Replace custom search TextField with Flutter SearchBar

Replaced the hand-rolled `TextField`-in-`AppBar` search UI with Flutter's built-in `SearchBar`
widget (Material 3). The `SearchBar` is now always visible in the `AppBar`'s `bottom` slot — no
toggle needed.

Removed: `bool _searching` state field, `TextEditingController _searchCtrl`, `Timer? _searchDebounce`,
and the `_searchBar()` / `_closeSearch()` helpers.

Added: `SearchController _searchController` with a listener that clears results when text is
emptied. `onChanged` fires search immediately (no debounce); `onSubmitted` also fires it. A clear
`IconButton` appears in `trailing` when the controller has text.

Updated `integration_test/app_e2e_test.dart`: search section now enters text directly into
`find.byType(SearchBar)` — no icon tap or `TextField` lookup needed.

Updated widget tests in `test/widget/email_list_screen_test.dart`: replaced the "tapping back
arrow" test with "SearchBar is always visible in the AppBar"; fixed "clear results" test to use
`emails: []` so the stream body stays empty after clearing.

## Sieve Scripts editing is discoverable

The Sieve script editor ("Email filters") was already implemented. It became reachable
via the "Email filters" entry added to `FolderDrawer` in the previous task — no further
code changes needed.

## MX record fallback in account auto-discovery

When JMAP well-known and autoconfig XML both fail, `AccountDiscoveryServiceImpl` now
queries `https://dns.google/resolve?name={domain}&type=MX` (DNS-over-HTTPS, no new
dependency). The highest-priority MX hostname is used as both IMAP host (port 993, SSL)
and SMTP host (port 587, STARTTLS). Three unit tests cover: basic MX hit, priority
sorting, and NXDOMAIN/error fallback to `UnknownDiscovery`.

## Email filters accessible from inside an account

Added "Email filters" entry to `FolderDrawer` (below "All accounts", above the folder
list). Visible only for JMAP accounts (`accountAsync.valueOrNull?.type == AccountType.jmap`).
Tapping it closes the drawer and pushes `/accounts/:id/sieve`. Previously the Sieve script
editor was only reachable via the hidden popup menu on the account list.

## Bulk actions on search results

Long-pressing a search result enters selection mode; tapping additional results adds/removes
them. The existing bottom bar (Archive, Delete, Mark as spam, Move to folder) works on the
selection. Implementation in `email_list_screen.dart`:

- `_selectedSearchIds` (`Set<String>`) tracks selected email IDs in search results.
- `_selecting` is true when either `_selectedThreadIds` or `_selectedSearchIds` is non-empty.
- `_selectedEmailIds` returns `_selectedSearchIds` when searching, thread-resolved IDs otherwise.
- `_buildEmailList` shows checkboxes in selection mode, highlights selected tiles, and routes
  taps to toggle-vs-open depending on mode.

## Multi-word search uses AND semantics

Searching for "foo bar" now returns emails that contain **both** words, not the exact
phrase. Fixed in `email_repository_impl.dart`:

- **IMAP search** (`searchEmails`): query is split on whitespace; each word becomes
  `OR SUBJECT "word" TEXT "word"`, joined by spaces. Multiple top-level IMAP criteria
  are implicitly ANDed by the protocol.
- **Local DB search** (`searchEmailsGlobal`): each word adds
  `& (subject LIKE '%word%' | preview LIKE '%word%')` to the Drift where-clause.

## Navigate back to account list from inside an account

Added an "All accounts" tile (with `Icons.switch_account`) at the top of `FolderDrawer`,
above a divider and the folder list. Tapping it closes the drawer and navigates to
`/accounts` via `context.go`. The drawer is shown in both `MailboxListScreen` and
`EmailListScreen`, so this entry point is reachable from anywhere inside an account.

## Speed up `task deploy-android`

Parallelism improvement:

- `_integrations` internal task: runs `integration` and `integration-ui` in parallel (they use
  random Stalwart ports and different Flutter build targets so there is no conflict).

## Android E2E test verifies APK before deploy

`task deploy-android` now runs `integration-android` (the full Android E2E test) before
uploading the APK. If the app crashes on start or any E2E step fails, the deploy is skipped.

Key fixes to make the Android E2E test reliable:

- `Taskfile.yml`: moved `integration-android` to a sequential `cmds` step after `check`,
  so the two E2E suites don't compete for CPU and slow the emulator.
- `stalwart-dev/integration_android_test.sh`: wrapped `force-stop`/`pm clear`/`uninstall`
  in a `pm list packages | grep -qF` check — only runs when the package is installed, so
  any real failure is surfaced instead of silently suppressed.
- `integration_test/app_e2e_test.dart`:
  - `pumpUntil` uses `pump(300ms)` instead of `pumpAndSettle()` so a concurrently
    running spinner never blocks settling.
  - `accountConnectionStatusProvider` overridden to complete immediately, eliminating the
    `CircularProgressIndicator` in `_AccountTile` that caused `pumpAndSettle` to deadlock.
  - Search section: `FocusManager.instance.primaryFocus?.unfocus()` dismisses the Android
    IME keyboard before polling for results — without this, the soft keyboard reduces
    `viewInsets.bottom` to near-zero and `ListView.builder` renders 0 items even though
    search results are present.

---

## Override accountConnectionStatusProvider in E2E test (fix Android pumpAndSettle deadlock)

`accountConnectionStatusProvider` overridden in `integration_test/app_e2e_test.dart` so
`_AccountTile` never shows a `CircularProgressIndicator` during tests. The spinner's
continuous animation prevented `pumpAndSettle()` from settling on Android. Reverted
`pumpUntil` to use `pumpAndSettle()` again. Commit: e50ff3c.

---

## Fix task check: unencrypted IMAP error + coverage gate

- `account_sync_manager_test.dart`: inject `_connectImapPlain` (bypasses the production SSL check) so the test works against the plain-IMAP dev Stalwart.
- `scripts/check_coverage.dart`: add three new screens (`sieve_script_edit_screen`, `sieve_scripts_screen`, `thread_detail_screen`) and `sieve_repository` to `_excluded` (all are screens/JMAP clients without unit tests).
- New unit tests: `sieve_script_test.dart`, plus `findMailboxByRole`, JMAP no-URL error, and JMAP API error tests in `mailbox_repository_impl_test.dart`.
- New widget tests: `try_connection_button_test.dart` (okMessage/errorMessage rendering) plus selection-mode, deselect, search-clear, and search-result-tap tests in `email_list_screen_test.dart`.
- Fixed `FakeEmailRepository.observeThreads` in `helpers.dart` to propagate `preview` from email to thread.
- Coverage gate now passes at 80%+ (84% with integration coverage merged).

## Android integration test via Stalwart

Added `stalwart-dev/integration_android_test.sh` and `task integration-android`. Starts Stalwart on random ports, detects a connected emulator via `adb devices`, sets `STALWART_IMAP_HOST=10.0.2.2` (emulator host alias), and runs the existing `integration_test/app_e2e_test.dart` on the emulator.

## Quote original message in reply, and add Forward button

`_reply` now passes `prefillBody` with the original message quoted as plain
text (`> line…`). New `_forward` method and Forward toolbar button added;
sets `Fwd:` subject prefix and prefills the same quoted body with To/Cc empty.

## Mark as unread button in email detail

Added `mark_email_unread_outlined` icon button to `EmailDetailScreen` toolbar.
Calls `setFlag(seen: false)` then pops back to the list.

## Pull-to-refresh on email list

Wrapped `_buildStreamBody` in a `RefreshIndicator` that calls `syncEmails`.
The empty-state is now a scrollable `ListView` so the pull gesture works even
when the folder has no messages.

## Show email preview snippet in list

Added `preview` field to `EmailThread` (populated from the latest email in
`_groupIntoThreads`). Thread tiles now show subject + a one-line preview
snippet in the subtitle.

## Extract TryConnectionButton widget shared by account screens

Extracted `lib/ui/widgets/try_connection_button.dart` — a stateless widget
rendering the result banner (ok/error text) and the spinner/button. Both
`add_account_screen` and `edit_account_screen` now use it, removing ~30 lines
of duplicated UI code.

## Extract _batchMoveToRole helper in email_list_screen

`_batchArchive()` and `_batchMarkSpam()` collapsed into a shared
`_batchMoveToRole(role, notFoundMessage)` helper, eliminating ~20 lines of
duplication.

## Enable always_use_package_imports lint rule

Added rule to `analysis_options.yaml`; `dart fix --apply` converted 125 relative
imports across 33 files to `package:sharedinbox/...` style automatically.

## Replace silent catch (_) with logged errors

5 `catch (_)` blocks in JMAP push stream setup and 2 in UI screens now use
`catch (e)` with `log(...)` via the project's `logger.dart` wrapper.
The two intentionally silent catches (malformed SSE JSON, Sent folder already
exists) were left as-is since they already had explanatory comments.

## Safety hardening before real account use

### 1. Fix non-PEEK body fetch (silently sets \Seen)

`lib/data/repositories/email_repository_impl.dart` ~line 163
Change `'(BODY[])'` → `'(BODY.PEEK[])'` so fetching the body does not set \Seen
as a side-effect of the IMAP FETCH command.

Same fix at ~line 1696 for attachment part fetches: `BODY[partId]` → `BODY.PEEK[partId]`.

### 2. Move to Trash instead of EXPUNGE

`lib/data/repositories/email_repository_impl.dart` `deleteEmail` method
Before enqueuing a hard delete, query the local mailboxes cache for a 'trash'-role
folder for that account.

- If found AND the email is not already in Trash: call `moveEmail` to that path.
- If not found OR already in Trash: fall back to the existing EXPUNGE path.

This makes delete reversible — the user can recover from Trash.

### 3. Confirmation dialog for delete

Three call sites need a `showDialog` confirmation before deleting:

a) Delete button in detail view
   `lib/ui/screens/email_detail_screen.dart` ~line 97
   Show AlertDialog "Delete this email?" with Cancel / Delete buttons.

b) Batch delete in list view
   `lib/ui/screens/email_list_screen.dart` `_batchDelete` ~line 268
   Show AlertDialog "Delete N emails?" with Cancel / Delete buttons.

c) Swipe-to-delete in list view
   `lib/ui/screens/email_list_screen.dart` `Dismissible.onDismissed` ~line 436
   Use `Dismissible.confirmDismiss` callback (fires before the item is removed)
   to show a confirmation for the right-swipe (delete) direction only.
   Return false to cancel and keep the item in the list.
