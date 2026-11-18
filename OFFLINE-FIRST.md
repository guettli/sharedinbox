# Offline-first

SharedInbox must work without a network. Every user action takes effect
locally at once; the server catches up later. This file is the contract that
new features and reviews check against. The mechanics live in
[SYNC.md](SYNC.md) (pending-change queue, invariants).

## The rules

1. **Local first, in one step.** A user action writes the local DB and
   queues its server change in the same transaction (`pendingChanges`, the
   outbox, or a pending flag on the row like `email_notes.pending_upload`).
   The UI never awaits the network to show the result.
2. **Sync never undoes the user.** Every sync path that writes server data
   into the DB first checks for pending local changes, including changes made
   *while* the server request was in flight (see the guard in
   `EmailRepositoryImpl._startServerFlagRead`, #1234). A server answer older
   than the user's last edit must not win.
3. **No silent loss.** A queued change that can no longer be applied becomes
   a `FailedMutation` the user can see. Sync, prune and account removal never
   drop queued work without telling the user.
4. **Reads work from cache.** Anything the user has seen once (lists, bodies,
   notes, scripts) opens offline. Stale cache beats an error.
5. **Network-only actions say so.** An action that truly needs the server
   (adding an account, connection test) shows one consistent "needs a
   connection" message and keeps the user's input.
6. **Push from one place.** Only one isolate pushes a given queue, so an
   upload is not done twice (#1235: the background isolate only pulls notes).

## Review checklist

Ask for every change that adds or touches a user action or a sync path:

- Does it work with the network down? What does the user see?
- Where is the change queued, and in the same transaction as the local write?
- What does the next sync do with a row that has a pending change, or gets
  one while the sync's request is in flight?
- Is there an offline test, and a race test for the in-flight case?

## Known gaps

Found by an audit in November 2026. Each issue says how to confirm it.

| Issue | Gap |
|---|---|
| #1236 | Force resync while offline wipes local mail |
| #1237 | Remove account silently discards pending work |
| #1238 | JMAP `Email/get` upsert overwrites a pending move or snooze |
| #1239 | Sync drops queued changes when a folder or mail disappears |
| #1240 | `mailto:` unsubscribe bypasses the outbox |
| #1241 | A cached body older than 7 days does not open offline |
| #1243 | Sieve scripts are server-first |
| #1244 | Raw source and attachments need the network |
| #1245 | No consistent "needs a connection" UI |

Already offline-first: flags, move, delete, snooze, mark-all-read, drafts,
outbox / compose, undo, local search, notes (#1235), notification rules,
preferences, folder create, rename, move and delete (#1242, SYNC.md §6b).

## Enforcement

- #1246: offline smoke test plus a registry of user actions, checked like
  `check-layers`.
- #1247: shared test helper for "server answer arrives after a local change",
  and fuzz coverage for it.
- #1248: offline scenario in exploratory testing.
