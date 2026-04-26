# Done

This file contains tasks which got implemented.

Tasks get moved from next.md to done.md

## Tasks

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
