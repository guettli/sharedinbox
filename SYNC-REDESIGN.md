# Sync redesign: overlay columns + operation log

Status: **proposal, chosen direction**, not implemented. Goal: make offline-first (the rules in
`OFFLINE-FIRST.md`, PR #1249) a property of the data model instead of a rule
every sync path has to remember. This is a staged migration of the existing
sync code, not a rewrite: the IMAP/JMAP transport code and its edge-case
handling stay.

Line references are to `lib/data/repositories/email_repository_impl.dart`
(**ERI**) unless another file is named, as of `33c67b4`.

## 1. Problem

One row in `emails` holds a *merged* state: what the server last said and
what the user just did share the same columns (`isSeen`, `isFlagged`,
`mailboxPath`, `snoozedUntil`). User actions write the row and queue a
`pending_changes` entry; sync writes the same row from server answers. Every
sync path must remember to protect pending changes, and coverage is uneven:

| Sync write path | Guard today |
|---|---|
| IMAP fetch/upsert `_fetchAndUpsertImapGuarded` (1758) | flags guarded (#1234). Skips UIDs with a queued `move`/`delete` keyed on `mailboxPath` (`_pendingDeleteOrMoveUids`, 1997), so a pending **snooze/unsnooze** (payload key `src`) is not skipped: `mailboxPath` and `snoozedUntil` get overwritten |
| IMAP CONDSTORE refresh (1530), 15-min flag reconcile (1591) | flags guarded (#1234) |
| IMAP deletion reconcile `_reconcileDeletedImap` (2068) | skips `isLocal` and queued move/snooze/unsnooze; adopts foreign moves (`_adoptImapMovedRow`, 2160) |
| IMAP UIDVALIDITY reset (1310) | **none**: deletes the folder's rows. Queued payloads carry UIDs without `uidValidity` (4621), so a queued delete can hit a different message after UIDs are reused |
| JMAP `_upsertJmapEmails` (3796) | flags guarded; **`mailboxPath` and `snoozedUntil` unguarded** (#1238); row deleted when `mailboxIds` is empty (3821) |
| JMAP `_reconcileJmapFlagsForMailbox` (3683) | flags guarded |
| JMAP `Email/get` `notFound` (3302) | skips rows with a queued change other than `add_keywords` |
| JMAP `_pruneJmapMailboxToServerIds` (3541) | skips only move/snooze/unsnooze |
| JMAP `Email/changes` `destroyed` (3428) | **none** (#1239) |
| Mailbox gone `removeLocalMailbox` (`mailbox_repository_impl.dart:1399`) | **deletes the queued changes too** (#1239) |
| Mailbox rename (`mailbox_repository_impl.dart:1161`) | rewrites `emails.mailboxPath` but not ids or queued payloads |

More problems with the same root:

- **Silent drops.** A change is deleted after `_maxChangeAttempts` (5,
  `_recordChangeError` 4073), on JMAP `JmapSetItemException` (6203), on
  "message gone" (6483) and on "mailbox not found" (6501). The optimistic
  value stays. Flags self-heal through the 15-min reconcile, but a dropped
  IMAP move makes the mail **vanish locally**: the destination reconcile
  deletes the row and the source UID is at or below `lastUid`, so it is never
  fetched again.
- **Attempts are charged for network failures.** A lost IMAP connection
  charges an attempt (6478), a batch MOVE already sent charges every row
  (6353), and the generic JMAP `catch` charges any transport error (6223).
  Five flaky syncs drop a change.
- **The race guard is in memory.** `_ServerFlagRead` (#1234) lives in one
  `EmailRepositoryImpl` instance. `BodyCacheService` builds its own instance
  (`body_cache_service.dart:131`, `di.dart:665`), also in the background
  isolate, and that instance writes `emails` (body healing re-keys rows, 891;
  `_backfillAddressHeaders`, 9413) without seeing the guard.
- **Identity follows location.** An IMAP row id is `accountId:mailbox:uid`.
  A move re-keys the row and everything pointing at it (`_rekeyEmailRow`,
  985: bodies, pending changes, threads, undo, logs), and code parses ids
  (`split(':').last`, around 2469–2635).

## 2. Model

Keep **one row per message instance** in `emails`, and give each
user-changeable field three ordinary columns:

```
  srv_<field>     what the server last said; written only by the server-write gate
  local_<field>   the user's pending intent (NULL = none); written only by the fold
  <field>         the value the app reads = COALESCE(local_<field>, srv_<field>)
```

```
  sync (IMAP/JMAP) ──▶ server-write gate ──▶ srv_<field> ─┐
                                                          ├─▶ <field> ─▶ all reads
  user action ──▶ ops ──▶ fold ───────────▶ local_<field> ┘   (threads, FTS, lists, search)
```

Three writers own these columns. All of them write the effective
`<field>` in the same statement through one shared helper, the
**email state writer**. It lives in its own file, because
`mailbox_repository_impl.dart` (rename at 1161, `removeLocalMailbox` at
1404) needs it too:

- the **server-write gate**: the only way sync code may set a
  user-changeable field, including inserting a new row. It applies the
  read-order rules of §4 and writes `srv_<field>`;
- the **fold** (below): it writes `local_<field>`;
- **local row creation**: virtual self-sent rows (`_createLocalSelfMessages`
  7495, the virtual Sent copy in `_storeSentCopyLocally` 7427) have no
  server answer yet. A `create_local` step inserts them with `local_*`
  set and `srv_*` empty.

The writer sets only the columns it changes, never the whole row. Today's
`insertOnConflictUpdate` sets every column and so re-fires the FTS update
trigger (`email_fts_au` is `AFTER UPDATE OF subject, preview, from_json`,
database.dart:666). It also has a SQL bulk form for `markAllAsRead`.

Former writers that disappear: `restoreEmails` (5769) is no longer needed,
because a hidden row still exists and undo just discards or inverts the op.
`restoreLocalSnooze` (5370) becomes an op. `_repointSnoozedPlaceholder`
(7071) rewrites the `dest` of the queued ops and re-folds, instead of
writing columns.

The effective columns are ordinary columns, not SQLite generated columns.
Generated STORED columns cannot be added with `ALTER TABLE`, so they would
force a rebuild of `emails` and its FTS index on every device at upgrade,
and they would only protect against a direct write that the checks in §8
already catch. With ordinary columns the migration is `ALTER TABLE ADD
COLUMN` plus one `UPDATE` copying today's values into `srv_*`.

- **UI read paths stay the same**: lists, the `threads` aggregate
  (`_updateThread` already materialises it from the row), FTS, search,
  detail. They read the effective `<field>` columns, which keep today's
  names. The exceptions are the hidden-row filters listed below.
- **Sync scans read the server columns.** Every folder-scoped scan done for
  sync must use `srv_mailbox_path`, not the effective one: the flag
  reconcile (1625), `_reconcileDeletedImap` (2074), `_movedDestinationId`
  (2144), the JMAP prune (3546) and the JMAP flag reconcile (3691).
  Otherwise a row with a pending move looks absent from its destination's
  listing and gets marked `srv_gone`, and a hidden row is never seen to
  vanish from its source, so an acked delete is never dropped.
- **One row per message**: no second copy, no extra FTS churn, and no cascade
  hazard. `email_bodies` and `attachment_files` cascade on delete of the
  `emails` row (database.dart:155, 182); hiding a row never deletes it, so a
  pending delete or a failure revert cannot lose the offline body.
- **Cheap migration**: added columns and one copy, no table rebuild, no
  FTS rebuild.

Fields and read groups. A *read group* is the set of fields one kind of
server read returns; each group has its own read stamp (§4):

| Read group | srv / local columns | Effective column |
|---|---|---|
| `keywords` | `is_seen`, `is_flagged`, `snoozed_until` (from the `snz:` keyword) | same names |
| `location` | `mailbox_path`, plus `local_hidden` (pending delete) and `srv_gone` (server said absent) | `mailbox_path` = `''` if `local_hidden`, or if `srv_gone` and `local_mailbox_path IS NULL`; otherwise `COALESCE(local_mailbox_path, srv_mailbox_path)` |

A hidden row gets the empty string as its effective `mailbox_path` (the
column is NOT NULL today, and changing that would need a table rebuild).
No IMAP mailbox name or JMAP mailbox id is empty, so every existing
`mailbox_path = ?` query already excludes it, and no read needs an extra
`AND visible`.

Queries that do not filter by mailbox must add `mailbox_path <> ''` in
phase 4:
- **Searches:** FTS search (8765), body search (8801), notes search (8822),
  `searchEmailsStructured` (8890) and `searchAddresses` (9149).
- **Lookups by address or thread:** `getEmailsByAddress` (9104), thread
  across folders (9323), and `getEmail(id)` (503): the detail view or a
  notification tap on a hidden row should show "deleted".
- **Internal lookups:**
  - `_findEmailRowByNormalisedMessageId` (5488, counterpart mirroring)
  - `findEmailByMessageId` (5754, undo)
  - `_localRowFor` (5580)
  - `_hasArrivedOutsideSent` (7587)
  - `wakeUpEmails` (5326)
- **Folder statistics:** `sync_state_repository_impl.dart:20`, which would
  otherwise show a phantom `''` folder.

Notifications, unread counts and `observeAllInboxThreads` already filter by
mailbox.

Guards:
- `_updateThread` is never called with `''`. A move or hide refreshes the
  old folder's thread using the *previous* effective path.
- Any user action on a row whose effective `mailbox_path` is `''` does
  nothing. Otherwise an `UndoAction` could record `''` as a source folder.

**Clean-up rule:** a row that is `srv_gone` and has no ops left is deleted.
Bodies cascade only then, when nothing can bring the row back.

Server location facts that are not user-facing values get plain `srv_`
columns: `srv_uid`, `srv_uid_validity`, `srv_mailbox_ids` (full JMAP set as
JSON). Header columns (subject, size, addresses, preview, …) have no user
intent and stay as they are; any read may write them.

**Local-only attributes** have no server counterpart and are plain columns
written by user actions: `snoozed_from_mailbox_path` (the server only stores
the `snz:` keyword, 5247) and `is_local` (virtual rows, §6).

**The fold** is a pure Dart function: `fold(srvRow, ops) → local_*`. It
starts from all-NULL and applies the row's foldable ops in `seq` order.
Each op type writes an explicit set of `local_*` columns (table in §3), which
may span both read groups. It runs in the same
transaction as anything that changes the row's ops (append, state change,
drop). Sync does not call it except when it drops an acked op (§4).

Rejected alternatives:

- **Keep the merged row and only add the gate.** This is the smallest
  change, and the gate is part of this design anyway. But once the user's
  value overwrites the row, the server's value is gone, so a refused change
  cannot revert without a re-fetch, and "pending" vs "confirmed" stays
  implicit in a join against the queue.
- **A separate server-mirror table plus a materialised projection table.**
  It doubles storage, adds FTS churn and risks wiping bodies through
  cascades.
- **SQL views over ops.** The list sorts by the precomputed `threads`
  aggregate, which a view cannot keep cheap.
- **SQLite generated columns for the effective value.** They force a table
  rebuild, see above.

## 3. Operation log

`ops` is **`pending_changes` evolved in place**, never a second queue. It
keeps the one autoincrement id as `seq`, so the global order that the flush
(6150), Sieve's "flags before move" (5948) and undo depend on stays intact.
New columns:

| Column | Meaning |
|---|---|
| `state` | `pending` → `inflight` → `acked`, or `stuck` / `failed` / `parked`, see §5 |
| `columns` | derived from the type (§3 table); not stored, listed for clarity |
| `ack_seq` | read sequence taken at ack time (§4) |
| `lease_until` | for `inflight`; on start-up an expired lease becomes `ambiguous` handling (§5) |
| `origin` | `user`, `bulk:<id>`, `sieve:<run>`, `undo`, `counterpart:<seq>` — for UI grouping and linked ops |
| `attempts`, `last_error` | as today, but `attempts` is no longer the claim marker (`_claimPendingChange`, 5162); `state` is |

**Ops never carry UIDs or mailbox paths of the source.** The flush resolves
the target's current server location from `srv_uid`, `srv_uid_validity`,
`srv_mailbox_path` / `srv_mailbox_ids` and refuses to act if `uidValidity`
changed. This removes `_rewritePendingChangeUids` (1064) and the
UID-reuse hazard.

Types and the `local_*` columns each one writes:

| Type | Writes |
|---|---|
| `set_seen(v)` | `is_seen` |
| `set_flagged(v)` | `is_flagged` |
| `add_keywords(k)` | none locally (no column; server-only today, 6084) |
| `move(dest)` | `mailbox_path`, and `snoozed_until = NULL` when the source was snoozed (4796) |
| `delete` (hard; the UI's delete is `move(trash)`, `_deleteRow` 5018) | `local_hidden` |
| `snooze(until)` | `mailbox_path`, `snoozed_until` |
| `unsnooze` | `mailbox_path`, `snoozed_until = NULL` |
| `clear_snooze` | `snoozed_until = NULL` |

Later: `create_mailbox`, `rename_mailbox`, `move_mailbox` and
`delete_mailbox` on the mailbox rows.

Producers, all of which append ops and never write effective or `srv_`
columns: `setFlag`, `markAllAsRead` (one transaction, batched fold; it also
writes `threads` directly today, 4685, which goes away), `moveEmail`,
`deleteEmail(s)`, `snoozeEmail`, `wakeUpEmails`, Sieve (`_enqueueSieve*`,
6011–6087), undo, and the counterpart mirroring (§6).

**Supersede**: a new op supersedes an older `pending`/`stuck`/`failed` op on
the same row only if the new op writes **every** column the old one writes
(a `set_seen` supersedes an older `set_seen`, a `move` supersedes an older
`move` but not a `set_flagged`, an `unsnooze` supersedes a `snooze`). The
superseded op is deleted in the same transaction, together with its shadow
ops (§6). `add_keywords` is never superseded. Partial overlap folds both in
`seq` order.

**Undo** stores the op `seq`(s) in `UndoAction` instead of today's
`cancelPendingChange(id, type)` heuristic (5181). Undo deletes the op if it is
still `pending` (not `inflight`); otherwise it appends the inverse op. A seq
that no longer exists (superseded or discarded) is treated as already undone
for the cancel step, and undo falls through to appending the inverse op. An
acked hard `delete` (no Trash folder) cannot be undone, as today.

## 4. Ordering: when is an acked op dropped?

The race fixed in #1234: a server read starts, the user changes something,
the old answer arrives and is written. The rules below replace
`_ServerFlagRead`, and live in the DB so every repository instance and
isolate sees them.

1. **Read sequence.** One persistent counter in its own one-row table
   (`sync_states` has a `(accountId, resourceType)` primary key and is the
   wrong place). A *read* is one server command (`UID FETCH`, `UID SEARCH`,
   `Email/get`, `Email/changes`, …). Its sequence is taken just before the
   request is sent.
2. **Per-group stamps.** Each row stores `srv_keywords_seq` and
   `srv_location_seq`: the sequence of the read that last wrote that group.
   A read that does not fetch a group (size backfill 1711, header backfill
   9413, JMAP reconcile fetching only `keywords,size` 3727, body fetch) never
   writes or stamps it.
3. **Monotonic writes.** A read writes a group only if its sequence is ≥ the
   row's stamp for that group. A slow read that started before a faster one
   is ignored for that row. This also applies to **absence**: a delete or
   `srv_gone` from an enumeration (`UID SEARCH ALL`, JMAP prune, `notFound`,
   `destroyed`) is applied only if the enumeration started after the row's
   `srv_location_seq`.
4. **Ack.** On server success the flush sets the op `acked` with
   `ack_seq = next sequence`. It writes into `srv_` **only facts the server
   confirmed**: the new location from COPYUID, the JMAP id. Such a write
   stamps its group with `ack_seq`, so a slow read that started before the
   ack cannot put the source location back (rule 3). It never writes
   guesses (no destination UID known, 6839): then `srv_` stays as it is and
   the op keeps folding (see rule 5 for how it resolves).
5. **Drop.** An acked op keeps folding until reads with sequence >
   `ack_seq` have written, for that row, **every** read group its columns
   belong to (a `snooze` needs both `keywords` and `location`):
   - the value matches the op's intent → drop, re-fold;
   - the value contradicts it → keep folding until a **second** post-ack
     read agrees, then drop and log `op.contradicted`. This covers servers
     whose reads lag their writes (Stalwart #407, search index #1201,
     6740) and still lets another client's later change win;
   - for `delete` (and `move(trash)` on a mail that vanished): absence
     observed by an enumeration with sequence > `ack_seq` drops it;
   - for an acked location op whose destination UID was unknown: the source
     listing will mark the row `srv_gone`. That is expected, not a failure:
     the op keeps folding and waits for the appear side of carry-over (§6) in
     the destination, which fills `srv_` and drops it. If nothing appears
     within a timeout (a few sync cycles), it resolves as satisfied and the
     row is hidden; the destination copy arrives as a new row.
6. **No ordering of server versions.** JMAP `state` strings are opaque
   (RFC 8620 allows only equality) and IMAP MODSEQ is per mailbox and not
   reliably bumped (1673, 1786). The rules only compare our own read
   sequence numbers.

Assumption, stated explicitly: after a server acknowledges a write, a later
read eventually returns it. Rule 5's second read handles the "later" part;
a server that never returns its own writes will show the op as contradicted
in the App Log.

## 5. Outcomes and failure handling

| Flush outcome | Example | Result |
|---|---|---|
| **not sent** | connect or login failed, command never written | `pending`, no attempt charged |
| **ambiguous** | connection lost after the command was sent; expired lease on start-up | attempt charged; the next try first checks whether the intent is already satisfied |
| **satisfied** | already in dest (#1201); flags already set; delete/trash of a mail that is gone; delete of a mailbox not found | `acked` |
| **transient** | server `NO` that may pass, timeout | retry with backoff; after `maxAttempts` → `stuck` |
| **refused** | JMAP `notUpdated` with a permanent type; target mailbox gone for a move to Archive; mail gone for a flag change | `failed` |
| **parked** | the target has no server copy yet (virtual row, §6; mailbox not yet created) | not flushed until the target exists |

- `stuck` ops **keep folding** and show a "not synced yet" badge, as the
  outbox does with `status = 'failed'` (database.dart:581). They keep being
  retried with a long backoff and never get dropped automatically.
- `failed` ops **stop folding**: the UI shows the server's state again, and
  the op is listed under Settings → Failed changes with Retry / Discard.
  Retry appends a new op (new `seq`) so it cannot jump ahead of newer
  intent. Failures from one `origin` (a bulk action, a Sieve run) are shown
  as one group.
- **Idempotency** per type: flags are idempotent. A move checks "already in
  dest / still in src" via the existing Message-ID search (6721) before a
  retry. `create_mailbox` does a LIST / `Mailbox/get` lookup before
  creating.
- **Dependent ops**: an op whose target is created by a `failed` op
  (move into a mailbox whose create failed) fails too, naming the cause.

Nothing is deleted silently. The app and the server only disagree while an
op is pending, stuck or contradicted, and the UI shows each of those states.

## 6. Identity and special rows

**Ids are frozen and opaque.** A row keeps the id it got when first
inserted, whatever it is, for its whole life. Moves, COPYUID remaps, body
healing (891) and foreign-move adoption update `srv_uid` /
`srv_mailbox_path` instead of re-keying. Existing ids stay valid, so old
references (undo actions, app log, notifications already on the device,
`notified_emails`, `drafts.replyToEmailId`) keep working without a legacy
lookup. No code may parse an id; that is a phase 2 task.

**One row per mailbox instance on IMAP.** Gmail label folders share
X-GM-MSGID, RFC 8474 EMAILID is shared across folders, and a mail sent to
yourself has an Inbox and a Sent copy with the same Message-ID
(`_localRowFor`, 5525). These stay separate rows, as today. A row only
carries over to a new location on a **vanish + appear pair**
(`_movedDestinationId`, 2140) or a move ack, and only when the match is
unique. No match, or more than one, means a new row.

**UIDVALIDITY reset** sets the folder's rows' `srv_location_seq` to 0 and
`srv_uid` to NULL, then re-matches by Message-ID during the refetch (unique
matches only). Rows not matched after a complete enumeration become
`srv_gone`. Ops on a `srv_gone` row are satisfied (delete intent) or failed
(anything else), never dropped silently.

**Force resync** (#1236) uses the same mechanism for the whole account:
mark, refetch, then remove only rows proven gone. It never clears first.

**Virtual self-sent rows** (SYNC.md §8a) are rows with `is_local = true` and
no `srv_` location. User changes on them become `parked` ops, folded like
any other. When the real message arrives it is matched with **today's role-based
pairing** (Message-ID plus `arrivalIsSent` / Sent-vs-other role, 5532),
unique matches only, so a self-sent mail filed into another folder by a
server-side Sieve script still matches. The real message fills the virtual
row's `srv_` columns **in place**.
The row keeps its id, its parked ops become `pending`, and
`_maybeDissolveLocalMessage` (5519), with its flag replay, goes away. A
virtual row that is still unmatched after an expiry (e.g. 7 days) is
dropped, and its parked ops become `failed` so the user sees them.

**Counterpart accounts** (IMAP and JMAP views of one server) mirror every
action today (`_mirror*ToCounterparts`, 5447–5691), so the server message is
changed twice. In the new model the counterpart gets a **shadow op** with
`origin = counterpart:<seq>`. It folds, it is never flushed, and it is acked,
failed, superseded or discarded together with its primary: deleting a
primary deletes its shadows in the same transaction, so no shadow can fold
forever. `_dropStaleCounterpartRow`
(5682) becomes a shadow `location` op instead of a direct write.

## 7. Other resources

- **Mailboxes** use the same overlay columns (`srv_name`, `local_name`,
  `local_hidden`, …) and get local ids for mailboxes created offline. A move
  into a not-yet-created mailbox is an op parked on the `create_mailbox` op,
  and the flush runs them in `seq` order. This covers #1242, Archive/Junk
  creation and the placeholder `"Snoozed"` path (`_repointSnoozedPlaceholder`,
  7071). Rename updates `srv_mailbox_path` of the rows in that mailbox, which
  is a server fact, not a re-key.
- **Unread counts** stay server counts (STATUS, `unreadEmails`). Each stored
  count gets the read sequence it was read at. The UI shows `server + delta`,
  where the delta covers only ops that the count does not reflect yet:
  `pending`, `inflight` and `stuck` ops, and acked ops with `ack_seq` greater
  than the count's sequence. The delta includes moves, deletes and snoozes of
  unread mail. This avoids counting a change twice, and avoids a flicker back
  to the old number.
- **JMAP mailbox sets.** The flush computes `mailboxIds` at flush time from
  `srv_mailbox_ids` and keeps today's *replacement* semantics
  (`{dest: true}`, 7218): the fix for #910 was deliberate, and a patch built
  from a stale source would leave the mail in two folders. The effective
  `mailbox_path` still picks one mailbox per row, so showing one mail in
  several folders stays out of scope.
- **Notes, drafts and outbox** already keep their pending state in their own
  flags (`pendingUpload`/`pendingDelete`, `dirty`, `status`). They stay as
  they are.
- **Sieve scripts** get a local copy with a dirty flag, like drafts (#1243).
  This does not depend on the email phases.

## 8. Migration plan

Each step is a PR or a short series of PRs, shippable on its own. Each step
that changes the schema converts the queued rows of the change types it takes
over, so an upgrade never strands queued work.

**Phase 0 — fixes to the current code, independent of the redesign.**
- Add `uidValidity` to queued IMAP payloads, and refuse to flush on a
  mismatch (the UID-reuse hazard in §1).
- Charge no attempt for "not sent". Add a `state` column with a real
  `failed` value: after the retry limit or a permanent refusal, the change
  becomes `failed` instead of being deleted. Also stop the other silent drops
  listed in §1. Today `observeFailedMutations` (9552) lists every row with a
  `lastError`, including ones still retrying, and `retryMutation` (9588)
  resets the row in place. The list must show only `failed` rows, and
  retrying ones as "retrying".
- **Until the overlays exist** (phases 3 and 4), the old guards
  (`_inFlightFlagResourceIds` 1455, `_rowsWithUnflushedMoveOrSnooze` 3518,
  `_pendingDeleteOrMoveUids` 1997) count only `pending`, `inflight` and
  `stuck` rows. A `failed` row gets no protection, so the next server read
  reverts the optimistic value, which is the "failed stops folding" behaviour
  of §5 in the merged model. Acked rows are deleted at ack time, as today.
- #1236 (check the server is reachable before a force resync clears
  anything), #1237 and #1240.
- Add stale-answer and reordered-answer injection to the existing tools:
  `scripts/sync_reliability_fuzz.dart`, `test/backend/chaos_monkey_test.dart`
  and the Stalwart reliability runner. Property: after the queue drains, the
  server and the effective columns equal the user's last intent per field.
  A stateful in-memory IMAP/JMAP fake is a separate, budgeted task
  (`test/unit/fake_imap.dart` is a 270-line stub, and JMAP is mocked with
  `MockClient`).

**Phase 1 — the op table.** Evolve `pending_changes` into `ops` in place:
`state`, `ack_seq`, `lease_until`, `origin`, plus the read-sequence
table. The flush uses `state`, the outcome table (§5) and the lease; Undo
stores op seqs. Effective state is still the merged columns, so the visible
behaviour stays as it is apart from failure handling.

As implemented, phase 1 is narrower, in this order:
1. `inflight` + `lease_until` replace "attempts raised" as the claim
   marker; an expired lease is the ambiguous outcome (done, schema v69).
2. The outcome table as one settle function, without behaviour change.
3. `stuck` instead of `failed` at the retry limit, with backoff in
   `lease_until`.
4. The satisfied/refused corrections of §5.
5. Undo stores op seqs.
6. `origin` (may slip to phase 4, where counterpart ops need it).

The table and the Dart names stay `pending_changes` / `PendingChangeRow`,
`seq` is its `id`: a rename touches about 30 files for no behaviour gain.
`ack_seq`, the read-sequence table and the `acked` state move to phase 3:
acked rows are still deleted at ack time, so nothing would read them before
the stamps and drop rules of §4 exist. `parked` comes with phase 4.

**Phase 2 — frozen, opaque ids.**
- Add plain (not yet overlaid) server-location columns `srv_mailbox_path`,
  `srv_uid`, `srv_uid_validity` with a unique index on
  `(account_id, srv_mailbox_path, srv_uid_validity, srv_uid)`; backfill them
  from the row id, which names the server location even during a pending
  move, never from the optimistic `mailboxPath`. Sync looks rows up by this index, never
  by building an id: ERI:1817 and `background_sync.dart:257` build ids from
  a location today. Lookup must not use the merged, optimistic
  `mailboxPath`, or a re-fetch during a pending move inserts a duplicate.
- New rows get ids from an opaque generator (e.g.
  `accountId:` + random), so they cannot collide with a frozen id after UID
  reuse.
- Ban *building* ids from a location as well as parsing them.
- Replace every re-key (`_rekeyEmailRow`, `_rewritePendingChangeUids`, body
  healing, foreign-move adoption) with updates of the `srv_` location
  columns. Split `email_repository_impl.dart` along the writer roles in
Appendix A, so that later checks can map files to roles. This comes before
the location overlay because otherwise the fold would have to re-key rows.

**Phase 3 — the `keywords` overlay.** `ALTER TABLE ADD COLUMN` for the
`srv_`/`local_` pairs of `is_seen`, `is_flagged` and `snoozed_until`, plus
one `UPDATE` copying today's values into `srv_*`. Today's columns hold
optimistic values for rows with queued changes, so the copy must not trust
them for those rows: it sets their `srv_keywords_seq` to 0 and queues a
full flag reconcile for the next sync. The migration then folds the queued
keyword ops once, so `local_*` is right from the start. Add the
server-write gate, the per-group stamps, monotonic writes and the drop rules
(§4), and move every sync write of these fields onto the gate. Delete `_ServerFlagRead`, `_noteLocalEdit` and the flag `protects()`
calls.
- Built-in checks, run in tests and sampled in release builds (violations
  logged to the App Log): "every row's `<field>` equals
  `COALESCE(local_<field>, srv_<field>)`" and "a row with no foldable ops has
  all `local_*` NULL".

**Phase 4 — the `location` overlay.**
- `ALTER TABLE ADD COLUMN` for `local_mailbox_path`, `local_hidden` and
  `srv_gone`. `srv_mailbox_path` already exists from phase 2. It was
  backfilled from the row **id**, which still names the source of a pending
  move, never from the optimistic `mailboxPath`. `mailbox_path` becomes
  effective (empty string when hidden).
- Switch the sync scans to `srv_mailbox_path`, add the hidden-row filters
  and guards from §2, and add the clean-up rule.
- The absence rules and in-place matching of virtual rows.
- Counterpart shadow ops and the unread-count delta.
- Sync stops deleting rows that have ops. This fixes #1238 and #1239 by
  construction.

**Phase 5 — mailbox ops.** Offline folder create, rename, move and delete
(#1242), and the Snoozed placeholder.

**Phase 6 — clean-up.** Remove the remaining guard helpers, such as
`_pendingDeleteOrMoveUids` and the per-path queue checks, and update SYNC.md.

**Enforcement, from phase 3 on:**
- **An allow-list check.** `EmailsCompanion`, `_db.emails` writes
  (`update`, `into`, `delete`) and raw `UPDATE`/`INSERT`/`DELETE` on
  `emails` may appear only in the email state writer and in migrations.
  Grepping for field names does not work: `mailboxPath:` appears more than
  100 times in `lib/`, mostly in logger calls and model constructors.
  `check-layers` is an import grep (`Taskfile.yml:791`) and cannot do this
  either. If the allow-list proves too coarse, a custom lint is the next
  step.
- The consistency checks from phase 3.
- The phase 0 fuzz property runs in CI.

## 9. Effect on open issues

| Issue | After the redesign |
|---|---|
| #1236 force resync wipes offline | phase 0 short-term fix; §6 mark-and-sweep long-term |
| #1237 remove account drops pending work | phase 0, independent |
| #1238 JMAP upsert overwrites move/snooze | fixed by phase 4 |
| #1239 sync drops queued changes | phase 0 stops the silent drops; fixed by phases 4 and 5 |
| #1240 mailto unsubscribe | phase 0, independent |
| #1241, #1244 body / raw / attachment cache | independent |
| #1242 folder ops offline | phase 5 |
| #1243 Sieve | §7, independent |
| #1245, #1246, #1248 UI / smoke / exploratory | independent |
| #1247 race test helper | replaced by the phase 0 fuzz work |

## 10. Risks and open questions

- **The copy `UPDATE`** on a large DB (phases 3 and 4) rewrites every row
  once and grows the WAL. It sets only `srv_*`, so no FTS trigger fires.
  Phase 2 also builds the unique location index. Measure both on a 50k-row
  DB.
- **Enforcement is a check, not the schema.** A direct write that slips
  past the grep check is caught by the consistency checks, not refused at
  compile time.
- **Fold cost** inside large sync transactions: today `_updateThread` runs
  outside the fetch transaction (1928). Sync does not fold except on drop,
  so this mainly hits `markAllAsRead` and bulk Sieve runs. Batch them.
- **Drift change streams are per connection.** Background-isolate writes
  may not refresh foreground streams. Correctness lives in the DB (ops,
  stamps, sequence), so only freshness is at stake. Decide in phase 1
  whether the background isolate writes `srv_` columns at all.
- **Thread derivation** on IMAP (`_computeThreadId`, 9262) stays as it is
  and reads the effective columns.
- **Phase 2 blast radius**: id parsing (`split(':').last`,
  `substring('$accountId:'.length)`) and attachment folder names derived
  from ids. Inventory these first.

## Appendix A: every writer and where it goes

**Sync → `srv_*` and headers**
- `_fetchAndUpsertImapGuarded` (1758), `_refreshFlagsImap` (1530),
  `_maybeReconcileImapFlagsMailbox` (1591).
- `_backfillSizes` / `_backfillImapSizes` (1711), headers only.
- `_reconcileDeletedImap` (2068) and `_adoptImapMovedRow` (2160), which
  become absence and carry-over rules.
- UIDVALIDITY reset (1310), per §6.
- `_upsertJmapEmails` (3796), `notFound` handling (3302), `destroyed` →
  `_deleteJmapEmailById` (3428, 3480).
- `_pruneJmapMailboxToServerIds` (3541), `_maybeReconcileJmapMailbox`
  (3586), `_reconcileJmapFlagsForMailbox` (3683).
- `removeLocalMailbox` / `pruneLocalMailboxes`
  (`mailbox_repository_impl.dart:1399`, 585), which become `srv_gone`.
- `clearForResync` / `clearMailboxForResync` (9631, 9663), which become
  mark and sweep.
- `_backfillAddressHeaders` (9413), headers only.
- `_healMismatchedImapBody` (891), which updates `srv_uid` and no longer
  re-keys.
- `_storeSentCopyLocally` (7427), a server fact from APPENDUID.
- `_maybeDissolveLocalMessage` (5519), replaced by the in-place match.
- `BodyCacheService` (foreground and background isolate) reaches body
  healing and the header backfill through its own repository instance.

**Flush → op state and confirmed `srv_` facts**
- `_applyPendingChangeImap` (6523), `_settleImapChange` (6461) and
  `_recordChangeError` (4073), which become the outcome table.
- `_remapEmailAfterImapMove` (6822) and `_rekeyEmailRow` (985), which become
  location updates.
- `_retryImapMoveByMessageId` (6721).
- `_applyPendingChangeJmap` (7152) and `_repointSnoozedPlaceholder` (7071).

**User actions → ops (and local-only attributes)**
- `setFlag` / `_setFlagNow` (4503, 4564) and `markAllAsRead` (4691).
- `moveEmail` / `_moveRow` (4767, 4786) and `deleteEmail(s)` / `_deleteRow`
  (4891, 5005).
- `snoozeEmail` / `_snoozeRow` (5206, 5228) and `wakeUpEmails` /
  `_unsnoozeRow` (5324, 5385).
- `restoreLocalSnooze` (5370), which becomes an op.
- Sieve `_enqueueSieveMove/Delete/Flags` (6011–6087).
- `_mirror*ToCounterparts` (5447–5691) and `_dropStaleCounterpartRow`
  (5682), which become shadow ops.
- `cancelPendingChange` (5181) and `retryMutation` (9588).
- Mailbox create, rename, move and delete
  (`mailbox_repository_impl.dart:600–1356`, rename rewrites at 1161).

**Local row creation**
- `_createLocalSelfMessages` (7495) and the virtual Sent copy in
  `_storeSentCopyLocally` (7427).

**Removed**
- `restoreEmails` (5769), replaced by discarding or inverting the op.

**Derived (unchanged, they read the effective columns)**
- `_updateThread` (347), `_reconcileSourceThreads` (430) and
  `_sweepOrphanThreads` (465).
- The FTS triggers (database.dart:651–750).
