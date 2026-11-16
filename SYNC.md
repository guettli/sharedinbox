# Email Sync Architecture

This document describes the full lifecycle of an email action — from the moment the user taps
a button to server confirmation — covering the IMAP IDLE loop, JMAP push/poll, the pending-change
queue, exponential backoff, and the undo/cancel mechanism.

For the database schema and protocol-level implementation details see [DB-SYNC.md](DB-SYNC.md).

---

## 1. Components

| Component | File | Role |
|-----------|------|------|
| `AccountSyncManager` | `lib/core/sync/account_sync_manager.dart` | Owns one `_SyncLoop` per account; starts, stops, and wakes sync loops |
| `_AccountSync` | same file | IMAP sync loop (IDLE + incremental fetch) |
| `_JmapAccountSync` | same file | JMAP sync loop (SSE push + poll fallback) |
| `EmailRepositoryImpl` | `lib/data/repositories/email_repository_impl.dart` | All DB reads/writes and network calls |
| `pending_changes` table | `lib/data/db/database.dart` | Protocol-agnostic outbound mutation queue |
| `UndoService` | `lib/core/services/undo_service.dart` | Persisted undo history; cancel-or-reverse logic |

---

## 2. Lifecycle of an email mutation (e.g. "Mark as read")

```
User taps "Mark as read"
        │
        ▼
EmailRepository.setFlag(id, seen: true)
        │
        ├─ 1. Write optimistic update to local DB
        │      emails.is_seen = true
        │
        └─ 2. Insert row into pending_changes
               { type: 'flag_seen', email_id: id, payload: {seen: true} }
               (IMAP: includes uid + mailboxPath for the STORE command)
               (JMAP: includes just the flag map for Email/set)

[UI immediately reflects the change via Drift's reactive streams]

        │
        ▼ (next sync cycle, triggered by IMAP IDLE / JMAP push / wakeUp)
_SyncLoop._flush() / flushPendingChanges()
        │
        ├─ IMAP: open connection → STORE uid +FLAGS (\Seen) → close
        │
        └─ JMAP: Email/set { update: { id: { keywords: { "$seen": true } } } }
               If stateMismatch → clear checkpoint → full re-sync

        │
        ▼
pending_changes row deleted on success
(on permanent error: retry count incremented; evicted after 5 failures)
```

---

## 3. IMAP sync loop

The IMAP loop runs one coroutine per account (`_AccountSync`):

```
start()
  │
  ▼
[forever loop]
  ├─ flushPendingChanges()   ← drain outbound queue first
  ├─ syncMailboxes()         ← detect new/removed mailboxes
  ├─ for each mailbox:
  │    syncEmails()          ← incremental: fetch only UIDs > lastUid
  │                             deletion reconciliation: remove rows
  │                             whose UID is absent from the server
  └─ _idle()                 ← IMAP IDLE for up to 25 min (RFC 2177)
       │                        Wakes on: server EXISTS/EXPUNGE/FLAGS
       │                        or syncNow() signal from UI
       └─ repeat
```

**Incremental sync checkpoint** — `sync_state` table stores `(accountId, mailbox, lastUid, uidValidity)`.
On each run, only UIDs greater than `lastUid` are fetched. If `uidValidity` changes the full
folder is re-scanned and the checkpoint is reset.

**Duplicate-folder skip** — folders whose contents duplicate every other folder are excluded
from the per-mailbox loop, so their messages are not downloaded a second time (#691). Currently
this is Gmail's "All Mail" (RFC 6154 `\All` special-use / RFC 8621 `all` role), detected via
`isDuplicateOfOtherFolders` (`lib/core/models/mailbox.dart`). The same guard runs in the IMAP
loop, the JMAP loop, and the force-resync-all loop; an explicit single-folder resync of All Mail
is still honored. The folder itself stays in the list with its server counts.

**Mailbox deletion reconciliation** — mailboxes absent from `LIST` (IMAP) or the
`Mailbox/get` response (JMAP full sync) are removed locally, along with their cached
emails, threads, IMAP sync checkpoint and any queued pending changes that referenced them.
If a folder is deleted between mailbox-sync and the per-mailbox email-sync of the same
cycle, `SELECT` fails with `NO [NONEXISTENT]`; the email loop catches that, prunes the
local cache, and returns zero instead of surfacing an error. The UI's email list bounces
the user back to the account's folder list when the currently open folder disappears.

**IMAP move remap** — IMAP UIDs are mailbox-scoped, so a moved message gets a new UID in
its destination folder. When a `move`/`snooze`/`unsnooze` change is flushed, the local row
id (`accountId:mailboxPath:uid`) is rewritten in place to point at the new UID. The new
UID is taken from the RFC 4315 `COPYUID` response code returned by `MOVE`; if the server
does not advertise `UIDPLUS`, a `UID SEARCH HEADER Message-ID …` in the destination
mailbox is used as a fallback. `email_bodies`, `threads`, `pending_changes`, and
`undo_actions` rows that reference the old id are updated atomically so cached bodies and
pending undo operations keep tracking the same physical message. When a later move,
snooze or unsnooze of the mail is still queued (it starts in this move's destination),
only the row's id and UID follow the server: the row keeps showing the mail where the
user's last move put it (#1276). Deletion reconciliation
also skips rows whose move is still queued, so the optimistic local move never gets
wiped mid-flight.

**No resurrection by a late FETCH answer** — the new-mail FETCH does not insert a row for
a UID whose move, snooze, unsnooze or delete is queued, checked both before the FETCH is
sent and after its answer arrived. A row the user moved or deleted *while* the answer was
on its way (and a flush may already have sent) is skipped too, via the in-memory edit
sequence of `_ServerFlagRead`: the answer predates the change and would bring the mail
back as a duplicate in its old folder (#1269). A change that is `failed` by the time the
answer is processed hides nothing (a failed move's revert has already put the row back;
for a failed delete the answer's copy is inserted again), and neither does one stamped
with an older UIDVALIDITY.

**IDLE cap** — IDLE sessions are limited to 25 minutes per the RFC. The loop also wakes
immediately if `syncNow()` is called (e.g. user pulls-to-refresh).

---

## 4. JMAP sync loop

The JMAP loop (`_JmapAccountSync`) follows a similar structure but uses HTTP:

```
start()
  │
  ▼
[forever loop]
  ├─ flushPendingChanges()   ← Email/set for queued mutations
  ├─ syncMailboxes()         ← Mailbox/get or Mailbox/changes
  ├─ for each mailbox:
  │    syncEmails()          ← Email/query + Email/get (first run)
  │                             Email/changes (subsequent runs, state token)
  └─ _wait()
       ├─ Subscribe to SSE push (`watchJmapPush`)
       ├─ If the stream stays open: wake only on a real `StateChange`
       │    event or a `kick()` from the UI — same shape as IMAP IDLE.
       │    The underlying SSE connection is capped at 25 min, so a
       │    silent server still gets a re-sync at that cadence.
       └─ If the stream ends immediately or later (no eventSourceUrl,
            connect failure, SSE timeout): fall back to a 30 s poll.
```

**State tokens** — each `Mailbox/changes` / `Email/changes` call uses the server-provided
`state` token stored in `sync_state`. A `stateMismatch` error clears the token and triggers
a full re-fetch.

**JMAP send** — outgoing mail uses `EmailSubmission/set` when the server advertises the
`urn:ietf:params:jmap:submission` capability; falls back to SMTP otherwise.

**Diagnosing push** — every branch of `watchJmapPush` writes an app-log row
tagged with the `sync.jmap.push` event and a `push_status` data field
(`connected`, `unsupported`, `connect_failed`, `sse_failed`, `sse_status_<N>`,
`closed`, `errored` — see `lib/core/sync/push_status.dart`). The sync-state
view (Settings → Accounts → your account → Sync state) surfaces the latest
row as a "Push connected" / "Falling back to 30 s poll" card so the user can
tell whether the 30 s cadence is a bug or the server simply not offering an
`eventSourceUrl`. `_JmapAccountSync._wait()` additionally logs a `sync.jmap.wait`
debug row with `sync_wait=push_event | poll_fallback | stop` explaining why
each cycle woke.

---

## 4a. Thread derivation

Threads are stored in the `threads` aggregate table so that folder listings can
show a single row per conversation. The `threadId` written on each `emails`
row drives that grouping and is updated in the same transaction as the email
upsert; the surrounding `_updateThread` call then recomputes the aggregate
(subject, participants, latest date, unread/flagged rollups) from the emails
that share the id.

**JMAP** — the server reports a `threadId` on every `Email` object and we use
it verbatim. Cases where the server omits it fall back to the per-email
`accountId:jmapId` so the message ends up in a singleton thread.

**IMAP** — IMAP has no `threadId`, so the sync loop derives one from the
already-fetched RFC 2822 headers (`References`, `In-Reply-To`, `Message-ID`).
The rule mirrors the classic JWZ algorithm, in order:

1. **First entry of `References`** — the oldest ancestor. Every reply down
   the chain carries the whole chain oldest-first, so all replies agree on
   the same root Message-ID.
2. **`In-Reply-To`** — some clients drop `References` but keep the immediate
   parent; using it keeps the reply attached to that parent's thread.
3. **Own `Message-ID`** — starts a fresh thread. Later replies attach to it
   via steps 1 or 2.
4. **Subject fallback** — for non-conformant senders that emit neither a
   Message-ID nor any reference header, group by
   `subj:<yyyy-mm>:<normalised subject>` bucketed on the message's `Date:`
   header. [`normalizedSubject`](lib/core/utils/subject_normalize.dart)
   strips stacked `Re:`/`Fwd:`/`AW:`/`WG:` prefixes, ticket tokens and
   bracketed noise, then lowercases the result. Bucketing by year-month
   bounds the time window so a subject that gets reused a year later
   starts a new thread instead of resurrecting an old one.
5. **Emailless singleton** — if every input is missing (no headers, no
   subject) the caller uses the per-message `accountId:mailboxPath:uid` so
   the message still has a stable, unique thread id.

The helper lives at `EmailRepositoryImpl._computeThreadId` (exposed via
`computeThreadIdForTest` for the unit tests in
`test/unit/email_repository_impl_test.dart`). The IMAP fetch loop
(`_fetchAndUpsertImap`) calls it inside the same DB transaction that upserts
the email row, then calls `_updateThread` once per affected thread key —
mirroring the JMAP path.

---

## 5. Exponential backoff

Both loops share the same backoff policy:

| Outcome | Backoff |
|---------|---------|
| Sync succeeded | Reset to 5 s |
| Network / server error | Double previous backoff, capped at 900 s (15 min) |

The backoff counter (`_backoffSeconds`) is per-account and per-process; it resets to 5 s
on the next successful cycle.

The last error message is written to `sync_log` and surfaced in the UI via
`syncLastErrorProvider` (the red `MaterialBanner` in the email list).

---

## 6. Pending-change queue

`pending_changes` is a protocol-agnostic table that stores every outbound mutation before it
reaches the server:

| Column | Description |
|--------|-------------|
| `id` | Auto-increment primary key |
| `email_id` | The email being mutated |
| `type` | `flag_seen`, `flag_flagged`, `move`, `delete`, `snooze` |
| `payload` | JSON-encoded protocol-specific arguments |
| `attempts` | Incremented on each failed try that may have reached the server; 0 means never sent |
| `created_at` | For debug; the flush runs in `id` order |
| `state` | `pending` (queued or retrying), `inflight` (claimed by a flush) or `failed` (given up on) |
| `lease_until`, `claim_token` | While `inflight`: until when the claim holds, and which flush holds it |

**Optimistic UI** — every mutation writes the local change first, then inserts into
`pending_changes`. The Drift reactive stream delivers the update to the UI before
the network round-trip completes.

**Conflict resolution** — the server always wins. On the next sync cycle the server's
state overwrites local rows. Outbound mutations are retried up to 5 times; after that
they are marked `state = 'failed'`, not deleted. Permanent per-item JMAP errors
(`forbidden`, `notFound` for a flag or move) and an IMAP change whose message is gone
(or cannot be found again after a UIDVALIDITY reset) skip the retry counter and are
marked failed at once. A JMAP `notFound` for a delete, and an IMAP change whose
source folder no longer exists, count as applied: the mail is already gone.

**Claim** — a flush claims each change right before sending it: `state = 'inflight'`
with `lease_until` = now + 5 minutes and the flush's random `claim_token`, as one
compare-and-set, so no other flush (another isolate, a second desktop process on the
same database, a force resync racing the sync loop) takes it, and Undo cannot cancel
it (it queues a reverse change instead). A flush also leaves every change of a mail
that another flush is sending, so a mail's changes reach the server in order. Every
outcome settles the claim, and only while the flush still owns it (same token): the
row is deleted when applied, goes back to `pending` (not sent: nothing charged; maybe
sent: one attempt charged) or becomes `failed`. A claim the flush left unsettled (an
unexpected error) is released at the end of that flush with one attempt charged. A
claim whose lease ran out means the app died mid-send: the next flush of the account
puts it back to `pending` with one attempt charged and sends it again; every apply
path first checks whether the change is already done (a move finds the mail in its
destination, a flag STORE is idempotent, a delete of a gone mail counts as applied).
`inflight` rows protect their local value from sync like `pending` ones; the Pending
Changes screen shows them as "sending…".

A network error charges no attempt: a failed IMAP connect, or a JMAP request that got
no answer (socket, TLS, `http` client error, timeout), stops the flush for the next
cycle. A JMAP request may still have landed, so its change goes back to `pending`
marked as maybe sent (attempts at least 1: Undo queues a reverse change instead of
cancelling it) but is not charged further; re-sending it is safe.

A failed change is never flushed again and protects nothing from sync (the guards
only count `pending` and `inflight` rows), so the next server read shows server truth again. A failed
read or star change makes the flag reconcile of the mail's folder due, so the next sync
reads that folder's flags (with CONDSTORE, and with JMAP, an unchanged mail is otherwise
read again only every 15 minutes, #1270); a separate `…ReconcileDue:<folder>` marker
keeps a reconcile already running from overwriting that: a pass clears it only when it
ran to the end, the marker was not set again meanwhile, and it did not have to skip a
mail with a failed flag change because another change of that mail is still queued. It also puts the flag back at
once to its value before the change, unless another change of the same flag exists for
the mail (then that value is not known locally).
A failed move, snooze or unsnooze is also undone locally at once: the mail goes back to its
source folder with its earlier snooze state (payloads carry `prevSnoozedUntil` /
`prevSnoozedFrom` for that), and later IMAP flag changes queued for it in the
destination are pointed back at the source UID, and the flag reconcile of the source is
made due (read/star changes made meanwhile may have failed too). This is skipped when the mail is
gone (message gone, UIDVALIDITY reset, JMAP `notFound`), when it is no longer where
the change put it, or when its source folder was renumbered since. The mail's later
queued moves, snoozes, unsnoozes and deletes address it where the failed change
would have put it, so they fail with it (`depends on failed change #id`), and the
revert goes back to the first change's source. Within one flush, once a mail's move,
snooze, unsnooze or delete did not apply, its later changes wait (uncharged) for the
next flush. A move
whose destination folder is missing (`NO [TRYCREATE]`) fails this way too; a change
naming a folder removed on the server is marked failed (`folder removed on the
server`) instead of deleted.

Failed changes are listed on the Pending Changes screen and the mailbox-list banner,
with **Retry** (queues a fresh copy at the end of the queue, so it cannot jump ahead
of newer changes, and shows its effect locally again; a change still queued keeps
its place and is only flushed sooner) and **Discard** (deletes it). Queueing the same
action again (or an Undo) deletes the failed change it replaces; changes the app
queues on its own (snooze wake-up, local Sieve filters, the #545 replay) never do,
and the wake-up skips a mail whose move, snooze or unsnooze failed.

Known gaps: a failed **delete** is not undone locally, and a hard-deleted row is not
fetched back until a force resync. Rows already removed by a reconcile before the
change failed (IMAP: the source UID is at or below the folder checkpoint; JMAP: the
mailbox prune) are not recovered either, nor is a mail optimistically moved into a
folder that was then removed on the server (its row goes with the folder).

---

## 7. Undo and cancel

When the user triggers an undoable action the UI calls:
```
ref.read(undoServiceProvider.notifier).pushAction(UndoAction(...))
```

`UndoService` persists the action to the `undo_actions` table (max 10 entries, FIFO).
A `SnackBar` with an **Undo** button appears for a few seconds.

When the user taps Undo, `UndoService.undo()` executes this sequence for each affected email:

```
1. cancelPendingChange(id, originalType)
      └─ Deletes the pending_changes row if nothing was sent for it yet
         (`state = 'pending'`, `attempts = 0`). Returns false when a flush has
         claimed it (`inflight`), it may have reached the server, or the
         server already processed it.

2. If the email row was hard-deleted (DELETE action):
      restoreEmails([original])
         └─ Re-inserts the row with its pre-deletion state,
            placed in the correct mailbox (source if cancelled, dest otherwise).

3. moveEmail(id, sourceMailboxPath)
      └─ Optimistic local move back to the original folder.
         If step 1 returned false (already sent to server), this enqueues
         a reverse-move in pending_changes so the server move is undone too.

4. If step 1 returned true (cancelled before flush):
      cancelPendingChange(id, 'move')
         └─ The reverse-move from step 3 is redundant; remove it.
```

The net result is: if the mutation was still in the queue it is silently cancelled with no
server round-trip; if it had already been flushed, a compensating move is queued.

---

## 8. Key invariants

- **Order**: pending changes are flushed before syncing. This prevents the server from
  overwriting an optimistic local state that the server hasn't seen yet.
- **Idempotency**: `flushPendingChanges` is safe to call multiple times. Each row is
  deleted only after the server acknowledges the change.
- **No silent data loss**: a change the app gives up on (retry limit, permanent server
  error, message gone) is kept as a `failed` row and surfaces as a `FailedMutation`
  in the UI (mailbox-list banner → Pending Changes), never deleted without the user.
- **Offline-first**: the user-facing contract these invariants serve is in
  [OFFLINE-FIRST.md](OFFLINE-FIRST.md).
- **UI layer isolation**: `lib/ui/` never imports `lib/data/`; all interaction goes
  through `core/` interfaces. The `check-layers` Taskfile task enforces this.

---

## 8a. Local self-sent "virtual" messages

A mail addressed to one of the user's own accounts appears in that account's inbox
**as soon as the server accepted it**, so it can be starred, noted or filed while the
real message is still in flight (#545). `enqueueSend` stamps a deterministic RFC 5322
`Message-ID` and queues the send as usual. Once the outbox sender's send succeeded —
SMTP accepted the message (IMAP) or the `EmailSubmission` was created (JMAP) — it writes
a row to `emails` with `is_local = 1`, `uid = 0` and that Message-ID.

- **Never before acceptance**: a send that SMTP/JMAP rejects, that keeps failing, or that
  is discarded from the Sent Queue leaves no inbox row behind — otherwise the user would
  see a "received" mail that was never delivered. Trade-off: a note to self queued while
  offline appears once it is actually sent, not at queue time.
- **Already arrived**: the row is skipped when the real message (non-local, same
  Message-ID, in a known folder whose role is not `sent`) is already stored, since its
  arrival had nothing to dissolve. Check and insert run in one transaction, and the
  insert is `insertOrIgnore` so a repeated send never resets the user's edits.
- **Best-effort**: a failure to write the row is logged, never rethrown — the message is
  already sent and must not be sent again.

- **Not pruned**: local rows have no server UID, so both deletion-reconciliation passes
  (`_reconcileDeletedImap`, `_pruneJmapMailboxToServerIds`) skip `is_local` rows.
- **No outbound mutations**: `_enqueueChange` is a no-op for a local row — there is no
  server message to flag/move/delete yet, so the state stays purely local.
- **Dissolve on arrival**: when the real message is synced in, `_maybeDissolveLocalMessage`
  matches it by Message-ID, transfers the star / read-state / folder the user set on the
  virtual copy (queuing the equivalent server mutations so both converge), then deletes
  the virtual row. Notes need no migration — they are keyed by Message-ID, which both
  rows share. The Sent copy we append after sending is left alone (matched by mailbox
  `role == 'sent'`); only the inbox arrival dissolves the virtual message.

---

## 9. Fuzz testing the sync engine

`test/backend/sync_reliability_runner_test.dart` runs the IMAP/JMAP sync engine
against an isolated Stalwart instance with multiple parallel DBs, performs
random create / update / delete operations, and asserts that all snapshots
converge. It runs with the rest of the backend suite (`task test-backend`); the
long-running nightly fuzz is `task test-fuzz`.

Pass `--fuzz` via the `SYNC_RELIABILITY_ARGS` environment variable (newline-
separated) to additionally inject randomised faults around the IMAP, SMTP and
JMAP clients:

| Fault | Effect |
|-------|--------|
| `imap`/`smtp` connect failure | `SocketException` before reaching the server |
| `imap`/`smtp` latency | 100–800 ms delay before connecting |
| HTTP connect failure | `http.ClientException` from the JMAP client |
| HTTP 503 | transient server-side error response |
| HTTP latency | 100–800 ms delay before forwarding the request |
| HTTP truncated body | the JMAP response stream closes mid-payload |
| JMAP `stateMismatch` | provokes the engine's state-token reset / re-fetch path |

The sync engine is expected to recover from every fault — the existing
convergence assertion in `_waitForConvergence` still applies. Each run prints
its seed; re-running with `--fuzz-seed=N` reproduces the exact same fault
sequence. Locally (with a Stalwart and Flutter SDK on PATH):

```
SYNC_RELIABILITY_ARGS=$'--fuzz\n--fuzz-seed=42\n--fuzz-prob=0.15\n--cycles=5' \
  flutter test test/backend/sync_reliability_runner_test.dart
```

The fault-injection layer itself lives in `scripts/sync_reliability_fuzz.dart`
and has unit coverage in `test/unit/sync_reliability_fuzz_test.dart`.

**Stale answers.** `test/unit/stale_answer_fuzz_test.dart` runs in
`task check-fast` (no network; about 15 s on its own, more under the
`--coverage` run of check-fast). It drives the real
`EmailRepositoryImpl` against a stateful in-memory IMAP server
(`test/unit/helpers/stateful_fake_imap.dart`: folders with UIDVALIDITY,
UIDs, Message-IDs, flags and MODSEQ; SELECT, UID SEARCH, UID FETCH incl.
CHANGEDSINCE, UID STORE, UID MOVE with COPYUID, UID EXPUNGE). The server
can hold an answer back after computing it: the test then lets the user
star, mark read, move or delete a mail, runs another flush, or lets another
client change the server, before the app reads the old answer. After the
queue drains and sync settles it checks, per mail: local read/star/folder
equal the server, the server equals the user's last action on each field
(unless another client changed that field since), the app changed nothing on
the server the user did not ask for, and no change is left `pending` or
`failed` (unless the server refused it or another client moved the mail
away). A failure prints the seed and the action trace. A seed reproduces
the run only against the same code (any change in the IMAP commands the app
sends shifts the random choices), so the trace is the durable record. Bugs it
finds and that are not fixed yet are kept as skipped regression tests in the
same file, and the driver avoids exactly their triggers; the regression tests
of fixed ones (#1266–#1271, #1276) run.
Longer or focused runs (locally, with a
Flutter SDK):

```
STALE_FUZZ_SEEDS=500 flutter test test/unit/stale_answer_fuzz_test.dart
STALE_FUZZ_SEED=17,42 STALE_FUZZ_VERBOSE=1 flutter test test/unit/stale_answer_fuzz_test.dart
STALE_FUZZ_KNOWN_BUGS=1 flutter test test/unit/stale_answer_fuzz_test.dart  # run the skipped ones
```

To check how a real server behaves before relying on a semantic (rather than
fuzzing the engine), probe a throwaway Stalwart directly — see
`stalwart-dev/README.md` and `stalwart-dev/jmap_probe.py`.
