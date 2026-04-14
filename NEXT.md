### CI for iOS App

I can provide a stalwart URL with username and password, whih can send mails to itself.

---

- **Swipe actions** (mobile) — swipe left = archive, swipe right = delete; configurable

- **Avatar / contact photo** — show sender photo from contact book in email list

- **Improved HTML rendering** — proper `WebView` instead of stripping tags

### Attachment sending
- File picker in `ComposeScreen` — opens platform file chooser
- Upload blob via `JmapApiClient.uploadBlob()`, attach `blobId` to outgoing email
- Show attachment chips with size and remove button

### Per-account signature
- Add `signature: String` to the account model and settings screen
- Append automatically when composing or replying

### Forward email
- New `Screen.Compose` mode alongside reply/reply-all
- Quote original with `---------- Forwarded message ----------` header
- Attach original attachments option

### Draft auto-save
- Periodic (e.g. 30s) `Email/set` with `$draft` keyword while composing
- Resume draft: show drafts folder, open into pre-filled `ComposeScreen`
- Discard on send or explicit close

### Account color coding
- Color dot/stripe per account in mailbox list and email list rows
- Color picker in settings, stored in the local `account` table
