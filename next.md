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

### 3. Advanced Search and Performance

- **Indexing**: Optimize database indexes for search performance.
- **UI**: Add advanced search filters (date range, attachment size, etc.).

### 4. Fuzz Testing

- **Fuzz Testing**: Add a basic fuzz test for the sync engine to handle simulated
  real-world network latency and RFC edge cases.
