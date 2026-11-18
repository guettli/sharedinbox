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
| `EmailRepositoryImpl` | `lib/data/repositories/email_repository_impl.dart` (state and public API) and its parts in `email_repository_impl/`, one per writer role (SYNC-REDESIGN.md, Appendix A) | All DB reads/writes and network calls |
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
        └─ One transaction:
           ├─ 1. Insert row into pending_changes
           │      { type: 'flag_seen', email_id: id, payload: {seen: true} }
           │      (IMAP: includes uid + mailboxPath for the STORE command)
           │      (JMAP: includes just the flag map for Email/set)
           │
           └─ 2. Fold the row's queued changes into it (§6a)
                  emails.local_is_seen = true
                  emails.is_seen = COALESCE(local_is_seen, srv_is_seen) = true

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
pending_changes row acked on success (state = 'acked'): it keeps showing
until a later server read confirms it, then it is dropped (§6a)
(on a refusal: state = 'failed'; after 5 failures that may pass: 'stuck')
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
  │                             deletion reconciliation: mark rows gone
  │                             whose UID is absent from the server
  │                             (deleted once no change of theirs is left)
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
`Mailbox/get` response (JMAP full sync) are removed locally, along with their threads
and IMAP sync checkpoint. Queued changes that referenced them are marked failed (listed
on the Pending Changes screen). The mails the server had there are marked gone and
deleted unless a change of theirs is still in flight or acked (§6a, clean-up rule); a
mail the user had moved into the folder shows in its source again, where the server
still has it (its failed move no longer folds).
If a folder is deleted between mailbox-sync and the per-mailbox email-sync of the same
cycle, `SELECT` fails with `NO [NONEXISTENT]`; the email loop catches that, prunes the
local cache, and returns zero instead of surfacing an error. The UI's email list bounces
the user back to the account's folder list when the currently open folder disappears.

**Row identity** — every `emails` row records where the server has the message:
`srv_mailbox_path`, `srv_uid` and `srv_uid_validity` (IMAP) or `srv_mailbox_path`
(the mailbox id) and `srv_jmap_id` (JMAP), unique per account (schema v70; the JMAP
mailbox since v73). Sync finds the row of a server message by these columns, never by
building or parsing the row id, and never by the shown `mailbox_path`: behind a queued
move that already names the destination, so a re-fetch of the source would otherwise
insert a second row. Every folder-scoped sync scan (deletion reconcile, JMAP prune,
flag reconciles) selects rows by `srv_mailbox_path` too. Server calls about a row
(body fetch, attachment download, raw message, JMAP flush) use them as well. A row whose
location is unknown matches a known UIDVALIDITY as well; a row stamped with another
UIDVALIDITY is another message. Local virtual rows (§8a) have no UID or JMAP id; their
`srv_mailbox_path` is their own folder.

The row id is **opaque**: a new row (fetch, JMAP upsert, Sent copy, virtual row) gets
`accountId:~` plus 32 random hex digits (`newEmailId`, `lib/data/repositories/email_ids.dart`),
so a reused UID can never name another mail's row. No code builds an id from a location
or reads anything out of one; `scripts/check_email_ids.sh` (part of `check-layers`, run by
`check-fast`) fails on the old shapes.

Row ids are also **frozen**: a row keeps the id it was inserted with for its whole life.
A row that carries over to a new location (a move, the body-fetch healing, a move made by
another client) changes only its UID, shown `mailbox_path` and `srv_` columns, so
everything that references it (body, attachments, queued changes, App Log, threads, Undo,
notification marks, draft replies, an open detail view) stays valid. When two rows turn out
to hold the same mail, the second one is merged into the kept one and deleted
(`_mergeDuplicateRow`, App Log warn `email.duplicate_merged`): its queued changes, thread
entries, Undo history, App Log lines, notification marks and draft replies point at the
kept row, and its body and downloaded attachments (folder and `attachment_files` rows)
move over if the kept row has no body; otherwise its attachment folder is deleted. That is the only place that
re-points references between rows; `check_email_ids.sh` also fails on any other write of
`emails.id` after insert or re-pointing of references. Rows stored before schema v71 keep their old ids
(`accountId:mailboxPath:uid`, `accountId:jmapId`, `accountId:__local__:…`); what those
said was moved into columns once, by the v70/v71 migrations: the server location, the
`jmapId` stamped on each queued JMAP change, and `is_virtual_sent_copy`. Undo snapshots
older than v70 were completed the same way (path and UIDVALIDITY by the v70 rules), and
the background new-mail check's `accountId:INBOX:uid` marks in `notified_emails` got their
location key (`notifiedImapLocationKey`). A JMAP row without a recorded server id queues
no server change (App Log warn `pending_change.no_server_id`), and Undo does not restore a
JMAP row whose server id another row holds by then: sync stored that mail again. When the server gives a location to another
row's mail, a stale row still recording it gives it up, with an App Log line.

**IMAP move remap** — IMAP UIDs are mailbox-scoped, so a moved message gets a new UID in
its destination folder. When a `move`/`snooze`/`unsnooze` change is flushed, the row keeps
its id; its UID and server location follow the server (`_relocateEmailRow`), and so do the
UIDs in its queued IMAP changes. The new
UID is taken from the RFC 4315 `COPYUID` response code returned by `MOVE`; if the server
does not advertise `UIDPLUS`, a `UID SEARCH HEADER Message-ID …` in the destination
mailbox is used as a fallback. Cached bodies, downloaded attachments, queued changes,
logs, threads and Undo history reference the id, so they keep tracking the same physical
message without a rewrite. A copy sync already stored at the new location with the same
Message-ID is dropped (App Log warn `email.duplicate_merged`); its queued changes, logs,
thread and Undo references (and its body, if the kept row has none) move to the kept row. Only the row's
UID and server location follow the server; the folder it shows is the fold of its
queued changes (§6a), so when a later move, snooze or unsnooze of the mail is still
queued the row keeps showing the mail where the user's last move put it (#1276). The
body-fetch identity guard (#616) relocates a row the same way. Deletion reconciliation
never deletes a row with a queued change, so the optimistic local move never gets wiped
mid-flight.

**Foreign move** — when another client moves a mail, its UID vanishes from the source
folder and a new UID appears in the destination. On servers with a move-stable id (RFC 8474
`EMAILID`, Gmail `X-GM-MSGID`, stored as `serverEmailId`), the deletion reconcile of the
source looks for the row sync already stored elsewhere with that id: a server row (not a
local virtual one) of the same account, in another folder, or in the same folder at another
UID that still exists (our own move whose answer was never recorded left the row with its
old UID). When exactly one such row exists (#589), the vanished row carries over: it keeps
its id and takes the other row's place (shown folder, UID, server location, headers, and
the flags it has no queued change for), and the other row is merged into it (see "Row
identity"; App Log warn `email.duplicate_merged`). The vanished row survives because it is
the one the user knows (an open detail view, Undo, notifications and drafts reference its
id), while the other was stored by a recent sync. A change queued on the vanished row before
the move follows the mail to its new UID, stamped with the UIDVALIDITY that UID was learned
under, and the row keeps showing its queued flag until the change is sent (a newer change
of the same flag on the other row wins). With no such row, or more than one (e.g. a Gmail
mail still under two other labels), the vanished row is marked gone (and deleted once
no change of it is left); so it is when the other row's location was recorded under an
older UIDVALIDITY of its folder (its UID may name another mail). The carry-over waits for
a later sync when the user moved the vanished row meanwhile or a change of the other row
is being sent right now. When the source folder is synced before the destination, the
row is marked gone and the destination's sync stores a new row: the carry-over needs
the vanished row to wait for its copy without a change of the user's to keep it, which
the clean-up rule does not allow (still open after phase 6: the force resync's
mark-and-sweep, §6a, is a different mechanism).

A shared move-stable id is taken as "the same mail". That holds for RFC 8474 `EMAILID` and
Gmail's `X-GM-MSGID`; servers that derive it from a content GUID (Dovecot keeps the GUID on
`COPY`) give a copy the id of its original, so a copy in another folder counts as the same
mail too: if the original is deleted while exactly one copy exists, the original's row takes
the copy's place. The mail is the same message either way; only the row's history (body,
Undo, logs) is the original's.

**No resurrection by a late FETCH answer** — the new-mail FETCH does not insert a new
row for a UID whose move, snooze, unsnooze or delete is queued, being sent or acked,
checked both before the FETCH is sent and after its answer arrived. An applied move or
delete stays `acked` until a read started after it confirms it (§6a), so a change the
user made *while* the answer was on its way, and a flush sent meanwhile, is still seen
after the answer arrived, in every isolate (until phase 4a an in-memory guard did this,
per repository instance). The answer predates the change and would bring the mail back
as a duplicate in its old folder (#1269). A row still recorded at that location is not
skipped: the answer only writes its server columns, and the queued change keeps showing
over them. A change that is `failed` by the time the answer is processed hides nothing
(it no longer folds, so the mail shows where the server has it), and neither does one
stamped with an older UIDVALIDITY. Remaining gap: when a read started after the ack
settles the change before the stale answer is processed (two syncs of one account at
once), the answer is stored as a new row, which the next reconcile of that folder marks
gone. This queue check (`_pendingDeleteOrMoveUids`) is the one sync guard left after
the overlays, on purpose (phase 6a): the overlay records where a row is, not where it
was, so once a move's answer relocated the row nothing in `emails` tells a stale answer
about the old UID from a new mail there; the change's payload is the only record of the
vacated location. Matching by Message-ID instead would also skip a real second copy (a
self-sent mail's Inbox and Sent copies), and a skipped UID is never fetched again.

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
   subject) the caller uses the row id so the message still has a stable,
   unique thread id.

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
| `type` | `flag_seen`, `flag_flagged`, `move`, `delete`, `snooze`, …; since schema v75 also the mailbox ops `create_mailbox` and `rename_mailbox`, since v76 `move_mailbox` and `delete_mailbox` (`resource_type` `Mailbox`, `resource_id` a `mailboxes.id`, §6b) |
| `payload` | JSON-encoded protocol-specific arguments |
| `attempts` | Incremented on each failed try that may have reached the server; 0 means never sent |
| `created_at` | For debug; the flush runs in `id` order |
| `state` | `pending` (queued or retrying), `inflight` (claimed by a flush), `stuck` (retry limit reached, still retried with backoff), `failed` (refused, given up on), `acked` (applied, waiting for a read to confirm it, §6a), `parked` (the mail has no server copy yet, §8a) or `shadow` (a counterpart's view of another account's change, §6a) |
| `lease_until`, `claim_token` | While `inflight`: until when the claim holds, and which flush holds it. While `acked`: for a move whose new location the server never named, until when it waits for its destination copy (§6a) |
| `ack_seq`, `contradicted_seq` | While `acked`: the read sequence taken at the ack, and that of the first later read that contradicted it (§6a) |
| `origin` | Schema v74: `counterpart:<id>` for a shadow of change `<id>`; NULL otherwise |

**Optimistic UI** — every mutation inserts into `pending_changes`, and the queued change
is folded into the row in the same transaction (§6a): read, star and snooze state and,
since schema v73, the folder (a delete for good hides the row). The Drift reactive
stream delivers the update to the UI before the network round-trip completes.

**Conflict resolution** — the server always wins once nothing of the user's is queued
for a field. A failure that may pass (a plain IMAP `NO`, a timeout, a
JMAP request error) is retried; after 5 attempts the change is `stuck`: it keeps
protecting the user's local value (the mail stays where the user put it), shows as
"not synced yet" on the Pending Changes screen and the mailbox-list banner, and is
retried with a growing backoff (15 minutes, doubling, at most 6 hours, kept in
`lease_until`) until it applies or the user discards it. Only a refusal becomes
`state = 'failed'`, at once: an IMAP `NO` with a permanent response code
(`[CANNOT]`, `[NOPERM]`, `[CONTACTADMIN]`, `[PRIVACYREQUIRED]`, `[READ-ONLY]`),
permanent per-item JMAP errors (`forbidden`, `notFound` for a flag or move), and an
IMAP change whose message is gone (or cannot be found again after a UIDVALIDITY
reset). A JMAP `notFound` for a delete, and an IMAP change whose
source folder no longer exists, count as applied: the mail is already gone.

**Claim** — a flush claims each change right before sending it: `state = 'inflight'`
with `lease_until` = now + 5 minutes and the flush's random `claim_token`, as one
compare-and-set, so no other flush (another isolate, a second desktop process on the
same database, a force resync racing the sync loop) takes it, and Undo cannot cancel
it (it queues a reverse change instead). A flush also leaves every change of a mail
that another flush is sending, so a mail's changes reach the server in order. Every
outcome settles the claim, and only while the flush still owns it (same token): the
row is acked (read/star/snooze changes, §6a) or deleted when applied, goes back to `pending` (not sent: nothing charged; maybe
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

A failed change is never flushed again, no longer folds into the row (§6a) and protects
nothing from sync (the location guards only count `pending`, `inflight` and `stuck`
rows), so the mail shows the server's read/star/snooze state again at once, as last read.
A failed read or star change also makes the flag reconcile of the mail's folder due, so
the next sync reads that folder's flags (the last read may predate the change reaching
the server; with CONDSTORE, and with JMAP, an unchanged mail is otherwise read again only
every 15 minutes, #1270); a separate `…ReconcileDue:<folder>` marker keeps a reconcile
already running from overwriting that: a pass clears it only when it ran to the end and
the marker was not set again meanwhile.
A failed move, snooze or unsnooze is also undone locally at once: it no longer folds, so
the mail shows in the folder the server has it in (its source) and with its snooze state
(the payload's `prevSnoozedFrom` restores the folder it was snoozed from); a failed
delete shows the mail again. Later IMAP flag changes queued for it in the
destination are pointed back at the source UID, and the flag reconcile of the source is
made due (read/star changes made meanwhile may have failed too). The re-pointing is skipped when the mail is
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

Failed and stuck changes are listed on the Pending Changes screen and the
mailbox-list banner, with **Retry** (a failed change: queues a fresh copy at the end
of the queue, so it cannot jump ahead of newer changes, and shows its effect locally
again; a stuck or queued change keeps its place and is only flushed sooner) and
**Discard** (deletes it; a stuck or queued one is first undone locally like a
failure, so the mail does not keep a state the server never gets). A change that did
not apply in a flush, or a stuck one not due yet, holds back the mail's later changes,
so they reach the server in order; a newer read/star change replaces a queued
(not yet claimed) or stuck one of the same flag. Queueing the same
action again (or an Undo) deletes the failed change it replaces; changes the app
queues on its own (snooze wake-up, local Sieve filters) never do,
and the wake-up skips a mail whose move, snooze or unsnooze failed.

Since schema v73 sync no longer deletes a row the user has a change for (§6a, clean-up
rule): a mail the server lost while a change of it was queued stays until that change
applies or fails (App Log warn `email.server_gone_with_changes`), and a delete for good
hides its row until the server confirms the mail is gone, so a failed delete shows the
mail again and an Undo that cancels it keeps its body. Known gap: a row the clean-up
rule already deleted (no change left) is not fetched back until a force resync.

---

## 6a. Read, star and snooze state and folder: the overlays

Schema v72, SYNC-REDESIGN.md §2–§5 (phases 3a and 3b). `is_seen`, `is_flagged` and
`snoozed_until` are each three columns on `emails`:

| Column | Written by | Meaning |
|--------|------------|---------|
| `srv_<field>` | the server-write gate only | what the server last said |
| `local_<field>` | the fold only | the user's pending intent; NULL = none (`local_snoozed_until` = 0: "not snoozed") |
| `<field>` | together with either | what the app shows: `COALESCE(local_<field>, srv_<field>)` |

All three are written through the email state writer
(`lib/data/repositories/email_state_writer.dart`), which sets the effective column in
the same statement and never rewrites the whole row.

**The `location` overlay** (schema v73, phase 4a): the folder a mail shows in,
`mailbox_path`, works the same way.

| Column | Written by | Meaning |
|--------|------------|---------|
| `srv_mailbox_path` | the server-write gate (and `relocate`, `renameFolder`) | the folder the server has the mail in (IMAP path, JMAP mailbox id); a row without a server copy has its own folder here. Never NULL: an insert trigger records the shown folder for a row inserted without one |
| `srv_gone` | the gate | the server no longer has the mail (absent from an enumeration of its folder, JMAP `notFound`/`destroyed`, a delete the server confirmed) |
| `local_mailbox_path` | the fold | the destination of the row's latest queued `move`/`snooze`/`unsnooze` |
| `local_hidden` | the fold | a queued delete for good |
| `mailbox_path` | together with either | `''` when `local_hidden`, or `srv_gone` without a `local_mailbox_path`; else `COALESCE(local_mailbox_path, srv_mailbox_path)` |
| `srv_location_seq` | the gate, acks | the read sequence that last wrote `srv_mailbox_path`/`srv_gone` |

- **Hidden rows.** `''` is no folder, so every folder query skips a hidden row; the
  others (`getEmail`, searches, lookups by address, Message-ID or thread, the folder
  statistics, the wake-up) filter it out. A hidden row takes no user action, and its
  thread is refreshed in the folder it showed in before.
- **Clean-up rule.** A row that is `srv_gone` and has no pending, in-flight, stuck or
  acked change is deleted (`cleanUpGone`, after every absence write and at the start of
  every flush); its body and attachments go with it. A row with such a change stays until
  the change settles: sync never deletes a row the user has a change for (#1239), and
  logs it (warn `email.server_gone_with_changes`; not when the only change is the
  user's own delete for good). A `failed` change stays listed without its row
  (`pending_change.row_removed` when the flush cleans the row up).
- **Force resync: mark and sweep** (#1236, phase 6a). A force resync of the account or
  of one folder deletes no row up front. It forgets the sync checkpoints (an IMAP one
  keeps its UIDVALIDITY with a "full fetch" mark, so a UIDVALIDITY the server changed
  meanwhile still marks the folder's rows gone; on JMAP each folder gets a full sync
  due, and the account resync forgets the `Mailbox` state), so the next sync of each
  folder is a complete refetch: every cached row it finds is written again through the
  gate and keeps its id, body and attachments. A row counts as found only under the
  folder's current UIDVALIDITY, and the fetch does not take over an unstamped row
  whose UID now holds a mail with another Message-ID. Then the folder is swept: a row the refetch's enumeration did not list
  (IMAP: the full fetch's `UID SEARCH ALL`, which now ends with the deletion reconcile;
  JMAP: the full sync's prune when its enumeration was complete) is marked gone, and
  deleted by the clean-up rule unless the user has a change of it. A row a read or ack
  wrote after the enumeration started is not swept. The folder listing sweeps folders
  the same way. Rows recorded in a folder the account no longer has are swept once the
  listing after the clear succeeded (skipped, App Log info `sync.resync_sweep_skipped`,
  when no folder of the account is known from the server). Gmail's All Mail, which the
  account resync does not refetch (#691), is not swept by it; an explicit resync of
  All Mail sweeps it. App Log warn `sync.resync_swept` lists what a sweep removed. A
  refetch that fails part-way removes nothing. The v77 upgrade deletes the bodies and
  attachment rows that resyncs before 6a left without a mail.
- **Location reads.** IMAP: the new-mail FETCH (a new row with the read's folder, an
  existing one confirmed there), the deletion reconcile's `UID SEARCH ALL` (rows of the
  folder by `srv_mailbox_path` confirmed present or marked gone), the move's answer
  (`relocate`: COPYUID or Message-ID search). JMAP: `Email/get` (`mailboxIds`: the
  recorded mailbox while it is still a member, else the one shown, the one synced, any),
  `Email/query` prune, `notFound`, `destroyed`. Each takes its sequence before the
  request and writes only rows whose `srv_location_seq` is not newer.
- **Ack.** Moves and deletes are acked like read/star changes (they used to be deleted
  when applied): what the server confirmed is written at once, stamped with the ack
  (the JMAP move's mailbox, a delete's gone state; an IMAP move's new UID and folder
  just before), and the change keeps folding until a read after the ack confirms it.
  A change with keyword and folder columns (a snooze) waits for both. Absence after
  the ack settles every acked change of the row; a move dropped that way logs
  `op.gone` (warn).
- **Appear side of carry-over** (phase 4b). An acked move, snooze or unsnooze whose new
  location the server never named (no COPYUID, no Message-ID match), and that is the
  row's newest move or delete, is not dropped when its source no longer lists the
  mail: the row is marked gone but keeps showing
  in the destination, and the change waits there (`lease_until` = now + 1 hour) for
  the destination's sync. When that sync stores a new row with the same Message-ID
  and exactly one row of the account waits for it in that folder, the waiting row
  takes the new row's place in place (it keeps its id; the new row is merged into it;
  App Log warn `email.local_row_matched`, kind `moved`) and the move is confirmed.
  When the destination's copy is stored already (that folder synced first), the
  row carries over at once, so the mail never shows twice. A sync of the destination
  that started after the wait began and did not store the mail ends the wait
  (another client moved it on or deleted it), as does the end of the hour; both
  run after a folder sync. An ended wait resolves as satisfied (`op.gone`), the row
  is hidden and cleaned up, and a copy stored later is a row of its own. A mail
  without a Message-ID cannot be matched and is not kept waiting.
- **UIDs of rows shown elsewhere than the server has them.** A row shown in a folder
  that is not its `srv_mailbox_path` (a queued move, a counterpart's shadow, an
  acked move waiting for its destination copy) still carries the source's UID. An
  IMAP change queued on it (star, move, delete, the wake-up's snooze cleanup) is
  marked `uidAfterMove` and finds the mail by Message-ID in the shown folder, or
  fails; it never acts on that UID there, where it may name another mail.
- **Counterpart shadows** (phase 4b, schema v74). When one server is added twice
  (IMAP and JMAP), a move, delete, snooze or unsnooze of a mail on one account gives
  the twin row of the other account a *shadow* of the queued change (`state =
  'shadow'`, `origin = 'counterpart:<id>'`): it folds, so the twin shows the change at
  once, but it is never flushed (the server message is changed once, by the
  primary), never listed and not unsynced work. It follows its primary: acked with
  the primary's `ack_seq` (and then settled by the counterpart's own reads, like any
  acked change; dropped instead when the twin is gone already), and dropped when the
  primary is cancelled (Undo), superseded, discarded or failed, in the same
  transaction where those paths re-fold, else at the start of the next flush
  (`dropOrphanedShadows`), so no shadow folds forever. A move into a folder the
  counterpart does not know yet hides the twin with a shadow `delete` carrying
  `awayFrom` (it agrees with a read that finds the mail gone or elsewhere) instead
  of deleting the row. The mirroring takes the latest change queued on the source
  row as the primary; when the action queued nothing (the mail is in the destination
  already), nothing is mirrored. A shadowed action writes no App Log line for the
  twin and does not clear its local-only snooze source. An acked shadow move waits
  for the destination copy like an own one, so an IMAP twin keeps its id. Changes
  mirrored before v74 are real changes and flush as before; an Undo stored before
  the upgrade whose twin change was sent no longer reverses the twin.
- **Unread counts** (phase 4b, §7 of SYNC-REDESIGN.md). The stored count is the
  server's (IMAP `STATUS`, JMAP `unreadEmails`), with the read sequence taken before
  that read (`mailboxes.unread_seq`, v74). The count shown (`observeMailboxes`) adds
  the change the count does not reflect: over the rows with a pending, in-flight,
  stuck, parked or shadow change, or one acked after `unread_seq`, the unread rows
  shown in the folder minus the unread rows the server has there as last read
  (`srv_*`; virtual rows left out). A read/unread change, and a move, delete or
  snooze of unread mail, count at once and once; a count read after the ack does
  not count them again. The v74 upgrade stamps the stored counts with the current
  read sequence. Limits: `srv_*` is the server's state as last read, not as of the
  count, so a row read again after the count no longer adjusts it until the next
  count read; a row with changes on both sides of the count's read can be off by
  one. A negative sum shows 0 and logs `mailbox.unread_negative` once per folder.

- **Email state writer.** The writer of the `emails` table (phase 3b): besides the
  overlays it deletes rows (`deleteRow`, `cleanUpGone`), inserts and updates the rows of
  server copies (`insertServerRow`, `writeServerHeaders`, phase 6a: the IMAP fetch and
  the JMAP upsert, with a `ServerRowHeaders` value that names no column;
  `writeServerHeaders` writes only the row at the location the headers name),
  restores a row for Undo (`restoreRow`, its local-only attributes in a separate
  `RestoredLocalFields`), fills header backfills (`writeHeaders`, `writeSizes`), records server location facts
  (`relocate`, `releaseLocation`, and `renameFolder`, which only the mailbox
  state writer calls, §6b), the local-only
  `snoozed_from_mailbox_path` (`writeSnoozedFrom`) and does the foreign-move
  carry-over (`takeOverRow`, a whole-row copy followed by a re-fold).
  `scripts/check_email_writes.sh` (in `check-layers`, run by `check-fast`, with
  fixture tests in `scripts/test_check_email_writes.sh`) enforces it. Any write of
  `is_seen`, `is_flagged`, `snoozed_until`, their `srv_`/`local_` columns,
  `srv_keywords_seq`, `mailbox_path`, `srv_mailbox_path`, `local_mailbox_path`,
  `local_hidden`, `srv_gone` or `srv_location_seq` outside the writer and the
  migrations (the members of `database.dart` that write `emails` while upgrading)
  fails, with no exception: an `EmailsCompanion`/`.insert`/`.custom` naming one
  (`mailboxPath` excepted in `.insert`, where Drift requires it), `srvIsSeen:
  Value(…)` and the like, SQL in any letter case (`UPDATE [OR …] emails … SET`,
  quoted columns, `INSERT INTO emails (…)` with one or without a column list, the
  table also interpolated), and in the members allowed to write `emails` a whole-row
  `toCompanion`, a `copyWith` naming one, or an insert/write whose argument is not an
  `EmailsCompanion(…)` literal, `newRow(…)`/`withServerLocation(…)` or a variable
  holding one (an upsert of an `EmailsCompanion.insert` would write the shown folder
  over a pending move); `newRow`/`withServerLocation` only in a plain `.insert(…)`
  without `mode:`/`onConflict:`, and no `replace`. SQL split over adjacent string
  literals is read joined. Any other write of `emails` (companions, Drift
  `update`/`into`/`delete`/`insert`/`replace`, the table managers,
  `updates: {…emails…}`, raw SQL, and any other bare reference to the table outside
  reads, which catches aliases) must be in the writer, the migrations, or a member on
  the script's allow-list, which names file, method and reason. The allow-list is
  empty since phase 6a (the fixture tests supply their own through
  `EMAIL_WRITES_ALLOWED`, honoured only with `CHECK_EMAIL_WRITES_FIXTURES=1`); an
  entry that no longer matches a write fails too. Check 4 keeps `restoreRow` and
  `RestoredLocalFields` in Undo's `_restoreEmail`. Members are found by indentation; fields, getters,
  annotations and signatures over two lines end the member above them.
  The same script's check 3 (schema v75) keeps every write of `mailboxes` in the
  mailbox state writer and the migrations (§6b), with no allow-list.
- **Built-in consistency checks.** `EmailStateWriter.consistencyProblems` lists the
  rows whose effective column is not `COALESCE(local_*, srv_*)` (for `mailbox_path`:
  `''` when hidden or gone), whose `local_*` is not the fold of the row's foldable
  changes (so a row without any has all `local_*` NULL and `local_hidden` false),
  that have no `srv_mailbox_path`, or that have a shadow change whose primary is gone
  or failed (`shadow`; the repair drops it). Tests and the fuzzes assert it is empty. The app runs a sample of
  it after a sync run (`OverlayConsistencySampler`, its own provider in `di.dart`,
  all builds): at most once per 30 minutes per account (the last check is kept in
  memory and in `sync_states` as `Overlay:ConsistencyCheck`, so restarts, the
  background isolate and repository rebuilds keep the interval), on the rows with
  the 200 most recent foldable changes plus 200 of the account's rows in `rowid`
  order from a random start within the account's `rowid` range, in one read
  transaction (a few ms). Each broken row is logged first, App Log error
  `overlay.inconsistent` with the row id and in `data` the mismatching fields, the
  effective, `srv_` and `local_` values, the fold and the changes (the first 10 rows
  one line each, the rest in one line with the total), and then repaired by
  re-folding it (the log line says so); rows whose shown value changed get their
  thread aggregate refreshed. The bug stays visible, and the user does not look at
  a wrong state until the row's next server read. The check is awaited at the end
  of the sync: it is bounded, and the background isolate may end as soon as the
  sync returns. A failing check logs `overlay.check_failed` (warn) and never fails
  the sync.

- **Fold.** `local_*` is computed from the row's changes in `pending`, `inflight`,
  `stuck`, `acked`, `parked` and `shadow` state, in queue order, the newest winning
  per field
  (`foldKeywords`, `lib/data/db/keyword_fold.dart`): `flag_seen`, `flag_flagged`,
  `snooze` (its time), `unsnooze`, `clear_snooze` and a `move` that ends a snooze
  ("not snoozed"). It runs in the transaction of whatever changes the row's queued
  changes: queueing, cancelling (Undo), discarding, retrying, failing, acking and
  dropping. A `failed` change does not fold, so the mail shows the server's state.
- **Server-write gate.** Every server read takes the next value of a persistent read
  sequence (`sync_read_seq`, one row) right before its request (IMAP `UID FETCH`,
  JMAP `Email/get`) and writes `srv_*` of a row only if no read that started later
  already wrote them (`srv_keywords_seq`), so a slow, stale answer is ignored row by
  row. The stamp is in the database, so the background isolate and `BodyCacheService`
  obey it too. The new-mail FETCH, the CONDSTORE refresh, the 15-minute flag
  reconcile (IMAP `FLAGS` including the `snz:` keyword; JMAP `keywords`) and the JMAP
  upsert write through it; size and header backfills and body fetches do not.
- **Ack.** A change that writes one of these fields is not deleted when the server
  applies it but `acked`, with `ack_seq` = the next read sequence: it keeps folding,
  so the answer of a read that started before the ack cannot show the old value again.
  The first read started after the ack that agrees drops it. One that contradicts it
  (a server whose reads lag its writes, or another client changed it since) is noted
  and makes the folder's flag reconcile due for the next sync run; a contradicting
  read of a later run drops it and logs `op.contradicted` (warn): from then on the
  server's value shows. Two reads of one run (the CONDSTORE refresh and the reconcile
  right after it) count once. An acked change a newer change of the same field
  shadows is dropped at its ack or at the next read, without a log line. Acked changes are not shown
  as pending anywhere; those of a row that no longer exists are deleted at the start
  of the next flush.
- **Rows without a server copy** (a local virtual row, §8a, or a JMAP mail whose
  server id is unknown) get `parked` changes (phase 4b): they fold like pending ones
  but are not flushed; their `srv_*` columns are never written for the user's
  change. When the server copy is stored, it fills the row in place (§8a; for a JMAP
  row without a server id: a new row of the same folder and Message-ID, a unique
  match only) and the parked changes become `pending`, rewritten to address the mail
  where the server has it. A parked change still waiting after 7 days becomes
  `failed` (`pending_change.parked_expired`, warn) and stops folding; Retry parks it
  again while the mail has no server copy.
- **Undo's restore** of a row sync cleaned up stores its snapshot as `srv_*` (folder
  included) with stamp 0 and makes the flag reconcile due (the snapshot may show a
  pending value); a row that still exists (also a hidden one) keeps its state and is
  only re-folded.
- The v73 upgrade recorded a server folder for every row (JMAP rows, virtual rows and
  rows whose location another took over had none) and folded the queued moves,
  snoozes, unsnoozes and deletes into `local_mailbox_path` / `local_hidden`.
- The v72 upgrade copied each row's values into `srv_*`, folded the queued changes
  into `local_*`, and made the flag reconcile due for the folders of rows with queued
  read/star/snooze changes, whose stored value was the user's, not the server's.

## 6b. Mailbox ops: folders created, renamed, moved and deleted offline

Schema v75 and v76, SYNC-REDESIGN.md §7 (phases 5a and 5b, #1242). Creating,
renaming, moving and deleting a folder work offline like any mail change: the
folder shows (or hides) at once, and the change is a queued op in
`pending_changes` (`resource_type = 'Mailbox'`, `resource_id` the
`mailboxes.id`), flushed with the same claim, lease, outcomes and states
(`pending`, `inflight`, `acked`, `stuck`, `failed`) as a mail change. Deleting a
folder created offline only gives up its creation. Moves and deletes are
described under "Move and delete (5b)" below.

| Column of `mailboxes` | Written by | Meaning |
|--------|------------|---------|
| `srv_name` | sync's folder listings, acks | the name the server last gave; NULL while the folder has no server copy |
| `local_name` | the fold | the name of the folder's latest foldable `create_mailbox` / `rename_mailbox` |
| `name` | together with either | `COALESCE(local_name, srv_name)` |
| `is_local` | create, listings, acks | created offline, no server copy yet |
| `srv_seq` | listings, acks | the read sequence that last wrote `srv_name` (and the JMAP `parent_id`); an older listing does not write it |
| `local_parent` | the fold (v76) | the new parent's `path` of the folder's latest foldable `move_mailbox` (`''`: top level); NULL: none |
| `local_hidden` | the fold (v76) | a foldable `delete_mailbox`: the folder shows nowhere |
| `parent_id` | listings, acks, creates | JMAP: the server's parent; the parent shown is `local_parent` when set, else this (`effectiveMailboxParent`) |
| `display_path` | derived | the tree path from the effective names (JMAP: the `parentId` chain; IMAP: the server path with the leaf of a renamed folder replaced, also inside its subfolders' paths) |

All of `mailboxes` is written by the mailbox state writer
(`lib/data/repositories/mailbox_state_writer.dart`); `check_email_writes.sh` check 3
enforces it. Mailbox ids are frozen: an acked rename or a create's new server id
changes the row's `path`, never its id; sync finds rows by `path`.

- **Create.** `createMailbox` / `createMailboxWithRole` insert a local row per level
  of the name that is not cached (`Projects/2026` is two), each with a queued
  `create_mailbox` op (payload: `name`, `parent` path, `role`). The row's `path` is a
  stand-in until the server's: on IMAP the path the folder will most likely get (the
  parent's path, the separator the account's paths use, the name), on JMAP
  `~new:<random>` (not in the JMAP id alphabet). A name already shown at that level
  is refused at once (`MailboxExistsException`).
- **Rename.** `renameMailbox` queues a `rename_mailbox` op (payload: the new leaf
  `name`); the folder shows the new name at once (`local_name`), on IMAP also in the
  display path of its subfolders. A newer rename replaces a queued (unclaimed) or
  failed one; renaming back to the server's name with nothing sent queues nothing.
- **Flush.** At the start of every flush, before the account's mail changes
  (`_flushMailboxOps`, `flush_mailbox.dart`), in queue order. IMAP: `CREATE` (the
  separator from the parent's path or the server's LIST), `RENAME` (the full new
  path). JMAP: `Mailbox/set` `create` (with `parentId`, and `role`; a role the server
  refuses, such as `snoozed` on Stalwart, is left out) and `update {name}`. An op of a
  folder, or with a parent, that has no server copy yet waits (uncharged). Outcomes:
  - *satisfied*: the folder was listed meanwhile (another client made it, or the
    folder of a role-create exists: a role-create first looks it up by role, then by
    name), or an earlier try that may have been sent is found done (a lookup before
    acting when the op has attempts);
  - *refused* → `failed`: a JMAP `notCreated`/`notUpdated` SetError (worded by
    `jmapMailboxSetErrorText`, the server's description appended), an IMAP `NO` with a
    permanent code, a name the server has already on the first try (a clash: never
    adopted), a folder gone on the server; App Log error `pending_change.rejected`;
  - *transient* → retried, `stuck` after 5 attempts; *not sent* (connect failed) →
    nothing charged; *ambiguous* (connection lost after sending) → kept, maybe sent.
- **Ack.** `acked` with `ack_seq`, and what the server confirmed written at once,
  stamped `srv_seq = ack_seq`: `srv_name`, `is_local = 0`, and the server's path when
  it differs from the row's (a JMAP create's id, an IMAP create whose separator was
  guessed wrong, an IMAP rename, which moves its subfolders too):
  `MailboxStateWriter.serverPathChanged` moves the row's `path` (keeping its id), the
  JMAP children's `parentId`, the queued creates naming it as parent, the threads and
  the IMAP checkpoints, and calls `EmailStateWriter.renameFolder`: the server folder
  of its mail (`srv_mailbox_path`, a server fact), the queued mail changes naming the
  folder (`dest`, `src`, `mailboxPath`, `prevSnoozedFrom`) and Undo actions follow,
  and the rows of those changes are re-folded, so a pending move into the folder
  shows it under its new path through the fold (no direct write of
  `local_mailbox_path`); App Log warn `pending_change.folder_renamed`. A row sync
  stored for that path already is merged into (`mailbox.local_merged`, warn). The
  acked op keeps folding until a folder listing started after the ack names the
  folder: agreeing, it is dropped; contradicting, it is dropped by the second such
  listing with `op.contradicted` (warn), and the server's name shows.
- **Listings** (`syncMailboxes`, the server-write gate of mailboxes) take a read
  sequence before LIST / `Mailbox/get` / `Mailbox/changes`. They write `srv_name`
  only when no later read or ack wrote it, set `is_local = 0` for a folder they list,
  never remove a folder created offline or one written after the listing started (a
  folder just created or renamed), and do not store again a path an IMAP rename acked
  after the listing started moved away from (the payload's `fromPath`). A folder the
  server no longer lists is removed (`removeLocalMailbox`): its queued folder ops and
  the changes naming it become `failed` (`folder removed on the server`, App Log warn
  `pending_change.folder_removed`), never dropped.
- **Mail changes that need a folder created offline.** A move, snooze or other mail
  change naming a folder without a server copy (`is_local`) waits in the flush,
  uncharged, with the mail's later changes; the create's ack names the server's path
  in it and the next step of the same flush sends it. When the create fails, is
  discarded, or is gone, the changes waiting for it (and creates of its subfolders,
  and renames of it) fail with it, naming the folder (`pending_change.folder_not_created`,
  warn); their mails show where the server has them again. A failed create hides
  the folder (`observeMailboxes`, `findMailboxByRole`); Retry queues it again and it
  shows again; Discard removes it.
- **The Snoozed folder on JMAP.** A snooze on a JMAP account whose Snoozed folder is
  not known queues a `create_mailbox` (name and stand-in path `Snoozed`, role
  `snoozed`) for it, and the snooze waits for it; the create finds a Snoozed folder
  the server has (by role, then by name) or makes one. The flush no longer resolves
  the stand-in itself. The v75 upgrade queues that create for each JMAP account with
  a queued snooze into the stand-in.
- **Review fixes (5a).**
  - A folder created offline is never synced (the sync loop and `syncEmails` skip
    it: no SELECT or `Email/query` of its stand-in) and `removeLocalMailbox`
    refuses it, so a create that is not confirmed yet (a transient error, stuck,
    being sent by another isolate, waiting for its parent) cannot be taken for a
    folder deleted on the server.
  - The IMAP hierarchy separator comes from LIST only (`imapSeparatorOf`, recorded
    per account in `sync_states` as `Mailbox:ImapSeparator`): subfolder paths,
    display paths and the subfolders a rename moves go by it, so on a `/` server
    "Work.old" is no subfolder of "Work".
  - A rename that may have reached the server (attempts, or being sent) protects
    its folder from the prune; a listing that shows the new path and not the old
    one completes it (`completeLostRenames`, App Log warn
    `mailbox.rename_found_done`). A newer rename replaces only a never-sent one.
    A listing skips paths below a path an acked rename moved away from, and a
    rename's ack carries the old paths of the acked renames it replaces.
  - A listing does not take over a folder created offline whose create was never
    sent: the create's flush reports the clash. A create found done by a read of
    the server (a lost answer, a role folder) is dropped by the next listing
    (`readConfirmed`), as JMAP `Mailbox/changes` does not name an unchanged folder.
  - A create's ack keeps its stand-in path (`localPath`); a mail change that still
    names it (queued from a screen opened before the ack, or the Snoozed race) is
    pointed at the server's folder at enqueue and in the flush; a `~new:` path no
    folder had fails the change. A mail change naming a folder whose rename is being
    sent waits, and a rename waits while a mail change naming the folder is being
    sent elsewhere.
  - A removed folder fails the creates queued below it (and what waits for them),
    and its acked ops go with its row. A user's delete says "deleted".
    Retry of a failed create queues the changes that failed with it again; a retry
    without a folder, a discarded create that may have been sent, and a queued
    create re-pointed to a new parent path are logged. The counterpart mirroring
    never targets a folder without a server copy.
- **Move and delete (5b, schema v76).**
  - *Move.* `moveMailbox` queues a `move_mailbox` op (payload: the new
    parent's `path`, `parent`, NULL for the top level, and the parent it showed
    below, `fromParent`, for Undo); the folder and its subfolders show below the
    new parent at once (`local_parent`; on IMAP the display paths of the folder
    and its subfolders, on JMAP the effective `parentId`). A newer move replaces
    a never-sent one; moving back below the server's parent with nothing sent
    queues nothing. Flush: IMAP `RENAME` to the new parent's path plus the leaf
    (the separator from LIST), JMAP `Mailbox/set` `update {parentId}`. A folder,
    or a new parent, created offline makes the move wait for its create (whose
    ack names the server's path in the move); a parent that is being deleted,
    or a `~new:` stand-in no folder has, refuses it. The ack works like a
    rename's: on IMAP `serverPathChanged` moves the row, its subfolders, their
    mail and the queued changes naming them, and records `fromPath`; on JMAP it
    writes the server's `parent_id`. The next listing settles it (the parent
    agrees, or is contradicted twice).
  - *Delete.* `deleteMailbox` queues a `delete_mailbox` op (payload:
    `removeEmails`, the user's yes to deleting the mail it has); the folder is
    hidden at once everywhere (`local_hidden`: folder list, counts, Move-to
    and move pickers, `findMailboxByRole`, the counterpart lookup, sync
    statistics, Sieve's JMAP folder lookup, the sync loop and `syncEmails`). A
    folder with a subfolder that shows is refused at once (delete those first).
    Flush: it waits while a mail change queued before it names the folder or a
    subfolder (pending, being sent or stuck), or while an op of a subfolder
    queued before it is not done; the flush runs the waiting deletes again
    after the mail changes, so one flush moves the mail out and then deletes
    the folder. IMAP: a folder the LIST no longer has is done; one with
    subfolders on the server is refused; without `removeEmails` a STATUS with
    messages refuses it (the mail stays, the folder shows again); else `DELETE`.
    JMAP: `Mailbox/set destroy` (with `onDestroyRemoveEmails` only with the
    user's yes); `notFound` is done, any other SetError refuses it
    (`mailboxHasEmail`, `mailboxHasChild`). The ack (`ackDelete`) keeps the op,
    `acked`, with `fromPath`, then `removeLocalMailbox(deletedByUser: true)`
    removes the cache as an online delete did: queued changes still naming the
    folder fail ("folder deleted", listed), its mail is marked gone (kept while
    a change of it is unsettled). The kept op stops a listing that started
    before the ack from bringing the folder back (IMAP and JMAP full
    `Mailbox/get`), and the next listing drops it (`settleAckedDeletes`).
  - *Mail changes and a folder being deleted.* The mail of a folder whose
    delete is queued shows nowhere either (search, by address, by thread, by
    id: `_visible` checks `local_hidden`). A mail change queued after the
    delete that moves mail INTO the folder (`dest`: an Undo's move back, a
    Sieve `fileinto`) waits while the delete is queued, being sent or stuck:
    sent first, its mail would be deleted with the folder. Once the delete is
    done it fails, listed; when the delete fails it is sent. A change that
    takes mail OUT of the folder (`src` / `mailboxPath`, whenever queued) is
    sent first, and the delete waits for it, as it does for a counterpart's
    shadow move out of the folder whose primary is not done yet.
  - *Mail the user did not see.* A delete with `removeEmails` records how many
    mails the user agreed to delete (`messages`: the server's count plus the
    mails moved in locally); a server with more (STATUS on IMAP, `totalEmails`
    on JMAP) refuses it (`mailbox.delete_new_mail`, warn; the folder shows
    again). Retry of a failed delete asks the server without deleting mail
    (`removeEmails` false); deleting it again asks the user again.
  - *A folder gone on the server* while its delete is queued: the delete is
    done (`mailbox.delete_found_done`, warn), not failed. Moves into a removed
    folder fail with it (on IMAP a RENAME into it would bring it back).
  - *Undo.* The snackbar of a folder move or delete offers Undo
    (`undoFolderChange`): an op not sent yet is cancelled; a move that may have
    reached the server is followed by a move back (`fromParent`); a delete that
    is being sent or may have reached the server cannot be undone ("Too late",
    worded for each case in the App Log). Discard and
    Retry act on failed moves and deletes like on any folder op (Retry of a
    delete hides the folder again).
  - *In-flight races.* A rename, move or delete waits while a mail change
    naming the folder or (IMAP) a subfolder is being sent by another flush;
    mail changes naming a folder (or IMAP subfolder) whose rename, move or
    delete is being sent wait. A listing does not prune a folder, nor (IMAP)
    its subfolders, while a rename or move of it may have reached the server
    (being sent, or sent without an answer), nor a folder whose delete is being
    sent; a lost IMAP move whose result the listing shows is completed like a
    lost rename. Both sides check again after their claim (a mail flush that
    claimed a change naming a folder being renamed, moved or deleted releases
    it; a folder flush that claimed its op while a mail change naming the
    folder is being sent releases it), so the two are never sent at once.
    The IMAP "source folder gone" outcome that drops a change as done is a
    warn now (`pending_change.skipped_gone`).
  - *No folder comes back by a move.* An IMAP RENAME creates missing parents,
    so a move into a parent the server does not list (deleted elsewhere, an
    Undo's old parent) is refused, and a move waits while its parent's own
    rename or move may have reached the server.
  - *A folder another client renamed or moved (IMAP).* IMAP has no folder ids,
    so a rename elsewhere lists as a folder gone plus a new one. Before the
    prune, a vanished folder without a queued delete (that one is never
    followed: its delete counts as done) is taken for renamed to a new folder
    that shares its leaf (a move) or its parent (a rename) with it, when the
    match is unique both ways and the new folder either has the UIDVALIDITY
    of its sync checkpoint (STATUS; RFC 3501 servers that keep it across
    RENAME) and holds its cached Message-IDs, or, as Stalwart gives a renamed
    folder a new UIDVALIDITY, holds every Message-ID cached for it (up to 50,
    `UID SEARCH HEADER Message-ID`) with exactly as many messages as are
    cached. `serverPathChanged` then moves the row
    (its id stays), its subfolders, its mail and the queued changes naming it
    (App Log warn `mailbox.renamed_elsewhere`, saying which rule matched).
    Otherwise (an empty or never-synced folder under a new UIDVALIDITY, two
    candidates, a rename and a move at once) the queued changes fail visibly
    as "folder removed on the server". JMAP renames keep the id and need none
    of this.
  - *The Snoozed folder on IMAP.* A snooze without a known Snoozed folder
    queues its `create_mailbox` (role `snoozed`) and waits for it, as on JMAP;
    the snooze and unsnooze flush no longer `CREATE` folders on the side (an
    unsnooze into a folder that is gone fails, listed, instead of bringing it
    back). The v76 upgrade queues that create for each IMAP account with a
    snooze queued into a `Snoozed` path no mailbox has (App Log warn
    `migration.snoozed_folder_queued`). The Snoozed and Trash lookups skip a
    folder being deleted.
  - *Counterparts.* When an account's move puts a shared mail into a folder its
    counterpart account (the same server over the other protocol) does not
    know, the twin no longer is hidden by a shadow `delete`: the counterpart
    gets a stand-in folder (a local row whose `create_mailbox` is a shadow of
    the move: never sent, folded, dropped with the move) and the twin a shadow
    move into it, so it shows there, parked on the folder's creation. The
    counterpart's listing adopts the stand-in when it lists the folder (by
    path, or by name and JMAP parent: `serverPathChanged` moves the twin's
    shadow along; App Log warn `mailbox.counterpart_folder_adopted`). Each
    move that needs the stand-in adds its own shadow create, so it stays
    while any of them is live; a stand-in whose moves all ended, or that a
    listing started after the moves' ack does not find, is dropped
    (`mailbox.counterpart_folder_dropped`).
  - *Waiting for a folder.* The Pending Changes screen says "waiting for folder
    "X" to be created" for a change that names a folder created offline
    (`PendingChange.waitingForFolder`, derived when read). The change stays
    `pending`: the flush holds it (as in 5a), no `parked` state with promotion.
  - The consistency check (`MailboxStateWriter.consistencyProblems`) also
    compares `local_parent` and `local_hidden` with the fold, and allows the
    acked delete kept without its folder.
- **Pending Changes screen** lists folder ops ("Create folder "X"", "Rename folder to
  "Y""); Retry and Discard act on them as above. `MailboxStateWriter.consistencyProblems`
  (`local_name` = the fold, `name` = `COALESCE(local_name, srv_name)`, a local row has
  a create op, no unfailed op without its folder) runs in tests and with the sampled
  overlay check after a sync run (all of an account's mailboxes; logged
  `overlay.inconsistent` and repaired by a re-fold).

---

## 7. Undo and cancel

When the user triggers an undoable action the UI calls:
```
ref.read(undoServiceProvider.notifier).pushAction(UndoAction(...))
```

`UndoService` persists the action to the `undo_actions` table (max 10 entries, FIFO).
A `SnackBar` with an **Undo** button appears for a few seconds.

When the user taps Undo, `UndoService.undo()` executes this sequence for each affected email:

The UI applies the action inside `EmailRepository.captureOps`, which records the
`pending_changes` ids it queued per email; the `UndoAction` stores them (`opSeqs`).

```
1. cancelOps(opSeqs[id])
      └─ Deletes exactly the action's queued changes if nothing was sent for
         them yet (`state = 'pending'` or `'parked'`, `attempts = 0`). The action counts as
         cancelled only if all of them were; an id that is gone (applied,
         superseded, discarded, or retried after failing, which queues a
         fresh row), claimed by a flush (`inflight`) or may have reached the
         server is not. An email the action queued nothing for (a local-only
         mail) counts as cancelled. The shadows of these changes on a
         counterpart in a paired account go with them (§6a). An action stored before the ids were
         recorded falls back to cancelPendingChange(id, 'delete' | 'move' |
         'snooze'), the latest queued change of that type.

      Cancelling is enough to put the mail back: the folder (and a delete
      for good's hiding) is the fold of the queued changes (§6a); the
      folder it was snoozed from comes back from the cancelled payload.

2. If the email row is gone (the server confirmed a delete and the
   clean-up rule removed it, or it was merged away):
      restoreEmails([original])
         └─ Re-inserts the row with its pre-deletion state,
            placed in the correct mailbox (source if cancelled, dest otherwise).
            A row that is still there, hidden or not, is only re-folded.

3. moveEmail(id, sourceMailboxPath)
      └─ Optimistic local move back to the original folder.
         If step 1 returned false (already sent to server), this enqueues
         a reverse-move in pending_changes so the server move is undone too.

4. If step 1 cancelled the action:
      cancelOps(<ids step 3 queued>)
         └─ The reverse-move from step 3 is redundant; remove exactly it
            (usually there is none: the mail was back in place already).
            Its shadows on a counterpart go with it.
```

The net result is: if the mutation was still in the queue it is silently cancelled with no
server round-trip; if it had already been flushed, a compensating move is queued.

---

## 8. Key invariants

- **Order**: pending changes are flushed before syncing. This prevents the server from
  overwriting an optimistic local state that the server hasn't seen yet.
- **Idempotency**: `flushPendingChanges` is safe to call multiple times. Each row is
  acked or deleted only after the server acknowledges the change.
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
  arrival had nothing to match. Check and insert run in one transaction, and a
  note that already exists for the Message-ID is kept, so a repeated send never resets
  the user's edits. The Sent-folder copy of a send without `APPENDUID` (#918) is a
  virtual row as well, marked `is_virtual_sent_copy`, so the two are never matched with
  each other's arrival.
- **Best-effort**: a failure to write the row is logged, never rethrown — the message is
  already sent and must not be sent again.

- **Inserted by the state writer** (`insertLocalRow`, the `create_local` step): its own
  folder and read/star state are stored as `srv_*` with stamp 0, once; no read ever
  writes a virtual row afterwards.
- **Absence rules**: local rows have no server copy, so no absence applies to them: the
  deletion reconcile, the JMAP prune, `notFound`/`destroyed` and a removed folder
  (`markFolderGone`) only touch rows with a server location (`is_local = 0`, a recorded
  UID or JMAP id). A virtual row ends only by the match below or by its expiry.
- **Parked changes**: a user change of a virtual row (star, read, move, snooze, delete) is
  queued as a `parked` change (§6, §6a): it folds, so the row shows it, but it is not
  flushed; Undo cancels it like a pending one. A delete for good hides the row (it is
  not deleted), so the delivered mail is deleted too once it arrives — but only when
  it arrives in the inbox or in the folder the note was deleted from; one a server
  filter filed elsewhere (Junk, Gmail's All Mail) is not deleted for good: the
  delete fails and the mail shows. Retry of a parked change that expired is
  rewritten for the server copy, waits again without one, and stays failed when the
  row is gone.
- **Matched in place on arrival** (`_matchArrival`): when sync stores the real message,
  it is paired with the virtual row by Message-ID and role (a Sent-folder arrival only
  with the virtual Sent copy, any other arrival, also one a server-side filter filed
  elsewhere, with the note), unique matches only. The virtual row keeps its id (the
  open detail view, notes, Undo and notifications keep working) and takes the stored
  row's server facts and headers (`takeOverRow`); the stored row is merged into it
  (`_mergeDuplicateRow`), its body replacing the draft text. The parked changes become
  `pending`, rewritten for the server copy (UID, folder, UIDVALIDITY, JMAP id; a later
  change addresses the mail where the change before it puts it), and are flushed. App
  Log warn `email.local_row_matched` names both rows. The match re-checks in its
  transaction that the row still waits, so it never happens twice. A parked move
  into the folder the mail arrived in is dropped. Notes need no migration — they
  are keyed by Message-ID.
- **Expiry**: a virtual row whose server copy did not arrive within 7 days is dropped
  right after a successful sync of the folder it would arrive in (a note: the inbox;
  a Sent copy: Sent), never before it, so a week offline does not drop a note whose
  copy the next sync stores (App Log warn `email.virtual_expired`, with its id and
  Message-ID), and its parked changes become `failed`, listed on the Pending Changes
  screen.

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
`task check-fast` on seeds 1–30 (no network; about 15 s on its own, more under the
`--coverage` run of check-fast). The nightly `task stale-fuzz`
(`.github/workflows/fuzz-nightly.yml`, Dagger `stale-fuzz`) runs another 200 seeds,
a window that moves every day (`STALE_FUZZ_FIRST_SEED`). It drives the real
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
of fixed ones (#1266–#1271, #1276) run. It also checks the read/star/snooze overlay
(§6a): `consistencyProblems()` is empty, so every row's shown value is
`COALESCE(local_*, srv_*)` and `local_*` is the fold of its queued changes. The
nightly chaos monkey and the long-term IMAP/JMAP fuzz (Stalwart) assert the same at
their checkpoints.
Longer or focused runs (locally, with a
Flutter SDK):

```
STALE_FUZZ_SEEDS=500 flutter test test/unit/stale_answer_fuzz_test.dart
STALE_FUZZ_FIRST_SEED=1000 STALE_FUZZ_SEEDS=200 flutter test test/unit/stale_answer_fuzz_test.dart
STALE_FUZZ_SEED=17,42 STALE_FUZZ_VERBOSE=1 flutter test test/unit/stale_answer_fuzz_test.dart
STALE_FUZZ_KNOWN_BUGS=1 flutter test test/unit/stale_answer_fuzz_test.dart  # run the skipped ones
```

To check how a real server behaves before relying on a semantic (rather than
fuzzing the engine), probe a throwaway Stalwart directly — see
`stalwart-dev/README.md` and `stalwart-dev/jmap_probe.py`.
