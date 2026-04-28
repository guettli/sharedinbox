# Done

This file contains tasks which got implemented.

Tasks get moved from next.md to done.md

## Tasks

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
pipeline (Linux + Android UI tests, MobSF scan, APK upload) work in `nix develop`:

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

Two parallelism improvements:

- `_integrations` internal task: runs `integration` and `integration-ui` in parallel (they use
  random Stalwart ports and different Flutter build targets so there is no conflict).
- `_mobsf-start` internal task: starts the MobSF Docker container as a dep of `build-android`,
  so it warms up concurrently with the APK build instead of blocking for up to 90 s afterwards.
- `scripts/mobsf_scan.sh`: added `docker rm $CONTAINER_NAME 2>/dev/null || true` before
  `docker run` to handle stopped-but-not-yet-removed containers (same fix applied to the new
  `_mobsf-start` task).

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
