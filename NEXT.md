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

## Enable always_use_package_imports lint rule

Add `always_use_package_imports: true` to `analysis_options.yaml`, then fix all relative imports across `lib/` to use `package:sharedinbox3/...` style.

## Extract _batchMoveToRole helper in email_list_screen

`_batchArchive()` and `_batchMarkSpam()` in `lib/ui/screens/email_list_screen.dart` (~lines 249–313) share the same pattern: look up a mailbox role, validate, iterate selected ids, call repo method. Extract a shared `_batchMoveToRole(String role)` helper.

## Extract _tryConnection logic into shared mixin for account screens

`add_account_screen.dart` and `edit_account_screen.dart` duplicate the `_tryConnection()` method and the `_tryTesting`/`_tryOk`/`_tryErr` state triplet. Extract into a shared mixin or base widget.
