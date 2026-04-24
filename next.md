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
