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

### 1. Multi-account search improvement

Extend the search functionality to allow searching across all accounts.

- **UI**: Add a search icon to the account list screen or a global search bar.
- **Repository**: Implement `searchEmailsGlobal` to query all accounts in the database.
- **Protocol**: For remote search, parallelize IMAP SEARCH across multiple accounts.
