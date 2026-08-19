# Bug report service

Small HTTP service that backs the in-app **Report a Bug** screen.

It has two flows:

1. **Confidential reports** (`POST /api/v1/bug-reports`) — stored privately on
   disk, never published.
2. **Public issue with an encrypted mail** (`POST /api/v1/encrypted-reports`) —
   creates a public GitHub issue whose attached email is encrypted on the
   device so only the maintainer can read it. Used when a user reports a bug
   *about a specific email* (issue #636).

## Endpoints

| Method & path | Purpose |
| --- | --- |
| `POST /api/v1/bug-reports` | Confidential report (multipart: `description`, `about_info`, optional `email`, `email_data`, `sync_log`, `attachments[]`). Returns `{ "id": "<uuid>" }`. |
| `GET  /api/v1/report-key` | Returns the maintainer's public key: `{ "keyId", "publicKey", "alg" }` (both keys base64). |
| `POST /api/v1/encrypted-reports` | Multipart: `description` (required), `encrypted_mail` file (required), optional `about_info`, `sync_log`. Stores the ciphertext, opens a GitHub issue linking to it, and returns `{ "id", "issueUrl", "issueNumber" }`. |
| `GET  /api/v1/encrypted-reports/{id}/mail.enc` | Serves the stored ciphertext so the maintainer can download and decrypt it. |

All endpoints are globally rate limited to 10 requests/minute and cap bodies at
20 MB.

## Configuration (environment variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `BUGREPORT_PORT` | `8090` | Listen port. |
| `BUGREPORT_STORAGE_DIR` | `./reports` | Where reports and encrypted blobs are stored. |
| `PUBLIC_BASE_URL` | `https://sharedinbox.de` | Base URL used to build the `mail.enc` download link placed in the issue. |
| `REPORT_PUBLIC_KEY` | — | base64 of `keyId[16] || publicKey[32]` (same payload the app embeds in its public-key QR codes). Required for `/report-key`. |
| `GITHUB_TOKEN` | — | Token with `issues:write` on the target repo. |
| `GITHUB_REPO` | — | `owner/name` of the repo issues are created in. |
| `GITHUB_API_URL` | `https://api.github.com` | Override for GitHub Enterprise. |

When `GITHUB_TOKEN`/`GITHUB_REPO` are unset the encrypted-report endpoint
responds `503 Service Unavailable`.

## Cryptography

The app encrypts the raw RFC-822 mail with ECIES
(X25519-ECDH + HKDF-SHA256 + AES-256-GCM), the same scheme used for secure
account sharing (`lib/core/services/share_encryption_service.dart`), with the
HKDF label `sharedinbox-encrypted-report`.

Wire format of `mail.enc` (raw bytes):

```
keyId[16] || ephPubKey[32] || nonce[12] || ciphertext || mac[16]
```

### Generating the key pair

Generate an X25519 key pair once, keep the **private** key offline, and publish
only `REPORT_PUBLIC_KEY = base64(keyId[16] || publicKey[32])`.
`ShareEncryptionService.generateKeyPair()` produces exactly these fields.

### Reading a report

Download `mail.enc` from the issue link and decrypt it with the private key via
`ShareEncryptionService.decryptBytes(..., info: 'sharedinbox-encrypted-report')`,
which returns the original `.eml` bytes.
