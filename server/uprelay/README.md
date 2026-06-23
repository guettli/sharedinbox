# uprelay — UnifiedPush relay for SharedInbox

`uprelay` is a tiny stateless HTTP service that forwards "new mail" events
from your mail server to UnifiedPush endpoints registered by SharedInbox
clients. Together with the in-app UnifiedPush integration (see
`lib/core/services/unified_push_service.dart`), it enables real-time
notifications without depending on Google Firebase or Apple APNs.

## How it fits together

```
┌─────────────────┐
│ IMAP server     │
│ (sieve, Stalwart│
│  hook, Dovecot  │
│  postlogin, …)  │
└────────┬────────┘
         │ POST /trigger {"account_id":"acc-1"}
         ▼
┌─────────────────┐                ┌────────────────────────┐
│ uprelay (this)  │ POST endpoint  │ UnifiedPush distributor│
│                 │ ─────────────► │ on the user's phone    │
│ /register       │                │ (ntfy, NextPush, …)    │
│ /unregister     │                └──────────┬─────────────┘
│ /trigger        │                           │ IPC
│ /healthz        │                           ▼
└─────────────────┘                ┌────────────────────────┐
                                   │ SharedInbox app        │
                                   │ → AccountSyncManager   │
                                   │   .syncAll()           │
                                   └────────────────────────┘
```

The relay knows nothing about IMAP. It only relays HTTP-to-HTTP. Wiring it
to your mail server is your responsibility — examples below.

## Running

```bash
go run ./server/uprelay -addr :8089 -state /var/lib/uprelay/state.json
```

`state.json` is created on first write. Container/k8s users should mount it
as a volume so registrations survive restarts.

## HTTP API

| Method | Path          | Body                                         | Notes                                      |
| ------ | ------------- | -------------------------------------------- | ------------------------------------------ |
| GET    | `/healthz`    | —                                            | Returns 200 OK.                            |
| POST   | `/register`   | `{"account_id":"<id>","endpoint":"<url>"}`   | Stores the mapping. Idempotent.            |
| POST   | `/unregister` | `{"account_id":"<id>"}`                      | Removes the mapping.                       |
| POST   | `/trigger`    | `{"account_id":"<id>"}`                      | POSTs an empty wake-up to the endpoint.    |

The app obtains its endpoint URL from the distributor and shows it under
**Settings → UnifiedPush**. The user (or a future enrollment screen) sends
it to `/register` with whichever `account_id` they want to wake up.

## Wiring it to your IMAP server

The relay's `/trigger` endpoint deliberately takes only an account ID — it
is unauthenticated by default, so deploy it behind a TLS-terminating reverse
proxy with HTTP basic auth or mTLS in production.

### Stalwart (sieve `vnd.dovecot.execute` shim)

Stalwart's sieve runtime supports HTTP requests via the `eval` extension:

```sieve
require ["fileinto", "envelope", "vnd.stalwart.expressions"];
if header :is "X-Spam" "no" {
  eval("http.post(\"https://uprelay.example.com/trigger\", \"{\\\"account_id\\\":\\\"acc-1\\\"}\");");
}
```

### Dovecot

Use a `postlogin` or LMTP filter script that POSTs to `/trigger` whenever a
message is appended to INBOX. A 2-line `curl` invocation is sufficient.

### IMAP IDLE bridge (future work)

A separate daemon that holds IMAP IDLE per registered mailbox and calls
`/trigger` on EXISTS is a natural follow-up; it slots in front of this
relay without changing the public API.

## Security model

* Registrations carry no credentials — only the endpoint URL is stored.
* The endpoint URL leaks where the user's distributor lives but not the
  contents of any message.
* Wake-ups carry no payload, so even a compromised relay cannot leak mail.
* Run behind TLS. Add basic auth on `/trigger` if you can — there's no
  built-in auth because deployments vary widely.

## Coverage / CI

The relay is intentionally stdlib-only (no `go.sum`) so it builds in CI
without network access. Add tests under `server/uprelay/` using `net/http/httptest`
when you add features.
