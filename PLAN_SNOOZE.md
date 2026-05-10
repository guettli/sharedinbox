# Snooze Feature Plan

## Goal
Allow users to snooze emails, moving them to a special folder and bringing them back to the Inbox at a specified time. Snooze data must be stored in the account (IMAP/JMAP) for cross-device synchronization.

## Technical Approach

### 1. Metadata Storage (Account Sync)
- **Keyword format:** `snz:<ISO8601_TIMESTAMP>` (e.g., `snz:2026-05-10T15:00:00Z`).
- **JMAP:** Use `keywords`.
- **IMAP:** Use User Flags (keywords).

### 2. Database Changes
- **Migration v22:**
    - `Emails` table:
        - `snoozedUntil` (DateTime, nullable)
        - `snoozedFromMailboxPath` (String, nullable) - to remember where to move it back (usually INBOX).
    - Index on `snoozedUntil`.

### 3. Repository Updates (`EmailRepository`)
- New method: `Future<void> snoozeEmail(String emailId, DateTime until)`
    - Optimistically update local DB.
    - Enqueue `snooze` change.
- New method: `Future<int> wakeUpEmails(String accountId)`
    - Find local rows where `snoozedUntil <= now`.
    - Enqueue `move` back to original mailbox.
    - Clear snooze metadata.

### 4. Sync Loop Integration
- In `AccountSyncManager`, call `wakeUpEmails(accountId)` at the start of each sync cycle.
- Update IMAP/JMAP sync logic to parse `snz:` keywords and update local `snoozedUntil` / `snoozedFromMailboxPath`.

### 5. UI Implementation
- **Snooze Picker:** A dialog with options like "Later today", "Tomorrow morning", "Next week", "Custom".
- **Action:** Add "Snooze" icon to `EmailListScreen` selection bar and `EmailDetailScreen`.
- **Mailbox:** Ensure a "Snoozed" mailbox exists (create if missing).

## Implementation Steps
1. [ ] Database migration and model updates.
2. [ ] Repository implementation for `snoozeEmail` and `wakeUpEmails`.
3. [ ] Update flush logic for IMAP and JMAP to handle `snooze` mutations.
4. [ ] Update sync logic to parse snooze keywords.
5. [ ] Integrate `wakeUpEmails` into the sync loop.
6. [ ] UI: Snooze picker dialog.
7. [ ] UI: Add Snooze action to list and detail screens.
8. [ ] Testing and validation.
