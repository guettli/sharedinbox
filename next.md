# Next

## Introduction

Do one thing, ask if unsure first!

Then implement.

Then run `task deploy-android`. Fix, if there are errors.

Then move task which you implementeed to done.md. Keep tasks you did not work in the file.

Check if all files are staged.

Git repo should not contain unknown files.

Then commit.

Then push

## Tasks

### 1. Infrastructure Hardening and Code Quality

Continue the momentum from the safety hardening and infrastructure work.
The focus is on making the app ready for real-world use with robust error
handling and performance optimizations.

- **Sync Reliability**: Implement a "Sync reliability" check that compares local
  counts with server counts periodically.
- **Search Optimization**: Add a "Recent Searches" history and optimize local search
  indexing for large accounts.
- **UI Polishing**: Ensure consistent spacing and theming across all screens.
- **Error Boundaries**: Add more granular error boundaries to prevent the entire
  app from crashing if a single widget fails.

### 2. Unified Attachment Handling and Improved Previews

Refactor attachment logic to be more consistent and provide better user feedback.

- **Previews**: Implement thumbnail generation for image attachments.
- **Progress**: Show download progress in the UI when fetching attachments.
- **Caching**: Implement a more robust caching mechanism with expiry.

### 3. Sync Reliability and Conflict Resolution

- **Reliability**: Implement a "Reliability Runner" that periodically verifies local state against the server.
- **Conflicts**: Improve handling of concurrent changes (e.g., mail moved on server while local move is pending).

### 4. Advanced Search and Performance

- **Indexing**: Optimize database indexes for search performance.
- **UI**: Add advanced search filters (date range, attachment size, etc.).

### 5. Multi-account Sync and Reliability Runner

Implement a robust verification system to ensure the local database accurately
reflects the server state across multiple accounts and protocols.

- **Reliability Runner**: A background service that periodically fetches a "ground truth"
  snapshot (UIDs/IDs only) for all folders and identifies discrepancies.
- **Sync Reliability UI**: Add a "Sync health" indicator in settings showing when each
  account was last verified 100%.
- **Network Resilience**: Improve backoff and retry logic for intermittent connections,
  especially for mobile.
- **Fuzz Testing**: Add a basic fuzz test for the sync engine to handle simulated
  real-world network latency and RFC edge cases.

### 6. Coverage Gate Maintenance

Reduce the `_excluded` list in `scripts/check_coverage.dart`.
Add a test to ensure the exclusion list doesn't contain files that no longer
exist ("ghost paths").
