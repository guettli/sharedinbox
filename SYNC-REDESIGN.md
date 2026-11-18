# Sync redesign: overlay columns + operation log

Status: **chosen direction, partly implemented** (phases 0–5, see §8; phase 6 left). Goal: make offline-first (the rules in
`OFFLINE-FIRST.md`, PR #1249) a property of the data model instead of a rule
every sync path has to remember. This is a staged migration of the existing
sync code, not a rewrite: the IMAP/JMAP transport code and its edge-case
handling stay.

Line references are to `lib/data/repositories/email_repository_impl.dart`
(**ERI**) unless another file is named, as of `33c67b4`. Since phase 2d
that file is split into parts by writer role (see Appendix A), so the line
numbers are stale: find the code by the member names, which the split kept
(the body of a public method is now the private `_<name>` in its part).

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

On the mailbox rows (phase 5): `create_mailbox`, `rename_mailbox`,
`move_mailbox` and `delete_mailbox` (§7, §8).

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
2. (Dropped: the outcome table as one settle function, without behaviour
   change, would reshuffle the most delicate code for no gain; the
   outcomes stay with their branches.)
3. `stuck` instead of `failed` at the retry limit, with backoff in
   `lease_until`; IMAP `NO` with a permanent response code is a refusal
   (done).
4. The satisfied/refused corrections of §5.
5. Undo stores op seqs (done: `captureOps` / `cancelOps`,
   `UndoAction.opSeqs`).
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

As implemented, phase 2 is a series of PRs:
1. **2a (done, schema v70):** `srv_mailbox_path`, `srv_uid`,
   `srv_uid_validity` and `srv_jmap_id` on `emails`, with unique partial
   indexes `(account_id, srv_mailbox_path, srv_uid, srv_uid_validity)`
   (UID before UIDVALIDITY, so a lookup by folder and UID is a point lookup
   whether the UIDVALIDITY is known or not) and `(account_id, srv_jmap_id)`.
   The backfill takes the IMAP path from `mailbox_path`, and from the id only
   while a move, snooze or unsnooze is queued (pending, inflight or stuck):
   after a folder rename the id still names the old path. UIDVALIDITY comes
   from the folder's checkpoint. A location held by several rows stays with
   the one whose id names it. Every writer keeps the columns current: the
   IMAP and JMAP upserts, `_rekeyEmailRow` (the server location follows
   even when the shown folder stays behind a later queued move), the
   rename, the Sent copy and Undo's restore. Sync looks rows up by them
   (fetch upsert, CONDSTORE flag refresh, JMAP upsert, disclaimed and
   destroyed ids, JMAP prune and flag reconcile, the failed-move revert),
   and server calls about a row use them (body fetch and its healing,
   attachment download, raw message, JMAP flush, the debug probe). The
   periodic IMAP flag reconcile and size backfill already scan by
   `srv_mailbox_path`. New rows still got today's ids (with `id#2`, `#3`,
   … when another mail's row had that id), and re-keys still happened
   (both replaced in 2b). A JMAP row without a recorded id is never pruned
   as gone. Left for later: the other folder-scoped scans still filter by
   `mailbox_path` (phase 4).
2. **2b (done, schema v71):** new rows get opaque ids from `newEmailId`
   (`accountId:~` + 32 random hex digits; the account prefix keeps the
   attachment cache folders per account): the IMAP fetch, the JMAP upsert,
   the Sent copy and the virtual self-send rows. The `id#n` free-id logic
   and the 2a insert fallback by id are gone. The IMAP move remap and the
   body-fetch healing keep the row's id and update its UID, shown folder and
   `srv_` location (`_relocateEmailRow`); keeping the id was smaller than
   generating a fresh one, as nothing referencing it (body, attachments,
   queued changes, logs, threads, Undo) needs a rewrite. The #1269 guard
   against a late FETCH answer remembers the server location of each edited
   mail, since a new row no longer gets the id the edit was noted under.
   Nothing parses ids any more: the v71 migration stamps the JMAP id on each
   queued JMAP change (new changes get it when queued), completes Undo
   snapshots taken before v70 with their server location, and marks the
   virtual Sent copies (`is_virtual_sent_copy`, also carried by Undo
   snapshots); drafts are matched by `srv_jmap_id`. The background new-mail
   check records `notifiedImapLocationKey('INBOX', uid)` instead of an
   email id, and the foreground dispatcher counts the row stored later at
   that location as notified. `scripts/check_email_ids.sh` (in
   `check-layers`) bans the old id shapes in `lib/`, migrations excepted.
3. **2c (done, no schema change):** frozen ids. The foreign-move adoption
   no longer re-keys: when a row vanishes from its folder and exactly one
   other row of the account has its move-stable server id, the vanished
   row carries over to that row's place (`_carryOverMovedRow`) and keeps
   its id; the other row is merged into it. The vanished row survives
   because the user's references (open detail view, Undo, notifications,
   drafts) name it, while the other row was stored by a recent sync. It
   takes everything the other row recorded except the flags it has a
   queued change for (unless the other row has one too), and its queued
   IMAP changes follow the mail to the new UID, stamped with the other
   row's UIDVALIDITY. A same-folder match counts when it records another,
   existing UID (an own move whose answer was lost). No match, several
   matches, or a match recorded under an older UIDVALIDITY delete the row,
   as before; a vanished row the user moved meanwhile, or a match with a
   change being sent, waits for the next sync.
   `_mergeDuplicateRow` (shared with the move remap's duplicate merge) is
   the only place that re-points references between rows: body, queued
   changes, threads, Undo, App Log, and now also `notified_emails`,
   `drafts.reply_to_email_id` and downloaded attachments (moved with the
   body, else deleted from disk); each merge logs `email.duplicate_merged`.
   `scripts/check_email_ids.sh` also fails on writes of `emails.id` after
   insert (`UPDATE emails SET id`, `id:` in an update `EmailsCompanion`,
   `copyWith(id: Value(…))`, also across lines and string literals) and
   on re-pointing references outside `_mergeDuplicateRow`. Left for phase 4: when the source folder is synced
   before the destination, the row is still deleted and a new one stored.
4. **2d (done, no behaviour change):** `email_repository_impl.dart` is
   split along the writer roles of Appendix A into part files under
   `lib/data/repositories/email_repository_impl/` (the table at the start
   of Appendix A). Each part holds one private extension on
   `EmailRepositoryImpl`, so the moved members keep their names and their
   library privacy and no call site changed. The class keeps the
   constructor, every field (extensions cannot hold state) and the public
   API: a public method of a role is a one-line forwarder to the private
   `_<name>` in that role's part (an extension member cannot implement the
   interface). Static members became private top-level declarations of
   their part. Every moved member is byte-identical to before apart from
   that (the forwarded ones lost `@override` and got the `_` name, three
   statics were rewrapped by the formatter after dedenting), and every
   identifier in the library resolves to the same declaration as before
   (checked with the analyzer). Doc references to members now in another
   part are qualified with that part's extension. The duplication check
   now sees this code (jscpd skips files over 100 kB, which the old file
   was), and its 14 existing clones are in `duplication-baseline.json`.

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

As implemented, phase 3 is two PRs:
1. **3a (done, schema v72):** the overlay itself.
   - **Schema.** `emails` gets `srv_is_seen`, `srv_is_flagged`,
     `srv_snoozed_until`, `local_is_seen`, `local_is_flagged`,
     `local_snoozed_until` and `srv_keywords_seq`; `pending_changes` gets
     `ack_seq` and `contradicted_seq` (the seq of the first contradicting
     post-ack read, which makes "a second read" checkable); the read
     sequence is the one-row table `sync_read_seq`, advanced with one
     `INSERT … ON CONFLICT DO UPDATE … RETURNING`. A `local_snoozed_until`
     of 0 (the epoch) means "not snoozed", since NULL means "no intent";
     the effective column is `NULLIF(COALESCE(local, srv), 0)`.
   - **Migration.** Copies today's values into `srv_*` (stamp 0), folds the
     pending/inflight/stuck keyword ops once into `local_*` (and the
     effective columns), and makes the flag reconcile due
     (`IMAP:FlagReconcileDue:<folder>` for the row's server folder and the
     payload's, `JMAP:ReconcileDue:<mailbox>`) for every row with such an
     op, whose stored value was the user's, not the server's.
   - **Email state writer** (`lib/data/repositories/email_state_writer.dart`,
     a plain class on `AppDatabase`, also used by `removeLocalMailbox`): the
     gate (`beginRead` takes the sequence right before the request,
     `KeywordRead.write` writes one row with `WHERE srv_keywords_seq <= seq`
     and settles its acked ops), `withServerKeywords` for a new row's
     insert, `refold`, `foldSeenBulk` (the SQL bulk form for
     `markAllAsRead`), `ack`, `dropOrphanedAcks` and `consistencyProblems`
     (effective = `COALESCE(local, srv)`, and `local_*` = the fold of the
     row's ops). `refold` and a gate write (with the settling of acked ops)
     each run in a transaction of their own (a savepoint when nested), so
     reading the ops and writing the row never interleave with an enqueue
     and its fold; so do the cancel paths. `KeywordRead.writeAll` writes a
     whole folder's answer: rows whose `srv_*` already match and that have
     no acked op are only stamped, one `UPDATE … RETURNING id` per group of
     equal values; the rest go through the per-row gate. `pending_changes`
     gets the index `(resource_id, state)`.
     Every statement sets the effective column together with the `srv_` or
     `local_` one (in SQL, with the new value inlined: `SET` expressions
     see the old row). The pure parts (`foldKeywords`, `keywordColumnsOf`,
     `readAgreesWith`, `ServerKeywords`) are in `lib/data/db/keyword_fold.dart`,
     shared with the migration.
   - **Gate sites.** IMAP: the new-mail FETCH (a new row is inserted with
     the read's values and stamp, an existing one goes through
     `KeywordRead.write`; the upsert no longer names the keyword columns),
     the CONDSTORE refresh and the periodic reconcile (which now write
     every row they read, in one transaction, and also its `snz:` keyword:
     FLAGS is the whole `keywords` group). JMAP: `_upsertJmapEmails` (the
     sequence is taken per `Email/get` batch) and the flag reconcile, which
     no longer skips rows with queued changes. The size backfill, header
     backfill and body fetch neither write nor stamp. Other writers:
     the Sent copy and the virtual self-send row are inserted with
     `withServerKeywords(…, seq: 0)` (a Sent copy sync already stored keeps
     its state); Undo's restore of a gone row writes the snapshot as
     `srv_*` with stamp 0, makes the flag reconcile due and re-folds (a row
     that still exists keeps its keyword columns); the foreign-move carry-over takes the copy's `srv_*` and
     stamp and re-folds (the `keepOwn` rule is gone); `_mergeDuplicateRow`
     re-folds the kept row.
   - **Fold.** Runs in the transaction of every op change: `_enqueueChange`
     (insert and fold in one transaction), cancel (`cancelOps`,
     `cancelPendingChange`), discard, retry, failure (with the dependents
     failed with it), ack, drop, and the ops `removeLocalMailbox` fails.
     User actions no longer write `is_seen`/`is_flagged`/`snoozed_until`:
     `setFlag` only queues; move/snooze/unsnooze/wake-up/restore write the
     location and `snoozed_from_mailbox_path` (local-only) and leave the
     snooze to the fold (`move` with `clearSnooze`, `snooze`, `unsnooze`,
     `clear_snooze`); `restoreLocalSnooze` only restores
     `snoozed_from_mailbox_path`. A failed flag change no longer guesses
     the previous value (`_revertFailedFlag` is gone): it stops folding, so
     the row shows `srv_*`, and the flag reconcile is still made due in case
     `srv_*` is stale (#1270). A failed snooze/move no longer writes
     `prevSnoozedUntil`; the fold gives the server's snooze back.
   - **Ack and drop.** On success a flush acks every op that writes a
     keyword column (`flag_seen`, `flag_flagged`, `clear_snooze`, `snooze`,
     `unsnooze`, `move` with `clearSnooze`): `state = 'acked'`, `ack_seq` =
     next read sequence; an older acked op of the row whose columns it
     covers is dropped then (it no longer shows). Ops without a keyword
     column (plain move, delete, `add_keywords`) and ops whose row is gone
     are deleted at ack as before. A gate write with a read sequence above
     `ack_seq` drops the op when the read agrees (a snooze agrees with any
     `snz:` keyword: the keyword has second precision in UTC digits and
     need not round-trip; an unsnooze/clear with none), records
     `contradicted_seq` on the first contradiction and makes the folder's
     flag reconcile due (otherwise, with CONDSTORE and on JMAP, an
     unchanged mail is read again only after 15 minutes), and drops it on a
     contradicting read of a later sync run with the App Log warning
     `op.contradicted`. A sync run (`EmailStateWriter.inSyncRun`, one
     `syncEmails` call) takes a start sequence; a read counts as "later"
     only when its run started after `contradicted_seq`, and the reconcile
     uses the due marker as it was when the run started, so the CONDSTORE
     refresh and the reconcile right after it never count as two reads.
     An acked op that a newer foldable op of the same columns shadows is
     dropped silently (at the newer op's ack, or at the next read).
     Acked ops are hidden from the Pending Changes screen, the failed list
     and the unsynced-work count, and `acked` is not in `_liveStates`, so
     every location guard treats an acked op like the deleted one before.
     Acked ops of rows that no longer exist are deleted at the start of each
     flush (`dropOrphanedAcks`). Snooze choice: location is not overlaid
     yet, so `snooze`/`unsnooze`/`move(clearSnooze)` are acked for their
     `snoozed_until` only and settle on the `keywords` group alone
     (§4.5 would also wait for `location` once phase 4 overlays it).
     Deleting them at ack, as before, would make `snoozed_until` flicker
     back to the old `srv_` value until the row's new location is read.
   - **Supersede.** A new `flag_seen`/`flag_flagged` deletes the queued
     (`pending`, not inflight) op of the same flag, in the enqueue
     transaction, besides the failed/stuck ones the user's action already
     replaced. Other types are left as before (the location ops still need
     their order and Undo's cancel). Latent: Undo's captured op ids are not
     known to the queue, so a superseded flag op could be among them; Undo
     queues no flag ops today, and a cancel of a gone id falls through to
     the inverse op (§3).
   - **Snooze keywords.** A re-snooze now removes the earlier `snz:`
     keyword (IMAP: FETCH FLAGS and STORE -FLAGS before the new one; JMAP:
     `keywords/snz:…: null` in the same `Email/set`). Before, both stayed,
     and sync read back whichever came first; the lenient snooze agreement
     would have hidden that.
   - **Removed.** `_ServerFlagRead`, its `protects()` calls,
     `_inFlightFlagResourceIds` as a flag guard (the JMAP "disclaimed but
     edited" guard keeps the query as `_rowsWithLiveChanges`), the per-id
     edit sequence, the flag skip logic in `_settleFlagReconcileDue` and
     `_revertFailedFlag`. Kept: the #1269 guard against a late new-mail
     FETCH bringing back a moved or deleted mail, now `_FetchLocationGuard`
     fed by `_noteLocationEdit` for placement changes only: that is a
     `location` concern (phase 4).
   - **Cut, until phase 4:** virtual rows (`is_local`) and JMAP rows
     without a server id get no op, so a user change on them is stored as
     their own `srv_*` value (`EmailStateWriter.writeOwn`) instead of a
     parked op. The `threads` write of `markAllAsRead` stays. Counterpart
     shadow ops are phase 4; the counterpart mirroring still queues real
     changes on the twin row, which fold like any other.
   - **Tests.** `test/unit/keyword_fold_test.dart` (the pure fold),
     `test/unit/keyword_overlay_test.dart` (gate order, stale answer after
     a change, ack without flicker, drop, two contradictions, one per sync
     run, shadowed and orphaned acks, a fold racing an enqueue, failed and
     stuck, supersede, bulk mark-read, snooze, cancel),
     `test/unit/keyword_overlay_jmap_test.dart` (ack and drop via
     `Email/changes`, the JMAP flag reconcile through the gate), the v71→v72
     migration test, and the stale-answer fuzz, whose property now also
     requires `consistencyProblems()` to be empty.
2. **3b (done, no schema change):** enforcement.
   - **Allow-list check.** `scripts/check_email_writes.sh` (in
     `check-layers`, so `check-fast`; fixture tests of violations and
     near-misses in `scripts/test_check_email_writes.sh`, run there too).
     Two parts. (1) The overlay columns (`is_seen`, `is_flagged`,
     `snoozed_until`, their `srv_`/`local_` pairs, `srv_keywords_seq`) are
     written only in `email_state_writer.dart` and the migrations (the
     members `_upgradeSteps`, `_backfillSrvLocation` and `_overlayKeywords`
     of `database.dart`; the rest of that file is checked), with no
     allow-list: it fails on one of them in an `EmailsCompanion(…)`,
     `.insert(…)` or `.custom(…)` (also across lines, `Value.absent()`
     excepted), on a `srv…`/`local…` name given a `Value(…)` anywhere (only
     emails rows have them; `isFlagged` alone is also a `threads` column),
     on SQL in any letter case (an `UPDATE [OR …] emails … SET` list or an
     `INSERT INTO emails (…)` column list naming one, also across string
     literals and quoted, an `INSERT INTO emails` without a column list,
     the table also interpolated as `${…emails…}`), and, in a member allowed
     to write `emails`, on a whole-row `toCompanion`, a `copyWith` naming
     one (not on a thread companion), and an insert/write/replace whose
     argument is not an `EmailsCompanion…(…)` literal, `withServerKeywords(…)`
     or a local variable initialised with one (an `Email` data row carries
     every column). (2) Every other write of `emails` (`EmailsCompanion`,
     `toCompanion`, Drift update/into/delete/insert/replace on `emails`
     incl. batches, the table manager and `managers.emails`, `updates: {…}`
     naming it, raw SQL in any case, and as a backstop against aliases any
     bare `_db.emails`/`db.emails` outside `select(`, `selectOnly(`, joins,
     `readTable…(` and `readsFrom:`) is in the writer, the migrations, or a
     member (method, getter or top-level function, found by indentation;
     fields, getters, annotations and two-line signatures start a member of
     their own) on the allow-list, which names file, member and reason with
     the phase that removes it; a stale entry fails too. A line that only
     looks like a write can opt out of (2) with `// not an emails write`.
     SQL is matched in code with `//` comments removed, so prose does not
     count. Plain `grep -E`/awk, tested with gawk, mawk and busybox awk.
   - **Moved into the writer** (small, same statements): every delete of
     rows (`deleteRow`, `deleteRowsOf`: 15 sites in sync, failure handling,
     counterparts, Sieve, `_mergeDuplicateRow`, force resync,
     `removeLocalMailbox`; phase 4's clean-up rule will live there), the
     header backfills (`writeHeaders` for preview, List-Unsubscribe,
     Reply-To, Bcc; `writeSizes`), and the foreign-move carry-over
     (`takeOverRow`): its whole-row copy wrote the overlay columns outside
     the writer (followed by a re-fold, so it was consistent, but it was the
     one such write the check found).
   - **Allow-listed** (16 members): the row inserts/upserts (IMAP new-mail
     fetch, JMAP upsert, Sent copy, virtual self-send rows, Undo's restore;
     their keyword columns come only from `withServerKeywords`); the
     optimistic location writes and the local-only
     `snoozed_from_mailbox_path` (`_applyLocalMove`/`Snooze`/`Unsnooze`,
     `_wakeUpEmails`, `_restoreLocalSnooze`, `_revertFailedLocation`,
     `_enqueueSieveMove`), phase 4; the server location facts
     (`_relocateEmailRow`, `_releaseImapLocation`), phase 4; the Snoozed
     placeholder repoint and the folder rename, phase 5.
   - **Sampled consistency checks.** `consistencyProblems` now returns
     `ConsistencyProblem`s (row, account, mismatching fields, whether the
     row has foldable ops, the values) and can be limited to given rows;
     it compares `local_*` with the fold per field, so "no foldable ops ⇒
     all `local_*` NULL" is the empty fold. `checkSample` checks the rows
     with the 200 most recent foldable ops plus 200 of the account's rows
     in `rowid` order from a random start in the account's own `rowid`
     range (wrapping; the query says `+account_id`, so SQLite walks the
     rowid range and stops at the limit instead of sorting the account's
     rows), reading in one transaction so an enqueue and its fold cannot
     fall between a row and its ops. `OverlayConsistencySampler` runs it
     after a sync run (`_syncEmails`, after `inSyncRun`), at most once per
     30 minutes per account, in every build (its own provider in
     `di.dart`, so a rebuilt repository keeps it; the last check is also
     stored in `sync_states` as `Overlay:ConsistencyCheck`, for restarts and
     the background isolate). Tests construct the repository without it
     and check the whole table themselves. Decision on repair: each broken
     row is logged first (App Log error `overlay.inconsistent`, `emailId`,
     and in `data` the fields, the effective/`srv`/`local` values, the fold
     and the ops; the first 10 rows one line each, then one line with the
     total and up to 100 more ids), then re-folded, which recomputes
     `local_*` and the effective columns from the ops and `srv_*`; the log
     line says it repaired, and the rows whose shown value changed get their
     thread aggregates refreshed (`_updateThread`). Leaving the row would
     show a wrong state until its next server read (or for good, for a
     `local_*` without an op), and the log keeps the bug visible. The check
     is awaited at the end of `_syncEmails` rather than fired off: it costs
     one `sync_states` read when not due and a few ms when due, its writes
     (repair, thread refresh) are ordered before the next sync step, and a
     background (WorkManager) isolate may be torn down once the sync
     returns. A failing check logs `overlay.check_failed` (warn) and never
     fails the sync. `test/unit/overlay_consistency_check_test.dart`.
   - **Fuzz property in CI.** The stale-answer fuzz already asserted the
     property (after the queue drains, server and effective read/star
     columns equal the user's last intent per field, and
     `consistencyProblems()` is empty) and runs in `check-fast` with seeds
     1–30. More seeds there cost too much (90 seeds took 3 minutes on
     their own, against 30 s for 30), so `check-fast` keeps 30 (no extra
     time) and the nightly `task stale-fuzz` (Dagger `stale-fuzz`, in
     `fuzz-nightly.yml`, no Stalwart) runs 200 seeds from a window that
     moves daily (`STALE_FUZZ_FIRST_SEED` = 31 + 200 × (day of the year −
     1), so January 1st starts right after check-fast's seeds). The nightly chaos monkey and
     the long-term IMAP/JMAP fuzz assert `consistencyProblems()` empty at
     their checkpoints. Not done: the fuzz does not snooze (the snooze
     fold is covered by `keyword_overlay_test.dart`), and
     `scripts/sync_reliability_fuzz.dart` injects faults but has no
     per-field intent model to check against.

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

As implemented, phase 4 is two PRs:
1. **4a (done, schema v73):** the overlay, the sync scans and the clean-up
   rule.
   - **Schema.** `emails` gets `local_mailbox_path`, `local_hidden`,
     `srv_gone` and `srv_location_seq` (the stamp of the `location` group,
     §4.2; not in the original list, but monotonic location writes need
     it). `mailbox_path` is effective: `''` when `local_hidden`, or when
     `srv_gone` with no `local_mailbox_path`, else
     `COALESCE(local_mailbox_path, srv_mailbox_path)`. `srv_mailbox_path`
     is never NULL any more: an `AFTER INSERT` trigger
     (`emails_srv_mailbox_path_default`) records the shown folder as the
     server's for a row inserted without one (a new row has no pending
     move; this also keeps every test fixture and the Sent copy valid), and
     JMAP rows record their mailbox id there (before, only IMAP rows had
     one). A row without a server copy (a virtual row, a JMAP mail whose id
     is unknown) has its own folder there, as 3a's `writeOwn` does for its
     keywords. `_releaseImapLocation` and the folder rename now clear only
     `srv_uid`/`srv_uid_validity`, not the folder. New index
     `emails_srv_mailbox (account_id, srv_mailbox_path)` for the
     folder-scoped scans, and the partial `emails_srv_gone (account_id)
     WHERE srv_gone = 1` for the clean-up rule.
   - **Migration.** A row without `srv_mailbox_path` gets the source of its
     first queued move/snooze/unsnooze, else the folder it shows. The
     foldable ops are folded once (both groups). An acked op keeps folding,
     as at runtime, until a read settles it (dropping it would flash an
     acked snooze without COPYUID back to its source); a `contradicted_seq`
     recorded before v73 concerned its keywords only and is cleared for
     one whose destination is not where the server has the mail. Only rows
     whose shown folder changes are rewritten (a row with a failed move
     whose revert was skipped shows its server folder from now on); they
     are listed in the App Log (warn `migration.location_overlay`, one line
     per account).
   - **Fold.** `foldLocation` / `locationColumnsOf` / `locationAgreesWith`
     in `keyword_fold.dart` next to the keyword fold; `refold` writes both
     groups in one statement. `move`/`snooze`/`unsnooze` write
     `local_mailbox_path = dest`, `delete` writes `local_hidden`. A
     `failed` op stops folding, so a failed move shows the mail in its
     source by itself: `_revertFailedLocation` no longer writes the folder
     (it keeps restoring `snoozed_from_mailbox_path`, re-pointing later
     changes and making the reconcile due), and retry/discard/cancel just
     re-fold. User actions no longer write `mailbox_path`: `_applyLocal*`,
     the wake-up, Sieve's `fileinto` and `restoreLocalSnooze` only write
     the local-only `snoozed_from_mailbox_path` (`writeSnoozedFrom`) and
     refresh threads. A **delete for good hides the row** instead of
     deleting it (body and attachments survive a failure or an Undo
     cancel); a row without a server copy is still deleted at once.
     Undo's cancel of a queued move, snooze or delete is now enough to put
     the mail back (the reverse move finds it in place and queues nothing):
     the local-only snooze source comes back from the cancelled payload
     (`prevSnoozedFrom`). `moveEmail` mirrors to the counterparts also when
     the row is in the destination already, so a counterpart whose mirrored
     change was sent (and cannot be cancelled) still gets its reverse move.
   - **Gate.** `KeywordRead` (the read object of 3a) also writes the
     location group: `writeLocation` (presence in a folder: IMAP FETCH of
     an existing row, JMAP `Email/get`), `confirmPresent` (an enumeration
     listed the row: IMAP `UID SEARCH ALL`, JMAP `Email/query` prune; it
     writes only a row marked gone or with an acked op, so a sync does not
     rewrite the whole folder) and
     `markGone` (absence: the UID missing from `UID SEARCH ALL`, JMAP
     `notFound`, `destroyed`, empty `mailboxIds`, the prune). Each writes
     only `WHERE srv_location_seq <= seq`, so absence from an enumeration
     that started before the row's location was last written is ignored
     (§4.3). New rows are inserted through `EmailStateWriter.newRow`
     (`withServerLocation` + `withServerKeywords`); existing rows get their
     headers with an `EmailsCompanion` that names no overlay column, so the
     JMAP upsert and the IMAP fetch no longer overwrite the shown folder
     (#1238). The reads take their sequence before the request: the IMAP
     `UID SEARCH ALL` of the deletion reconcile, each `Email/changes` page,
     and the first `Email/query` of the full sync and of the reconcile now
     do too.
   - **Ack and drop.** Every op with an overlay column is acked now (plain
     moves and deletes too). What the server confirmed is written at the
     ack, stamped with `ack_seq`: the JMAP move's mailbox (`mailboxIds` is
     replaced), the gone state of a delete for good (IMAP expunge, JMAP
     destroy or `notFound`). An IMAP move's new location (COPYUID or
     Message-ID search) is written by `relocate`, stamped with a sequence
     taken before the MOVE (or the search) that learnt it (§4.1). `_settleAcked` is shared by both groups and reads the
     row's `srv_*` after the write: an acked op settles once every group it
     has columns in was written by a read after its ack (so a snooze waits
     for both, §4.5), dropped when they agree and by the two-read rule when
     they contradict (`op.contradicted` now also names the server's
     folder). Absence after the ack settles every acked op of the row; an
     acked move/snooze/unsnooze dropped that way logs `op.gone` (warn): the
     mail vanishes from the list.
   - **Clean-up rule.** `EmailStateWriter.cleanUpGone` deletes the rows of
     an account that are `srv_gone` and have no pending/inflight/stuck/acked
     op (a `failed` op stays listed without its row). It runs after every
     absence write and at the start of every flush. Sync no longer deletes
     a row itself: the IMAP deletion reconcile, the UIDVALIDITY reset and
     `removeLocalMailbox` (`markFolderGone`), JMAP `notFound`, `destroyed`,
     empty `mailboxIds` and the prune all mark gone and clean up. A row
     kept because the user has a change for it is logged (warn
     `email.server_gone_with_changes`); the change then fails at the flush
     (message gone) and is listed, never dropped (#1239). A JMAP `notFound`
     for any change marks the row gone as well (before, a failed move left
     it shown in the destination). An IMAP move answered without COPYUID
     for a row hidden by its queued delete takes the destination UID only
     from a unique Message-ID match, as for a row that is gone. The UIDVALIDITY
     reset logs the rows it keeps (`sync.uidvalidity_changed`), and so does
     `removeLocalMailbox` (`email.server_gone_with_changes`);
     `markFolderGone` runs in one transaction and clears the UID only of the
     rows it marked that are still recorded in that folder. A failed move
     whose mail is in neither folder (`_dropGoneRow`) marks it gone too,
     and it is deleted only without a change left. The warning is not
     logged for a row whose only change is the user's own delete for good;
     a flush that cleans up a row whose failed change stays listed logs
     `pending_change.row_removed`. Force resync (whole account or one
     folder) still deletes the rows, except those with a change, which
     the refetch finds again by their server location (#1236's
     mark-and-sweep is later).
   - **Sync scans** filter by `srv_mailbox_path` (and the row's `srv_uid` /
     `srv_jmap_id`), never by the shown folder: the IMAP deletion
     reconcile, the JMAP prune and flag reconcile (the IMAP flag reconcile
     already did); `deleteRowsOf` too. The `_rowsWithUnflushedMoveOrSnooze`
     and `_rowsWithLiveChanges` guards are gone: a row with a pending
     change is no longer at risk.
   - **Hidden rows.** `_visible` (`mailbox_path <> ''`) in `getEmail` (a
     hidden row reads as deleted), `findEmailByMessageId`, the FTS/body/
     notes search, `searchEmailsStructured`, `getEmailsByAddress`,
     `searchAddresses`, the thread across folders, the counterpart lookup,
     `_localRowFor`, `_hasArrivedOutsideSent`, `wakeUpEmails`, the folder
     statistics, the body prefetch (`BodyCacheService`) and the note log's
     Message-ID lookup. `_updateThread` ignores `''`; a re-fold refreshes the
     thread in the folder the row showed before and the one it shows now
     (`Refold`). Every user action (flag, move, delete, snooze, unsnooze)
     on a hidden row does nothing.
   - **Late FETCH (#1269).** The in-memory `_FetchLocationGuard` /
     `_noteLocationEdit` is removed: an applied move or delete now stays
     acked until a read started after it confirms it, so the queue check
     after the FETCH (`_pendingDeleteOrMoveUids`, which counts acked ops
     now) sees a change sent while the answer was on its way, in every
     isolate. Only a row still recorded at the fetched location skips the
     check (its change folds over what is written). Gap: if a read started
     after the ack settles the op *before* the stale answer is processed
     (two syncs of one account at once), the answer is inserted as a new
     row; the next reconcile of that folder marks it gone.
   - **Rename and the Snoozed placeholder.** `EmailStateWriter.renameFolder`
     moves `srv_mailbox_path`, `local_mailbox_path`,
     `snoozed_from_mailbox_path` and the `dest`/`src`/`mailboxPath` of the
     account's queued payloads (and `prevSnoozedFrom`), and the folders
     stored in Undo actions, from one folder to another in one
     transaction (App Log warn `pending_change.folder_renamed`); the IMAP
     folder rename and `_repointSnoozedPlaceholder` use it (phase 5 makes
     both ops).
   - **Enforcement.** `check_email_writes.sh` check 1 covers the location
     columns (`mailbox_path`, `srv_mailbox_path`, `local_mailbox_path`,
     `local_hidden`, `srv_gone`, `srv_location_seq`; `mailboxPath` stays
     allowed in `EmailsCompanion.insert(…)`, where Drift requires it), and
     an insert/write argument must be an `EmailsCompanion(…)` literal,
     `newRow(…)`/`withServerLocation(…)` or a variable holding one (no
     `EmailsCompanion.insert(…)` upsert, no bare `withServerKeywords`);
     `newRow`/`withServerLocation` only in a plain `.insert(…)` without
     `mode:`/`onConflict:`, and no `replace`. SQL split over adjacent string
     literals is read joined, and the file pre-filter knows the location
     column names. The
     allow-list shrinks from 16 members to 5 (the new-row inserts of sync,
     the virtual rows and Undo's restore); `relocate`, `releaseLocation`,
     `renameFolder` and `writeSnoozedFrom` moved into the writer.
     `consistencyProblems` (and with it `OverlayConsistencySampler`)
     checks `mailbox_path`, `local_mailbox_path`, `local_hidden` and a
     missing `srv_mailbox_path`; the repair re-folds (and records the shown
     folder as the server's for a row without one).
   - **Undo's restore** of a row the clean-up deleted records the
     snapshot's server folder (and UID unless another row holds it), not
     the folder it showed: a snapshot taken behind a queued move shows the
     destination, where no sync could confirm it.
   - **Tests.** `location_overlay_test.dart` (IMAP rig: fold, stale source
     sync, ack and drop, refused move, delete hides then cleans up, Undo
     cancel keeps the body, a gone mail with a queued move, a refused
     delete showing the mail again, a removed folder putting a moved-in
     mail back in its source (#1239), the late FETCH, the rename incl.
     `prevSnoozedFrom` and Undo, the consistency repair),
     `location_overlay_jmap_test.dart` (#1238 with a queued and with a
     just-sent move and with a queued and an in-flight snooze, #1239
     `destroyed` keeping row and body and `notFound`, delete for good, a
     foreign move), Undo of a move whose counterpart change was sent
     (`undo_logic_test.dart`), fixtures for the new check rules, and the
     v72→v73 migration test.
2. **4b (done, schema v74):** rows without a server copy, counterpart
   shadow ops, the appear side of carry-over and the unread-count delta.
   - **Schema.** `pending_changes.origin` (§3; `counterpart:<id>` for a
     shadow, NULL otherwise) and `mailboxes.unread_seq` (§7). Nothing
     queued is converted: virtual rows had no ops (3a's `writeOwn`), and
     the changes mirrored onto a twin before v74 are real ones, which
     flush as before. Two new states, `parked` and `shadow`; both fold
     (`foldableOpStates`), neither is flushed (the flush selects `pending`
     and due `stuck` only).
   - **Parked ops.** `_enqueueChange` queues a change of a row without a
     server copy (a virtual row; a JMAP row without `srv_jmap_id` or
     `srv_uid`) as `parked`, unstamped, and does not kick a flush.
     `writeOwn` and `writeOwnLocation` are gone: no user action writes a
     `srv_` column any more, for these rows either (point 3 of the 4b
     brief, the JMAP rows without a server id, included). Undo cancels a
     parked op like a pending one (`_unsentStates`), a new read/star
     change supersedes a parked one, a delete for good of a virtual row
     hides it (parked delete) instead of deleting it, Retry of a failed
     change of a row still without a server copy parks it again, and
     `removeLocalMailbox` fails parked ops naming the folder. The Pending
     Changes screen lists them ("waiting for the server copy of this
     mail"); they count as unsynced work.
   - **Absence rules.** A virtual row has no server copy, so no absence
     applies: the deletion reconcile and `markFolderGone` skip `is_local`
     rows, the JMAP prune skips rows without `srv_jmap_id`, and
     `notFound` / `destroyed` / empty `mailboxIds` address rows by server
     id. It ends only by the in-place match or by its expiry.
   - **In-place match** (`_matchArrival`, replacing
     `_maybeDissolveLocalMessage`). After a sync stored rows, each is
     matched with a row that waits for exactly that mail: a virtual row
     (role rule of §6: a Sent arrival only with the virtual Sent copy; also
     a hidden one), and, for a newly stored row only, a row waiting with
     an acked move into that folder (below) or a JMAP row of that folder
     without a server id (unique Message-ID match). The waiting row keeps
     its id: the stored row is merged into it (`_mergeDuplicateRow`, so
     its references follow; a virtual row's draft-text body is dropped
     first, so the server's replaces it), it takes the stored row's
     server facts, headers and read stamps (`takeOverRow`, the
     carry-over's copy; the local-only `snoozed_from_mailbox_path` is
     kept), its parked ops become `pending` (`_unparkOps`: in queue order
     each payload gets the server's UID, folder, UIDVALIDITY and JMAP id,
     a later one the destination of the one before it plus the
     `uidAfterMove` marker, as if queued now; ids and so Undo's
     references stay), and its acked ops settle against the new location
     (`EmailStateWriter.settle`). App Log warn `email.local_row_matched`
     (kind `virtual`, `moved` or `no_server_id`, with the merged row's id).
     The sync guard `_hasLocalMessages` became `_hasWaitingRows` (a local,
     gone, or location-less row exists).
   - **Expiry** (`EmailStateWriter.expireParked`, right after a
     successful sync of a folder, never before it: a week offline must not
     drop a note whose copy the very next sync stores; a note only after
     an inbox sync, a virtual Sent copy after a Sent sync, a parked change
     of a JMAP row after a sync of its folder). A virtual row stored more
     than 7 days ago is dropped (its
     body cascades; App Log warn `email.virtual_expired`) and its parked
     ops become `failed` ("the server copy of this mail never arrived"),
     listed without their row; a parked op of another row older than 7
     days becomes `failed` ("the server id of this mail never became
     known") and stops folding, the row stays (App Log warn
     `pending_change.parked_expired` for each). Retry of such a change
     (its payload carries `parkedShownIn`, the mark of a parked change)
     stays failed when the row is gone, parks it again while the row has
     no server copy, and otherwise rewrites it for the copy (`_unparkOps`),
     never sending UID 0. On upgrade, virtual rows older than 7 days are
     dropped after the first inbox sync (each logged).
   - **In-place match, review fixes.** `_matchInPlace` re-checks in its
     transaction that the kept row still waits (`_isWaiting`) and that the
     stored row is a server row with the same Message-ID, so two isolates
     or two copies cannot match it twice. `_unparkOps` drops a parked move
     into the folder the mail arrived in, and sends a parked delete for
     good only when the mail arrived in the inbox or is in the folder the
     user deleted it from (`parkedShownIn`): a mail a server filter filed
     into Junk or Gmail's All Mail (where an expunge removes every label)
     is not deleted; that delete fails, the mail shows, and
     `email.local_row_matched` says so (and says "deleted for good" when it
     is).
   - **Virtual row creation** moved into the writer (`insertLocalRow`,
     `writeLocalRowHeaders` with a `LocalRowHeaders` value, the
     `create_local` step): `local_rows.dart` builds no `EmailsCompanion`
     any more. The own folder and keywords are still stored as `srv_*`
     with stamp 0 at insert (the columns are NOT NULL; no read ever writes
     a virtual row, and the match replaces them). The writer refuses a
     `LocalRowHeaders` that is virtual with a server location (or not
     virtual without one), and `writeLocalRowHeaders` writes only a
     virtual row or the row at the server location the headers name.
   - **Counterpart shadow ops.** The mirroring (`_mirrorMove/Delete/
     SnoozeToCounterparts`, the bulk delete) runs the twin's action inside
     `_asShadowOf(primary)`, where the primary is the latest change queued
     on the source row (none: nothing is mirrored; so `moveEmail` of a row
     already in the destination no longer mirrors, which 4a needed for a
     twin whose real change was sent). `_enqueueChange` then inserts a
     `shadow` op with `origin = counterpart:<primary>` (one per primary
     and row), folds it, does not capture it for Undo and does not kick a
     flush. Lifecycle: `EmailStateWriter.ack` acks the primary's shadows
     with the same `ack_seq` (the read sequence is global), or drops one
     whose twin is gone; the counterpart's own reads then settle it like
     any acked op. `dropOrphanedShadows` drops a `shadow` whose primary no
     longer exists or failed (and acks one whose primary is acked) and
     re-folds the twin; it runs in `_refoldAndRethread` (so in the
     transaction of every cancel, discard, retry and failure), after the
     enqueue's supersede of a read/star change, in `removeLocalMailbox`,
     in `expireParked` and at the start of every flush.
     `_dropStaleCounterpartRow` (a move into a folder the counterpart does
     not know) is a shadow `delete` with `awayFrom` (the twin's server
     folder; `locationAgreesWith` accepts gone or any other folder)
     instead of deleting the row: an Undo or failure of the primary shows
     the twin again, with its body. Shadows are hidden from the Pending
     Changes screen, the failed list and the unsynced-work count. A
     shadowed action writes no App Log line for the twin (the primary's
     says what the user did) and does not clear the twin's local-only
     snooze source (nothing would restore it when the primary is
     cancelled). An acked shadow move waits for the destination copy like
     an own one (below), so an IMAP twin whose INBOX no longer lists the
     mail keeps its id instead of hiding and coming back as a new row.
   - **UIDs of a twin or a waiting row (review blocker).** A twin shown
     in a folder through a shadow, or a row whose acked move never learnt
     its new UID, keeps the source's UID; an IMAP change queued on it
     (star, move, delete for good, the wake-up's snooze cleanup) built
     from the shown folder and that UID would act on another mail there.
     `_markUidAfterQueuedMove` therefore marks `uidAfterMove` whenever the
     payload's folder is not the row's `srv_mailbox_path` (or a foldable
     move of any state puts it there), and the flush finds the mail by
     Message-ID, or fails the change.
   - **Primary and shadow** are queued in two transactions (the mirroring
     needs the account list, a watch query that would wait on a
     transaction it runs in): a crash between them leaves the twin
     without the shadow, which only delays its showing the change until
     its account reads it.
   - **Appear side of carry-over.** In `_settleAcked`, an acked move,
     snooze or unsnooze (not a shadow) whose row becomes gone after the
     ack while `srv_mailbox_path` is not its destination, whose row has a
     Message-ID, and which is the row's newest move, snooze, unsnooze or
     delete (a later delete for good the server confirmed must hide the
     row; the stale-answer fuzz found that resurrection), is kept instead
     of dropped: the row keeps showing
     in the destination (gone with a `local_mailbox_path`), `lease_until`
     records the deadline (`awaitAppearWindow`, 1 hour), and the clean-up
     rule keeps the row. The destination's next sync matches the new row
     in place (`awaitingRowFor`: gone, an acked op waiting with that
     destination, same Message-ID, unique), and the op settles as
     confirmed. When the destination's copy is stored already (that
     folder synced first), the absence carries the row over at once
     (`_settleGoneRows`: `waitingDestinationOf`, `storedCopyIn`), so the
     mail never shows twice. A successful sync of the destination that
     started after the wait began and did not match the mail ends it
     (`endAwaitedMoves`: another client moved it on or deleted it), and
     `expireAwaitedMoves` ends any wait older than the window; both run
     after a folder sync, not in the flush. An ended wait resolves as
     satisfied (`op.gone`), the row is hidden and cleaned up. A
     change queued on a waiting row is marked `uidAfterMove`
     (`_markUidAfterQueuedMove` counts the waiting acked move), so the
     flush finds the mail by Message-ID instead of acting on the source's
     UID in the destination.
   - **Unread-count delta** (§7). The IMAP `STATUS` loop and the JMAP
     `Mailbox/get` paths store the read sequence taken before the read in
     `unread_seq`; `observeMailboxes` adds `unreadDeltaSql`: over the rows
     with a pending/inflight/stuck/parked/shadow op or one acked after
     `unread_seq`, unread rows shown in the folder minus unread rows the
     server has there (`srv_*`, not gone), virtual rows excluded. It
     covers read/unread changes and moves, deletes and snoozes of unread
     mail. The v74 migration stamps the stored counts with the current
     read sequence, so changes acked before the upgrade are not counted
     on top of counts that reflect them. Limits: `srv_*` is the server's
     state as last read, not as of the count; a row read again after the
     count (its change confirmed and dropped) no longer adjusts it, so the
     folder shows the older count until the next count read (once per sync
     cycle); a row with one change the count reflects and another it does
     not can be off by one. A negative sum (a count read before mail it
     now has) shows 0 and logs `mailbox.unread_negative` once per folder.
     `EXPLAIN QUERY PLAN`: the delta is driven from the foldable ops
     (covering index `pending_changes_resource_state`, then the `emails`
     primary key), one probe per queued change and mailbox when it reruns
     on a write; no new index.
   - **Enforcement.** The allow-list of `check_email_writes.sh` loses the
     two `local_rows.dart` members (3 left: the new-row inserts of the
     IMAP fetch and the JMAP upsert, and Undo's restore); fixtures for an
     emails write in `local_rows.dart` (fails) and the writer calls
     (passes), and the allowed-member fixtures moved to `sync_jmap.dart`.
     `consistencyProblems` reports a shadow whose primary is gone or
     failed (field `shadow`), which the sampler's repair drops.
   - **App Log.** New warn lines where sync drops or rewrites local data:
     `email.local_row_matched`, `email.virtual_expired`,
     `pending_change.parked_expired`; `op.gone` now also for an expired
     wait. The `pending_change.no_server_id` warning remains only for a
     JMAP change whose row is gone.
   - **Tests.** `rows_without_server_copy_test.dart` (a JMAP row without
     a server id: parked, matched in place, expired; an acked move
     without a known location: shown in the destination while it waits,
     matched in place by the destination's copy, resolved after the
     window), `counterpart_shadow_test.dart` (shadow shown and never sent,
     Undo, ack and settle by the counterpart's read, an orphan found by
     the consistency check and dropped, delete, the hiding shadow and its
     settle, the unread delta), the self-send tests (parked, in place,
     Undo, expiry), Undo of a mirrored move with the original sent, the
     v73→v74 columns in the migration test, and the Stalwart backend test
     of #565 now also checks the row keeps its id and the parked star
     reaches the server. The stale-answer fuzz moves the app's clock past
     the wait when it settles (time passes while the queue drains).
     Review round: IMAP-twin tests (a star or move queued on a twin shown
     through a shadow is marked `uidAfterMove`; an acked shadow waits),
     `waiting_rows_sync_test.dart` (through the real IMAP sync: a note
     older than the expiry matched by the inbox sync that stores its
     delivery, the immediate carry-over when the destination synced first,
     the end of a wait when the destination's sync finds no copy), the
     parked delete for good (sent for an inbox arrival, refused for Junk),
     a second copy not matching a row again, Retry of an expired parked
     change, and a negative unread sum.
   - **Not done, documented.**
     - A foreign move whose source folder is synced before the
       destination still deletes the row and stores a new one (2c's
       gap): carrying it over needs the vanished row to wait without a
       change of the user's, which the clean-up rule does not allow;
       phase 6's mark-and-sweep (§6 "Force resync") is the place.
     - An IMAP move answered without COPYUID whose mail has no
       Message-ID (and no move-stable id) cannot be matched in its
       destination, so it still ends as a new row there. With a
       Message-ID, the flush's own search in the destination
       (`_retryImapMoveByMessageId`) already finds the new UID, so the
       wait above mainly covers a server whose search lags.
     - A failed primary takes its shadows along, and its Retry does not
       re-create them: the twin shows the change again only after the
       retried change is acked and the counterpart reads it.
     - A move mirrored onto a twin before v74 is a real change of the
       twin's account, and Undo actions stored before v74 captured it.
       Undo after the upgrade still cancels it with the original when
       nothing was sent. When the twin's change was sent but the
       original was cancelled, `moveEmail` back queues nothing on the
       source row (it is in place already) and so mirrors nothing: the
       twin stays where its sent change put it, and the user moves it
       back by hand. Only Undo actions from before the upgrade can hit
       this.
     - Undo's `restoreEmails` stays for rows sync cleaned up (§2 "Former
       writers"); with hidden rows it is rarely needed.

**Phase 5 — mailbox ops.** Offline folder create, rename, move and delete
(#1242), and the Snoozed placeholder. Left for it after 4b: the folder
rename and `_repointSnoozedPlaceholder` still rewrite rows and payloads
directly (`EmailStateWriter.renameFolder`) instead of being ops; a move
into a folder that does not exist yet is not parked on a `create_mailbox`
op (§7), so the `parked` state is used only by rows without a server copy;
a counterpart that does not know a folder hides its twin (shadow
`delete` with `awayFrom`) rather than parking a move on the folder's
creation.

As implemented, phase 5 is two PRs, both done:
1. **5a (done, schema v75):** the mailbox op infrastructure, create and
   rename, the Snoozed folder, and moves into a folder not created yet.
   SYNC.md §6b describes the behaviour.
   - **Schema.** `mailboxes` gets `srv_name`, `local_name`, `is_local` and
     `srv_seq` (the stamp of `srv_name`, as `srv_location_seq` for mail);
     `name` is effective, `COALESCE(local_name, srv_name)`; `display_path`
     is derived from the effective names. Mailbox ops are rows of
     `pending_changes` with `resource_type = 'Mailbox'` and
     `resource_id` = `mailboxes.id`: `create_mailbox` (`name`, `parent`
     path, `role`) and `rename_mailbox` (`name`). Mailbox ids are frozen
     like mail ids: sync looks rows up by `path` (new rows get
     `account:path`, or a random id when a renamed row keeps that one), so
     an ack never re-keys a row or its ops. No `local_hidden`, no parent
     overlay yet (5b).
   - **Migration.** `srv_name` = `name` for every row (no mailbox op
     existed). For each JMAP account with a queued snooze or unsnooze into
     the `Snoozed` stand-in, a local `Snoozed` row (role `snoozed`) and its
     `create_mailbox`: the flush no longer resolves the stand-in.
   - **Mailbox state writer** (`lib/data/repositories/mailbox_state_writer.dart`,
     the only writer of `mailboxes`): `createLocal` (one local row and op
     per uncached level; IMAP stand-in path = the likely server path, JMAP
     `~new:<random>`), `enqueueRename` (supersedes a queued or failed
     rename; back to the server's name queues nothing), `ensureLocal`
     (the Snoozed folder), the fold (`foldMailboxName`, `displayPaths`,
     `localMailboxShown` in `lib/data/db/mailbox_fold.dart`), the gate
     (`writeServer`: monotonic by `srv_seq`, `is_local = 0` for a listed
     folder, settles acked ops; `prunable`, `renamedAwaySince`), the flush
     outcomes (`ack`, `fail` with the dependents, `discard`, `retry`,
     `failOpsOfRemoved`, `failOrphanedWaiting`) and `serverPathChanged`.
   - **Flush** (`flush_mailbox.dart`, a part of the email repository so it
     shares the claim, lease, token and outcome helpers): mailbox ops of
     the account first, in `seq` order, then the mail changes. The
     outcomes of §5 apply; a refusal fails the op and its dependents. A
     clash on the first try is refused, not adopted (#1242: "a server-side
     name clash becomes a FailedMutation"); a try after one that may have
     been sent, or a role-create, looks the folder up first (§5
     idempotency).
   - **Ack.** Acked with `ack_seq`; the confirmed name, `is_local = 0` and
     a new server path are written at once, stamped. A path change
     (`serverPathChanged`) moves the row's `path`, its subfolders (IMAP),
     the JMAP children's `parentId`, queued creates naming it as parent,
     threads and checkpoints, and calls `EmailStateWriter.renameFolder`.
     The acked op is settled by the next folder listing started after the
     ack (agree: dropped; contradict twice: dropped, `op.contradicted`).
   - **`renameFolder` and the Snoozed placeholder** (point 2 of the brief).
     `renameFolder` is no longer called for a user action, only by the
     mailbox writer when the server confirmed a path (the IMAP rename's
     ack, a create's server id). It no longer writes `local_mailbox_path`
     or the effective folder of a pending move: it writes the server fact
     (`srv_mailbox_path`), re-points the queued payloads naming the folder
     (op data, §2 "rewrites the dest of the queued ops and re-folds") and
     re-folds their rows, so the folder a pending move shows comes from
     the fold. `_resolveJmapSnoozedMailbox` and `_repointSnoozedPlaceholder`
     are gone: a JMAP snooze without a known Snoozed folder queues its
     `create_mailbox` and waits for it. Decision: the queued payloads are
     still rewritten at the ack rather than resolved through an alias in
     the fold: an alias table would have to be applied at about 50 payload
     reads in the flush, the settle rules and Undo, and dropped only when
     no op or Undo action names the old path any more.
   - **Moves into a folder not created yet** (point 3, brought forward from
     5b because an offline create is unusable without it): a mail change
     naming an `is_local` folder is held by the flush
     (`_holdForLocalFolders`, uncharged, with the mail's later changes)
     instead of a `parked` state with promotion; the create's ack re-points
     it, so the same flush sends it. A failed, discarded or lost create
     fails it (`pending_change.folder_not_created`).
   - **Server-side changes** (point 5, for 5a's ops). A listing never
     prunes a local folder or one written after it started, and does not
     store again a path an acked IMAP rename moved away from (`fromPath`);
     a folder the server dropped fails its queued folder ops and the
     changes naming it (`pending_change.folder_removed`, listed).
   - **Enforcement.** `check_email_writes.sh` check 3: `mailboxes` is
     written only by the mailbox writer and the migrations (`_upgradeSteps`,
     `_overlayMailboxes`), fixtures in `test_check_email_writes.sh`. The
     email allow-list is unchanged (`renameFolder` was in the writer
     already). `MailboxStateWriter.consistencyProblems` / `checkAndRepair`,
     run by tests and by `OverlayConsistencySampler` after a sync run (all
     mailboxes of the account, repaired by a re-fold).
   - **App Log.** New: `mailbox.create`, `mailbox.rename` (info),
     `pending_change.folder_not_created`, `mailbox.local_merged`,
     `op.contradicted` for a folder; `pending_change.rejected`,
     `pending_change.folder_removed` and `pending_change.folder_renamed`
     now also for folder ops.
   - **Tests.** `mailbox_ops_test.dart` (the fold and display paths;
     IMAP on the stateful fake, which now has CREATE/RENAME/LIST/STATUS:
     offline create then move then flush, a refused create failing the
     move and Retry, a clash, Discard, delete of a local folder, offline
     rename with a move queued into the folder, a stale listing racing the
     rename's ack, a folder deleted on the server with a queued rename, a
     folder another client created; contradiction; JMAP: create, move,
     flush with the server's id, a refused create, rename and its
     settle), the rewritten create/rename tests of
     `mailbox_repository_impl_test.dart`, the JMAP Snoozed tests, the v75
     migration test, and the Stalwart backend tests (IMAP and JMAP:
     create, move into it and rename offline, flushed; a JMAP clash).
   - **Review fixes** (second commit, SYNC.md §6b "Review fixes"): local
     folders are never synced or removed as gone; the IMAP separator only
     from LIST; lost or in-flight renames protect their folder and are
     completed by the listing; read-confirmed creates settle on the next
     listing; stand-in paths resolved after the ack; removed folders fail
     queued child creates and drop their acked ops; Retry of a create
     brings its failed changes back; a listing never adopts a never-sent
     create (a clash stays a visible failure); `check_email_writes.sh`
     check 3 also catches the table's own write methods and `this._db.`.
2. **5b (done, schema v76):** folder move and delete as ops, the
   counterpart's stand-in folder, the IMAP Snoozed folder as an op, and
   renames made on another IMAP client. SYNC.md §6b "Move and delete (5b)"
   describes the behaviour.
   - **Schema.** `mailboxes.local_parent` (the fold of the latest foldable
     `move_mailbox`: the new parent's `path`, `''` for the top level) and
     `local_hidden` (a foldable `delete_mailbox`). Decision: no
     `srv_parent_id`; `parent_id` stays the server's JMAP parent (now gated by
     `srv_seq` like the name, and written by a move's ack), and the parent a
     folder shows below is computed (`effectiveMailboxParent`, used by the
     model, the display paths and the create's sibling check). A stored
     effective parent would have needed every writer of `parent_id`, the
     migration and the many tests that seed rows to keep two columns in step,
     for one `COALESCE` at read time. IMAP keeps the hierarchy in the path:
     `displayPaths` puts a folder with a `local_parent` (and its subfolders)
     below the new parent's display path.
   - **Ops.** `move_mailbox` (`parent`, `fromParent` for Undo) and
     `delete_mailbox` (`removeEmails`). `enqueueMove` supersedes a never-sent
     or failed move and queues nothing for a move back below the server's
     parent; `enqueueDelete` keeps a live delete and replaces a failed one.
     The repository refuses a delete of a folder with a subfolder that shows
     (as the UI did) and a move into the folder itself or a descendant.
   - **Hidden everywhere.** `mailboxShownSql` (observeMailboxes, so lists,
     counts, pickers and the sync loop; `findMailboxByRole`, `_findParent`),
     `syncEmails` (a hidden folder is not synced), the counterpart lookup,
     the account comparison, sync statistics and Sieve's JMAP folder lookup
     skip `local_hidden`.
   - **Flush** (`flush_mailbox.dart`). Move: waits for a local folder or a
     local new parent, refuses a `~new:` parent no folder has and a parent
     being deleted; IMAP `RENAME` (shared with the rename:
     `_renameImapTo`), JMAP `update {parentId}`. Delete: waits while a mail
     change queued before it names the folder or a subfolder, or a
     subfolder's op queued before it is not done (`subfolderOpQueued`); the
     flush runs the deletes again after the mail changes (`onlyDeletes`), so
     one flush empties and deletes. IMAP checks LIST (gone = done; server
     subfolders = refused) and, without `removeEmails`, STATUS; JMAP
     `destroy` (`notFound` = done). Outcomes as for 5a's ops.
   - **Ack.** A move's ack is a rename's (path change with `fromPath` on
     IMAP; `parent_id` written on JMAP), settled by the next listing on the
     parent (`mailboxReadAgrees` with `srvParent`). A delete is acked by
     `ackDelete`: the op stays `acked` with `fromPath` (kept by `deleteRow`)
     while `removeLocalMailbox(deletedByUser: true)` removes the cache with
     the online delete's semantics (changes naming it fail, mail marked
     gone, kept while a change of it is unsettled); `renamedAwaySince` keeps
     a stale listing (IMAP, and since 5b the JMAP `Mailbox/get` paths) from
     bringing it back, and the next listing drops it
     (`settleAckedDeletes`).
   - **Mail changes naming a folder being deleted.** Earlier ones go first
     (the delete waits); later ones that move mail into it are held while
     the delete is queued, being sent or stuck (`pathsBeingDeleted`), then
     fail with "folder deleted" (or are sent when the delete failed); later
     ones that take mail out of it are sent first and the delete waits
     (`mailLeavingQueuedFor`), also for a counterpart's shadow whose primary
     is not done. The mail of a hidden folder is out of the email queries
     (`_visible`). A delete with `removeEmails` stores the count the user
     agreed to (`messages`); more on the server refuses it. Retry of a
     failed delete drops the old `removeEmails`. `pathsBeingRenamed`
     covers moves and deletes being sent and, on IMAP, the subfolders; both
     the mail and the folder flush check again after their claim.
   - **Server-side changes.** A queued delete of a folder the server
     removed is done (`mailbox.delete_found_done`) instead of failed.
     `failOpsOfRemoved` and `_failDependentsOf` also fail moves into a
     removed or never-created folder. `prunable` keeps a folder and its
     IMAP subfolders while a rename or move of it may have reached the
     server (a 5a gap: the subfolders were pruned), and a folder whose
     delete is being sent; `completeLostRenames` also completes lost IMAP
     moves.
   - **IMAP rename on another client** (`_followRenamesElsewhere`): a
     vanished folder without a queued delete is taken for renamed to a new
     folder sharing its leaf or parent, when the match is unique both ways
     and the new folder has its checkpoint UIDVALIDITY (STATUS; servers
     that keep it across RENAME) confirmed by its cached Message-IDs, or,
     else, holds every Message-ID cached for it (up to 50, `UID SEARCH
     HEADER Message-ID`) with exactly the cached number of messages:
     Stalwart gives a renamed folder a new UIDVALIDITY (seen in the backend
     test), so it takes the second rule. Review fix: a folder with a queued
     delete is never followed (a wrong match would delete another folder);
     a subset of the mail or an ambiguous match is no rename. `serverPathChanged` follows it
     (`mailbox.renamed_elsewhere`). An empty or never-synced folder renamed
     on a server like Stalwart is not recognised: its queued changes fail
     visibly as before. `messageIdSearchCriteria` (`lib/data/imap/`) is
     shared with the flush's Message-ID search.
   - **Undo.** `undoFolderChange` (repository) / `undoLatest` (writer):
     a never-sent move or delete is cancelled; a sent move gets a move back
     to `fromParent`; a delete being sent or sent cannot be undone (worded
     apart). The folder snackbars offer it. An IMAP move into a parent the
     server does not list is refused (RENAME would create it), and a move
     waits while its parent's own rename or move may have been sent.
   - **The `parked` state for folder waits** (point 3 of the brief) was
     not built: the 5a hold is computed at every flush from the folders'
     `is_local`, needs no promotion step in any isolate, and a `parked`
     state would also be taken by the virtual-row expiry (7 days) and
     Undo's `cancelOps` rules. The Pending Changes screen still says
     "waiting for folder "X" to be created": `PendingChange.waitingForFolder`
     is derived when the queue is read.
   - **Counterpart** (`ensureCounterpartFolder`, `_adoptCounterpartFolder`,
     `dropOrphanedCounterpartFolders`): a twin whose account does not know
     the destination folder gets a shadow move into a stand-in folder of its
     own account, whose `create_mailbox` is a shadow of the primary move
     (never flushed; acked with it; `_ackShadows` acks a mailbox shadow
     instead of dropping it). A listing adopts the stand-in by path or by
     name (and JMAP parent); a stand-in whose shadow went, or that a listing
     started after the ack does not find, is dropped and the changes the
     user queued for it fail. Each move that needs a stand-in adds its own
     shadow create, so an Undo of one keeps the folder for the others.
     `_dropStaleCounterpartRow` is gone.
   - **IMAP Snoozed folder.** `_snoozeRow` queues the create on IMAP too; the
     snooze and unsnooze flush no longer create folders. The v76 migration
     queues the create for queued IMAP snoozes into a `Snoozed` path no
     mailbox has (`_queueSnoozedCreates`, shared with v75's JMAP step).
   - **Enforcement.** `check_email_writes.sh` check 3 allows
     `_queueSnoozedCreates`; new fixtures for it, a `local_hidden` write and
     a parent write outside the writer. `consistencyProblems` compares
     `local_parent` and `local_hidden` with the fold and allows the kept
     acked delete; `checkAndRepair` repairs by the same re-fold.
   - **App Log.** New warns: `mailbox.delete_found_done`,
     `mailbox.renamed_elsewhere`, `mailbox.counterpart_folder_adopted`,
     `mailbox.counterpart_folder_dropped`; `op.contradicted` for a move;
     `pending_change.folder_renamed` also for a move whose parent's path
     changed; `pending_change.folder_removed` ("folder deleted") for the
     changes a confirmed delete fails. Info: `mailbox.move`,
     `mailbox.delete`, `mailbox.undo`, `mailbox.counterpart_folder`.
   - **Tests.** `mailbox_ops_test.dart` (fold and display paths; IMAP:
     offline move with subfolders and mail, a listing during an in-flight
     move, offline delete with a stale listing, delete after the mail moved
     out in one flush, refused delete and Discard, `removeEmails` and a
     change queued after the delete, Undo of a delete and of a sent move, a
     delete found done, subfolder then parent, subfolders that show, a move
     into a folder created offline and into a refused one, a rename
     elsewhere followed and one not matched, the IMAP Snoozed create, the
     "waiting for folder" label; JMAP: move, move into a folder created
     offline, delete with a stale full listing, a refused delete and Retry),
     the rewritten counterpart tests, the v76 migration, and Stalwart
     backend tests (IMAP: move, mail moved out and delete in one flush, a
     rename on another client followed; JMAP: move, delete, a refused
     delete).
   - **Left for phase 6** (below).

**Phase 6 — clean-up.** Remove the remaining guard helpers, such as
`_pendingDeleteOrMoveUids` and the per-path queue checks, and update SYNC.md.
Also left for it after 5a: mark-and-sweep for force resync (§6), which
still deletes the mailbox rows without ops; the three allow-listed
new-row inserts of `emails`. Left after 5b: the queued mail payloads are
still rewritten when a folder's server path changes (an alias table was
decided against in 5a); an IMAP folder renamed and moved at once on
another client, or an empty or never-synced one renamed on a server that
gives it a new UIDVALIDITY, is not followed (its queued changes fail
visibly; a server MAILBOXID, RFC 8474, would close this); a counterpart stand-in for a
nested folder is made at the top level and adopted on JMAP only when the
server's folder is top level too (otherwise it is dropped after the
listing and the twin shows where its account reads it); a folder moved
while a stale listing runs can show twice until the move's ack merges
the rows (`mailbox.local_merged`), as in 5a for renames; a watched email query (search results open on screen) is not re-run
when only a folder's `local_hidden` changes, so it drops the mail of a
folder just deleted at its next refresh.

**Enforcement, from phase 3 on** (done in 3b, see there):
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

Since phase 2d the code is split by role. The parts are in
`lib/data/repositories/email_repository_impl/`; the class itself, its
fields and the public API forwarders stay in `email_repository_impl.dart`.

| Part | Role (groups below) |
|---|---|
| `sync.dart` | Sync: dispatch, `clearForResync` / `clearMailboxForResync`, `_backfillAddressHeaders` |
| `sync_imap.dart` | Sync: IMAP fetch and upsert, flag refresh and reconcile, size backfill, `_reconcileDeletedImap`, UIDVALIDITY (the late-FETCH location guard until 4a) |
| `sync_jmap.dart` | Sync: JMAP upsert, `notFound` / `destroyed`, prune, reconcile, sync state |
| `jmap_push.dart` | Sync: the JMAP EventSource watch (no row writes) |
| `row_identity.dart` | Sync and flush: rows by server location, `_relocateEmailRow`, `_carryOverMovedRow`, `_mergeDuplicateRow` |
| `bodies.dart` | Sync: bodies, attachments, raw messages, `_healMismatchedImapBody` |
| `change_queue.dart` | Flush and user actions: the op table (enqueue, claim, lease, Undo `captureOps` / `cancelOps`, `cancelPendingChange`, `retryMutation`) |
| `change_failures.dart` | Flush: `_recordChangeError`, stuck and failed changes, reverting failed flag and location changes |
| `flush_imap.dart` | Flush: `_applyPendingChangeImap`, `_settleImapChange`, `_remapEmailAfterImapMove`, `_retryImapMoveByMessageId` |
| `flush_jmap.dart` | Flush: `_applyPendingChangeJmap` (`_repointSnoozedPlaceholder` gone in 5a) |
| `flush_mailbox.dart` | Flush: mailbox ops (`_flushMailboxOps`: create, rename since 5a; move, delete since 5b) and the hold of mail changes that need a folder not created yet or being deleted |
| `user_actions.dart` | User actions: flags, `markAllAsRead`, move, delete, snooze, wake up, `restoreLocalSnooze`, `restoreEmails` |
| `counterparts.dart` | User actions: `_mirror*ToCounterparts` and `_dropStaleCounterpartRow` (shadow ops since 4b); sync: `_matchArrival` (the in-place match, 4b) |
| `sieve.dart` | User actions: Sieve `_enqueueSieveMove/Delete/Flags` |
| `local_rows.dart` | Local row creation: `_storeSentCopyLocally`, `_createLocalSelfMessages` (their row writes through the writer's `insertLocalRow` since 4b) |
| `send.dart` | Sending (SMTP, JMAP submission, outbox); its row writes go through `local_rows.dart` |
| `threads.dart` | Derived: `_updateThread`, `_reconcileSourceThreads`, `_sweepOrphanThreads` |
| `queries.dart`, `row_mapping.dart` | Reads and row ↔ model mapping (no writes) |
| `diagnostics.dart` | Diagnostics and the reliability probe (no row writes) |

The email state writer (§2) is `lib/data/repositories/email_state_writer.dart`
(phase 3a), outside the parts so `mailbox_repository_impl.dart` can use it.
Since phase 3b it also holds the row deletes, the header backfills and the
carry-over's whole-row copy, since 4a the location overlay, the clean-up
rule and the server location facts (`relocate`, `releaseLocation`,
`renameFolder`), since 4b the local rows (`insertLocalRow`), the parked-op
expiry, the shadow-op lifecycle and the appear side of carry-over, and
`scripts/check_email_writes.sh` lists the members that
still write `emails` themselves (allow-list, with the phase that moves
each). Since 5a the mailbox state writer
(`lib/data/repositories/mailbox_state_writer.dart`) is the only writer of
`mailboxes` (check 3 of the same script). The thread aggregate is `refreshThreadAggregate`
(`lib/data/repositories/thread_aggregate.dart`, 4a), shared with
`removeLocalMailbox`.

The line numbers below are from before the split (`33c67b4`).

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
- `_maybeDissolveLocalMessage` (5519), replaced by the in-place match
  (`_matchArrival`, 4b).
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
