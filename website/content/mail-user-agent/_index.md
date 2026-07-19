---
title: 'Mail User Agent'
description: 'How the sharedinbox.de mail client is organised, screen by screen.'
---

This section documents the sharedinbox.de mail client from the user's point of
view. Every screen has a stable **name** — the same name is used in the app's
AppBar, in the source code, and here in the docs. When you file a bug, using
that name (for example *Combined Inbox* or *Email Detail*) is the fastest way
for a human or a coding agent to find the right code.

## Sections

- [Screens](/mail-user-agent/screens/) — one page per screen, with a screenshot
  and links to the screens you can navigate to from there.
- [Snooze](/mail-user-agent/snooze/) — how the Snooze feature works and where
  the data lives.

## Screen naming convention

Each screen has one canonical name (Title Case, with spaces). The name shows up
in three places:

| Where | Example |
| --- | --- |
| AppBar title in the app | `Combined Inbox` |
| Source file under `lib/ui/screens/` | `combined_inbox_screen.dart` |
| Widget class | `CombinedInboxScreen` |

The [Screens](/mail-user-agent/screens/) index lists every screen with its
canonical name, its source file, and how you reach it in the app. Bottom-sheet
pickers and dialogs also get named surfaces where they matter for bug reports
(for example the [Snooze Picker](/mail-user-agent/screens/snooze-picker/)).

## Screenshots

Screenshots live under `website/static/mail-user-agent/screenshots/` and are
referenced from the screen page with the same slug as the page URL, e.g.
`combined-inbox.png` for `/mail-user-agent/screens/combined-inbox/`. Adding a
new screenshot is a matter of dropping the image into that folder — the page
markup already points at the expected filename.

Recommended dimensions: 720 × 1440 (portrait phone at 2x) so the images look
sharp on both desktop and mobile without inflating page weight.
