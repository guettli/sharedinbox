# SharedInbox — Next Steps Plan

Priority-ordered list of MUA features to implement. Android/iOS packaging is out of scope for now.

## 1. Mark as read on open ✅ done

Was already implemented: `EmailDetailViewModel` calls `setKeyword(…, SEEN, true)` after body load.

## 2. CC in compose ✅ done

Added `cc` field to `ComposeViewModel` and a CC `OutlinedTextField` in `ComposeScreen`.

## 3. Reply / Reply-All ✅ done

- `Screen.Compose` extended with `replyToEmailId`, `prefillTo/Cc/Subject/Body`.
- `ComposeViewModel.init()` accepts prefill params.
- `EmailDetailScreen` shows "Reply" and "Reply All" `TextButton`s in the TopAppBar.
- Quoted body and `Re:` subject prefix are built from the loaded email.

## 4. HTML body rendering ✅ done

- `htmlToPlainText()` strips tags and decodes entities.
- `EmailDetailScreen` falls back to the HTML body (stripped) when no text body exists.

## 5. Unread count badge in mailbox list ✅ done

Was already implemented: `unread_emails` stored from JMAP and shown in `MailboxRow`.

## 6. Attachment viewing ✅ done

- `EmailBodyPart` now carries `name`, `size`, `disposition`.
- `Email` model has `attachments: List<EmailBodyPart>`.
- `JmapApiClient.getEmailAttachments()` and `downloadBlob()` added.
- `EmailRepository.getAttachments()` and `downloadBlob()` added and implemented.
- `AttachmentOpener` interface in `core`; JVM impl uses temp file + `Desktop.open()`; Android/iOS stubs provided.
- `EmailDetailViewModel` loads attachments when `hasAttachment` is true; exposes `downloadAttachment()`.
- `EmailDetailScreen` shows attachment rows with name, size, and "Open" button.

## Next candidates

- Thread view (group emails by `threadId`)
- Search (JMAP `Email/query` with filter)
- Draft auto-save (`$draft` keyword)
- Attachment sending (upload blob, attach to outgoing email)
- Keyboard shortcuts (desktop: j/k, r, f, d)
