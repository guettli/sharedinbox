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

### Render HTML email bodies

#### Current state

HTML mail *reading* (transport + storage) is already implemented: the IMAP
fetcher stores the HTML body on `EmailBody.htmlBody`
(`lib/core/models/email.dart:89`). What is missing is HTML *rendering*:
`lib/ui/screens/email_detail_screen.dart:158` currently strips tags via
`htmlToPlain(body.htmlBody ?? '')` and shows the result as plain text.

#### Plan

1. Add `flutter_html: ^3.0.0` to `pubspec.yaml`.
   - Mature, pure-Dart (no JS / no platform views), works on desktop +
     mobile + web.
2. Update `lib/ui/screens/email_detail_screen.dart` `_buildBody`:
   - Prefer `body.htmlBody` over `body.textBody`.
   - If `htmlBody` is present and non-empty, render with the `Html` widget.
   - Else fall back to the current `SelectableText(textBody)` path.
3. Block remote image loading by default (privacy — defeats tracking
   pixels). At the top of an HTML message, show a small
   "Load remote images" button that flips a per-screen `bool` and
   re-renders. Implement by passing a custom image-loading delegate to
   `flutter_html` that returns an empty widget for `http(s)` images
   until the flag is set. Inline `cid:` images are out of scope for
   this task.
4. Leave `htmlToPlain` in place — it is still used for reply / forward
   quoting (`_quotedBody`) where plain text is correct.
5. No DB schema changes, no generated-code changes, no migration.
6. No new tests required (pure UI rendering change). Existing widget /
   integration tests must keep passing.

#### Out of scope (follow-ups if needed)

- Clickable / launchable links inside HTML.
- Dark-mode HTML colour normalisation.
- Sandboxed rendering via `WebView` / `flutter_inappwebview`.
- Inline `cid:` image resolution.

#### Verification

- `task deploy-android` succeeds.
- Manual: open an HTML newsletter — formatting (lists, bold, links) is
  visible instead of raw tags or stripped text.
- Manual: a plain-text-only email still renders unchanged.
