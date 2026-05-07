# Next

## Introduction

Continue the momentum from the safety hardening and infrastructure work.
The focus is on making the app ready for real-world use with robust error
handling and performance optimizations.

Create several small commits. Every commit should be self contained.

while working create/append to plan.log, so that the user sees what you are working on.

## Tasks

### 0. deploy-android

Make `task deploy-android` work.

### 0.5 Debug duration of deploy-android

Is there a way to make deploy-android faster?

Use `task --verbose` to see what gets done.

Maybe avoid doing things again, when nothing changed.
Taskfile has features to avoid calling things again, when the input has not changed.

### 1. Fix Android E2E Race Condition (aliceTile)

The Android E2E test `integration_test/app_e2e_test.dart` is flaky. It fails
at `tap(aliceTile)` with "0 widgets" even though `pumpUntil` found it.
The current "double pumpUntil" fix isn't reliable enough.
Investigate if the animation state or the Drift stream propagation is the
culprit.

### 2. Implement Global Crash Screen

Wrap `main()` in `runZonedGuarded` to catch unhandled async errors.
Implement a `CrashScreen` widget that shows the stack trace and a
"Copy to Clipboard" button for user reporting.

### 3. Database-Backed Threading

Currently, emails are grouped into threads in-memory in the repository.
Refactor to store thread relationships in the local SQLite database.
This is necessary for performance on mailboxes with thousands of messages.

### 4. Implement Undo for Bulk Actions

Add a global "Undo" snackbar after deleting or moving emails.
The system needs to handle the three sync states:
- Queued (easy to undo)
- In-progress (cancel network call)
- Finished (requires a reverse move/un-delete)

### 5. Transition to Real Account Testing

Prepare the integration tests to run against a real test account
(`si3e2e@thomas-guettler.de`) instead of the local Stalwart server.
This verifies the app against real-world network latency and RFC edge cases.

### 6. Coverage Gate Maintenance

Reduce the `_excluded` list in `scripts/check_coverage.dart`.
Add a test to ensure the exclusion list doesn't contain files that no longer
exist ("ghost paths").
