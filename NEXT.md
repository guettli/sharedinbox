# Next

## Introduction

Do one thing, ask if unsure first!

Then implement.

Then run `task check`.

Then move task to DONE.md

Check if all files are staged.

Git repo should not contain unknown files.

Then commit.

## Tasks

## Extract _tryConnection logic into shared mixin for account screens

`add_account_screen.dart` and `edit_account_screen.dart` duplicate the `_tryConnection()` method and the `_tryTesting`/`_tryOk`/`_tryErr` state triplet. Extract into a shared mixin or base widget.
