# Gmail support

Gmail can be added like any other IMAP/SMTP account: on the **Add account**
screen, type your Gmail address and SharedInbox fills in the servers for you
(`imap.gmail.com:993` and `smtp.gmail.com:465`, both TLS) — you never enter a
server name. This works for both `@gmail.com` and the legacy `@googlemail.com`
addresses.

## What you still need to enter today

Google no longer accepts your normal account password over IMAP/SMTP. Until
one-tap Google sign-in lands (see below), you authenticate with an **App
Password**:

1. Enable **2-Step Verification** on your Google account.
2. Create an **App Password** (Google Account → Security → App passwords).
3. Paste the 16-character App Password into the password field.

App Passwords are unavailable if a Google Workspace admin has disabled them.

## The "All Mail" folder

Gmail exposes an **All Mail** folder (IMAP `[Gmail]/All Mail`) that holds a copy
of every message in every other folder. SharedInbox skips it during automatic
sync so each message is downloaded once from its real folder rather than a second
time from All Mail (#691). Detection is role-based — the folder carries the
RFC 6154 `\All` special-use flag (mapped to the `all` role) — so it also covers
localized Gmail names and any non-Gmail server that advertises an `all`-role
folder. The folder still appears in the folder list and can be synced on demand
via an explicit single-folder resync. See [SYNC.md](SYNC.md).

## Integration options considered

Only server auto-fill (above) is implemented so far. The remaining options are
recorded here so the trade-offs are not lost.

### A. App Password over IMAP/SMTP — *implemented (server auto-fill)*

- **Pro:** no OAuth infrastructure, no Google verification, works on every
  platform immediately, reuses the existing IMAP/SMTP sync engine.
- **Con:** the user must enable 2-Step Verification and copy-paste a token, so
  it does not fully meet the "no copy-paste password" goal; unavailable when a
  Workspace admin disables App Passwords.

### B. OAuth 2.0 + XOAUTH2 over IMAP/SMTP — *recommended next step*

Authorization-code + PKCE flow ("Sign in with Google"), then authenticate
IMAP/SMTP with XOAUTH2 (`enough_mail` already supports this via
`ImapClient.authenticateWithOAuth2` and SMTP `AuthMechanism.xoauth2`).

- **Pro:** best UX — pick an account and consent, no server/username/password
  entry; reuses the existing sync engine.
- **Con:** needs a Google Cloud project + OAuth consent screen; the
  `https://mail.google.com/` scope is *restricted* and requires Google's
  security assessment (CASA) for public distribution — until then it is limited
  to test users; per-platform redirect handling (Android intent-filter, iOS URL
  scheme, desktop loopback listener) is extra work, and refresh-token storage
  and renewal must be added.

### C. Gmail REST API backend (`gmail.googleapis.com`) via OAuth

- **Pro:** purpose-built, best rate limits, native push (Pub/Sub).
- **Con:** a large new protocol backend (like the JMAP one) — new account type,
  new sync and send paths, label↔folder mapping — that does not reuse the IMAP
  engine, and still needs OAuth plus restricted-scope verification. Highest
  effort.

### D. `google_sign_in` package for the OAuth step

- **Pro:** native Android account picker, less flow code on mobile.
- **Con:** oriented at foreground access tokens, awkward to obtain the durable
  refresh tokens that background IMAP IDLE needs; weak desktop support; same
  verification requirement. Best used as the Android front-end to option B
  rather than on its own.

**Recommendation:** ship server auto-fill now (option A), then add option B for
true one-tap sign-in once a Google Cloud client ID and the restricted-scope
verification are in place.
