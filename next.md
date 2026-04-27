# Next

## Introduction

Do one thing, ask if unsure first!

Then implement.

Then run `task deploy-android`. Fix, if there are errors.

Then move task which you implementeed to done.md. Keep tasks you did not work in the file.

Check if all files are staged.

Git repo should not contain unknown files.

Then commit.

## Tasks

I opened an account. How to get back to the list of accounts?

I saw no way to do that.

---

I opened a mailbox. I search for "foo bar". I want to see all mails containing foo and bar. Not
mails containing "foo bar" exactly.

---

I search for "foo". Now I see all mails containing "foo". I want to easily do the common actions on
the selected mails: Delete, Archive, Move to Folder, Move to Junk, ...

---

How can I edit the Sieve Filter?

---

When adding a new account, and no well-known file was found, not exact hint in DNS, then
SMTP/IMAP/JMAP should use the mx record as fallback.

---

How can I edit Sieve Scripts? Afaik this feature was added.

---

Replace the custom TextField-in-AppBar search implementation in
lib/ui/screens/email_list_screen.dart with Flutter's built-in SearchBar / SearchAnchor widget
(Flutter 3.x).

Goals:

Remove the _isSearching bool, the _searchController, the slide animation, and the manual Timer
debounce

Use SearchAnchor + SearchBar to drive the _searchQuery state that filters the email list

Keep the existing filter logic untouched — just replace the input mechanism

The search bar should live in the AppBar area; if SearchAnchor doesn't fit cleanly there, use
SearchBar standalone with onChanged (no debounce needed — let the user control submit, or accept
instant filter)

Preserve all existing AppBar actions (compose, sync, settings) when search is not active

Update or remove any tests in integration_test/ that relied on the old search widget tree

---
