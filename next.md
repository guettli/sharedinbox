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

### 1. High-Priority Infrastructure & Performance
- **FTS5 Search Indexing**: Migrate the local search from SQLite `LIKE` queries to
  a proper `FTS5` virtual table. This is critical for maintaining performance as
  the local database grows into thousands of messages.
- **Search History**: Implement a "Recent Searches" UI component in the
  `SearchScreen` to allow quick re-runs of common queries.

### 2. User Experience & Notifications
- **UnifiedPush Integration**: Research and implement `UnifiedPush` support to
  provide real-time background notifications for new emails without relying on
  proprietary push services.
- **UI Consistency Pass**: Conduct a thorough review of spacing, padding, and
  typography across all screens to ensure a polished Material 3 experience.
- **Draft Synchronization**: Update the `Drafts` repository to sync local drafts
  with the server-side `Drafts` folder via IMAP/JMAP.

### 3. Safety & Resilience
- **Encrypted Local Storage**: Add an optional layer of encryption to the Drift
  database (using `sqlcipher`) to protect cached emails when the device is locked.
- **Advanced Error Boundaries**: Implement more granular `ErrorWidget` wrappers
  around critical components (like the HTML renderer) to prevent localized
  rendering issues from crashing the whole screen.
- **Fuzz Testing**: Expand the `reliability_runner` with a basic fuzz test for the
  sync engine to simulate extreme network conditions and server edge cases.
