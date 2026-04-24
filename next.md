# Next

## Introduction

Do one thing, ask if unsure first!

Then implement.

Then run `task check`.

Then move task to done.md

Check if all files are staged.

Git repo should not contain unknown files.

Then commit.

## Tasks

## Pull-to-refresh on email list

`EmailListScreen` has a manual sync icon button but no swipe-to-refresh gesture.
Wrap the `StreamBuilder` result body in a `RefreshIndicator` that calls the
same sync trigger as the icon button.

File: `lib/ui/screens/email_list_screen.dart`

## Mark as unread button in email detail

`EmailRepository.setFlag(emailId, seen: false)` already exists. Add a
"Mark as unread" icon button (or overflow menu item) in `EmailDetailScreen`
that calls `setFlag(seen: false)` then pops the screen so the message
reappears as unread in the list.

File: `lib/ui/screens/email_detail_screen.dart`

## Quote original message in reply, and add Forward button

When replying, `prefillBody` is never set so compose opens with an empty body.
Set `prefillBody` to the original message formatted as a plain-text quote:

```text
\n\n— On <date>, <from> wrote:\n> line1\n> line2…
```

For Forward, add a third icon button (Icons.forward) next to reply/reply-all:

- subject: `Fwd: <original subject>`
- To/Cc: empty (user fills in)
- body: same quoted original text

The body snapshot is already available in `_buildBody()` context.

File: `lib/ui/screens/email_detail_screen.dart`
