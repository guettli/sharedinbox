# Maybe Next Steps

Read NEXT.md for next steps.

## SharedInbox — Possible Next Features

Inspired by K9/Thunderbird for Android and community feature requests.
K9 source: https://github.com/thunderbird/thunderbird-android
K9 feature requests: https://github.com/thunderbird/thunderbird-android/issues

---

## High value / low complexity

### Keyboard shortcuts (desktop)
- `j` / `k` — next / previous email in list
- `r` — reply, `R` — reply-all, `f` — forward
- `e` — archive, `d` — delete, `m` — move
- `u` — mark unread, `s` — toggle star (`$flagged`)
- `c` — compose
- `Enter` — open, `Escape` — back

---

## Medium complexity

### Thread / conversation view
- JMAP already returns `threadId` on every email — group by it in `EmailListScreen`
- `Thread/get` fetches all email IDs in a thread
- Collapsed thread header shows latest snippet, expand to see all messages
- Reply-all automatically includes all thread participants

### Search
- `Email/query` already accepts `filter` with `text`, `from`, `subject`, `hasAttachment`, `after`, `before`
- Search bar in email list header
- Filter chips: from, subject, attachments, date range
- Results screen reuses `EmailListScreen`

### Unified inbox
- Virtual "All Inboxes" mailbox entry at the top of `MailboxListScreen`
- Queries `Email/query` across all accounts (parallel), merges by `receivedAt`
- Unread count = sum of all account inbox unread counts


### Vacation auto-responder (JMAP VacationResponse)
- `VacationResponse/get` and `VacationResponse/set` — simple extension of `JmapApiClient`
- UI in `SettingsScreen`: toggle enabled, subject, message body, start/end date
- Supported by Stalwart

### Smart / virtual folders
- "Starred" — `Email/query` filter `hasKeyword: "$flagged"`
- "Sent" — filter `hasKeyword: "$answered"` or sent mailbox
- "All mail" — no mailbox filter
- Shown as a pinned section above the account's real mailbox tree

---

## Higher complexity

### OS notifications (desktop + Android)
- On new email SSE event, show platform notification with sender + subject snippet
- Click notification → navigate to email
- Per-account and per-mailbox notification settings (all, inbox-only, off)
- Notification grouping by account

### Snooze / remind me later
- Tap "Snooze" → pick time → email disappears from inbox until that time
- Implemented as `move to Snoozed folder` + scheduled `WorkManager` job that moves it back
- Snoozed folder shown in mailbox list with a clock icon

### Scheduled send
- "Send later" button in `ComposeScreen` → date/time picker
- Save as draft with `$draft`, schedule a `WorkManager` job to send at the chosen time
- Shown in a "Scheduled" virtual folder; cancellable

### HTML compose (rich text)
- Currently compose uses a plain `TextField`
- Switch to a `WebView`-backed rich text editor (e.g. Quill, Summernote)
- Send as `text/html` part with `text/plain` fallback
- Adds complexity on KMP — may need platform-specific implementations

### Contact groups / distribution lists
- `ContactCard/get` for groups (kind = "group")
- Show group suggestions in `To`/`CC` autocomplete
- Expand group to individual addresses on send

### Calendar invite handling
- Parse `text/calendar` (`.ics`) attachments in email body
- Show event summary (title, time, organizer) with Accept / Decline / Tentative buttons
- JMAP Calendar (`urn:ietf:params:jmap:calendars`) for the actual response — Stalwart supports it

### Read receipts (MDN)
- Detect `Disposition-Notification-To` header in incoming emails
- Prompt user to send receipt (or auto-send based on preference)
- Send MDN via `Email/set` + `EmailSubmission/set`

### PGP / S-MIME
- Integrate OpenPGP (e.g. pgpainless or BouncyCastle on JVM)
- Key management screen
- Sign and/or encrypt outgoing, verify and/or decrypt incoming
- Complex but frequently requested

---

## Nice to have / polish

- **Print email** — render to PDF via platform print dialog
- **Share email** — Android share intent / macOS share sheet
- **Per-folder sync frequency** — some folders sync rarely (Archive), others often (Inbox)
- **Message expiry** — auto-delete emails older than N days per folder
- **External link confirmation** — warn before opening links from untrusted senders
- **Mute thread** — never show notifications for this thread again
- **Block sender** — add to local blocklist, move future emails to Trash automatically
