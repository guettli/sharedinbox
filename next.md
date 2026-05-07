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

### 1. Implement Undo for Delete and Move actions

Provide a way for users to undo accidental deletions or moves, improving the safety of the application.

- **Infrastructure**: Implement a `ChangeLog` or similar mechanism to track the last N destructive actions.
- **UI**: Display a snackbar with an "Undo" button after a delete or move action.
- **Logic**: Implement the reverse operation (moving back from Trash or to the source folder) when Undo is pressed.
- **Sync**: Ensure that undo operations correctly interact with the `pending_changes` queue.
