# Done

This file contains tasks which got implemented.

Tasks get moved from NEXT.md to DONE.md

## Tasks

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
