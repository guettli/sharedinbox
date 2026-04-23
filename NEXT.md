# Next

## Introduction

Do one thing, then run `task check`. Then commit.

After commit, remove the item from this document.

## Tasks

Create a script which tests that IMAP/JMAP to DB sync works reliably.

Create two DBs which connect to the same Stalwart account.

The script should do random create/update/deletes on both DBs (via the Dart code), and check after
100 concurrent changes, that both DBs are in sync.

The script should be called with a the number of updates (100 by default) and the number of cycles
(50 by default).

Then check the script. First with small amount: 10/1, 20/2, ...

BTW: Start an own Stalwart server for this. See existing code.

Ask questions first. Then do.
