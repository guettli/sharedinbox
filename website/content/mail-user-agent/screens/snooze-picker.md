---
title: 'Snooze Picker'
description: 'Bottom sheet used to pick when a snoozed email should reappear.'
---

![Snooze Picker](/mail-user-agent/screenshots/snooze-picker.png)

The **Snooze Picker** is the bottom sheet that opens whenever you snooze an
email — from [Email Detail](/mail-user-agent/screens/email-detail/), or from
the selection bottom bar in [Email List](/mail-user-agent/screens/email-list/)
or [Combined Inbox](/mail-user-agent/screens/combined-inbox/).

**Source:** `lib/ui/widgets/snooze_picker.dart` — `SnoozePicker`.

## What you can pick

- **This evening** — 18:00 today (only shown before 18:00).
- **Tomorrow morning** — 08:00 tomorrow.
- **Next week** — same weekday, seven days from now.
- **Pick date & time…** — arbitrary date/time up to a year out.

The chosen `DateTime` becomes the `until` parameter of
`EmailRepository.snoozeEmail(emailId, until)`. See
[Snooze](/mail-user-agent/snooze/) for what happens next.
