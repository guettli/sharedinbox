# Bug report service

Small HTTP service that backs the in-app **Report a Bug** screen.

There is **one** submission flow (`POST /api/v1/encrypted-reports`): every
report opens a **public GitHub issue** carrying the cleartext fields
(`description`, system info). Anything private is encrypted on the device and
uploaded as separate blobs the issue links to, so only the maintainer (holding
the private key) can read them:

- **encrypted mail** (`mail.enc`) — the full `.eml`, when the user reports a bug
  *about a specific email* and opts to attach it (issue #636).
- **encrypted metadata** (`metadata.enc`) — a small YAML block with the private
  non-mail details: the optional contact email and, when the full mail is not
  attached, the reported email's metadata (#847).
- **encrypted screenshots** (`image_<n>.enc`) — each screenshot the user adds
  (issue #851).

Every encrypted part is optional: a general bug report with no email is just a
public issue with no attachments (#847).

## Endpoints

| Method & path | Purpose |
| --- | --- |
| `GET  /api/v1/report-key` | Returns the maintainer's public key: `{ "keyId", "publicKey", "alg" }` (both keys base64). |
| `POST /api/v1/encrypted-reports` | Multipart. Cleartext fields: `about_info` (required), optional `description`, `sync_log`. Encrypted file parts (all optional): `encrypted_mail`, `encrypted_metadata`, `encrypted_attachments[]` (screenshots). Stores the blobs, opens a public GitHub issue linking to each, and returns `{ "id", "issueUrl", "issueNumber" }`. |
| `GET  /api/v1/encrypted-reports/{id}/mail.enc` | Serves the stored encrypted mail. |
| `GET  /api/v1/encrypted-reports/{id}/{name}` | Serves a stored `metadata.enc` or `image_<n>.enc` blob. |

> **Note:** the older confidential endpoint `POST /api/v1/bug-reports` (private
> on-disk reports) has been removed (#847). Any reports it stored before removal
> are left untouched on disk under `BUGREPORT_STORAGE_DIR`.

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
| `BUGREPORT_PPROF_ADDR` | `127.0.0.1:6061` | Listen address for the `net/http/pprof` handlers, served on a **separate** non-public listener. Set to the WireGuard IP (e.g. `10.0.0.1:6061`) so Parca can scrape heap/goroutine/mutex/block profiles; set to `off` to disable. |

When `GITHUB_TOKEN`/`GITHUB_REPO` are unset the encrypted-report endpoint
responds `503 Service Unavailable`.

## Profiling (pprof)

Go's `net/http/pprof` handlers (heap, goroutine, mutex, block, cpu profile,
trace) are served on a **separate** listener via `BUGREPORT_PPROF_ADDR`
(default `127.0.0.1:6061`). They leak the command line, goroutine stacks and
live heap, and `profile`/`trace` pin a CPU for the profile's whole duration —
so this listener must never share the public interface. Bind it to the
WireGuard IP in production so Parca can scrape it; a bind failure only logs and
never takes the server down.

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

Each encrypted-report issue carries a **"How to decrypt"** section with a
ready-to-run command. The `bugreport` binary has a `decrypt` subcommand that
reads `REPORT_PRIVATE_KEY` + `REPORT_PUBLIC_KEY` from the environment (an
AgentLoop `sharedinbox` worker already has both) and turns a `mail.enc` blob
back into the original `.eml`:

```sh
curl -fsSL '<download URL from the issue>' -o mail.enc
go run ./server/bugreport decrypt mail.enc > mail.eml   # or: decrypt - < mail.enc
```

The subcommand implements the same ECIES scheme as the app
(`ShareEncryptionService.decryptBytes(..., info: 'sharedinbox-encrypted-report')`),
so a Dart tool with the private key works too.

### Encrypted screenshots

Screenshots attached to an encrypted report are encrypted on the device with the
**same** ECIES scheme and HKDF label as the mail and uploaded as
`encrypted_attachments[]`. The server stores each as `image_<n>.enc` and links it
from the issue. The `decrypt` subcommand is content-agnostic, so a screenshot
decrypts exactly like the mail:

```sh
curl -fsSL '<image_n.enc URL from the issue>' -o image_1.enc
go run ./server/bugreport decrypt image_1.enc > image_1.png
```
