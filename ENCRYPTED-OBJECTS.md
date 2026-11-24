# End-to-end encrypted objects (entries, flash cards)

Status: **design, not implemented yet.** Tracking epic: #1352.

This document is the **single source of truth** for format, clocks, merge
rules, folders and keys of the encrypted personal-data features. Issues only
describe scope and link to sections here. If an issue and this document
disagree, this document wins — fix the issue, or change this document in the
same PR that changes the behaviour.

## 1. Goal and scope

SharedInbox stores, besides mail, **personal data** on the user's own IMAP or
JMAP server, end-to-end encrypted and offline-first:

- **Entries** — one unified type for notes, todos and journal entries
  (section 6).
- **Flash cards** — Anki-like cards with FSRS scheduling (section 7).

No SharedInbox backend is involved. The mail server is only dumb, untrusted
storage. The UI reads only from the local Drift DB; the sync engine pushes and
pulls in the background (see `OFFLINE-FIRST.md`).

Not in scope (format is prepared for it, section 4.4): sharing collections
with other people.

## 2. Threat model

**Assets:** content of entries and cards, review history, images; the keys.

| Adversary | Protected? | Notes |
| --- | --- | --- |
| Mail provider / server admin reading the mailbox | **Yes**: content, titles, dates, type of object, done-state | Sees: the two folder names, number of mails, padded sizes, INTERNALDATE (≈ when something was written), how often an item is rewritten, which objects share a collection key (key id). |
| Server tampering (modify, swap, replay old mails, delete) | **Detect** modification and swapping (AEAD + item HMAC + AAD + collection check). Replay of old versions is blocked by the rollback guard (5.4). A mail vanishing without a tombstone never deletes local data (5.4). | **Deletion on the server cannot be prevented.** Mitigation: user deletes are explicit tombstones, so other devices keep and re-upload vanished objects; plus export (#1356). |
| Malicious server planting a key mail | **Yes** — slot lists are MAC'd; a device that already wrote objects never switches to a foreign key (4.3). | |
| Stolen, locked phone | As strong as the OS keystore (Android Keystore / iOS Keychain) and the optional SQLCipher DB encryption (`db_encryption_service.dart`). | The data key is readable without biometrics so background sync works (4.2). |
| Stolen, unlocked phone / malware on the device | **No.** | Out of scope. |
| Android auto backup / iCloud backup of the app DB | Content in the DB is plaintext unless SQLCipher is on; the data key in secure storage is device-bound and not part of the backup. | A restored DB gets a new deviceId (5.2). |
| Brute force of a passphrase slot by the provider | Only as strong as the passphrase (Argon2id). | The UI warns; recovery key and pairing are the recommended paths. |
| Provider keeps copies of deleted mails (Gmail All Mail, Exchange Recoverable Items) | Plaintext only matters for **migrated legacy notes** (#1355); everything else is ciphertext anyway. | The migration warns the user. |

**Before the first release that writes encrypted objects for real users, the
format (sections 4–5) gets a review by a human with cryptography experience.**
Until then the features stay behind the debug flag (section 9).

## 3. Folders

Exactly two folders per account:

- `SharedInbox/Keys` — key mails (section 4) and short-lived pairing mails.
- `SharedInbox/Data` — every object: entries, cards, card batches, review-log
  segments and packs, blobs (images), device-state docs.

The object kind is only inside the ciphertext. Paths are built with the
hierarchy separator from `imapPathSeparator()` (`mailbox_repository_impl.dart`)
and the personal NAMESPACE prefix (e.g. `INBOX.`); JMAP creates `SharedInbox`
and its children via `Mailbox/set` with `parentId`.

App folders are **hidden from the mailbox list and excluded from every
mail-sync loop** via a new `isAppDataFolder(mailbox)`
(`lib/core/models/mailbox.dart`), which matches the mailbox id/path recorded
by the store, never a display name. Apply it at every call site of
`isDuplicateOfOtherFolders` (`account_sync_manager.dart`, `sync_jmap.dart`),
in `reliability_runner.dart`, and in the mailbox list, search scope and
move-target picker.

Sync checkpoints live in `SyncStates` with `resourceType` `mos:keys` and
`mos:data` (never an `IMAP:`/`JMAP:` prefix — those belong to mail sync).
The checkpoint is JSON `{uidValidity, lastUid, uidNext, messages}`; a
`STATUS` equal to it skips the folder. The personal NAMESPACE prefix is
cached under `mos:namespace`; the folder listing matches app folders at the
top level and under that prefix (e.g. `INBOX.SharedInbox.Data`).

**IMAP store (#1370)**: `MailObjectStoreImap`
(`lib/data/repositories/mail_object_store_imap.dart`). Tables (schema v82):
`mail_objects` (one row per version, keyed by `(accountId, messageId)`;
`payload` holds the outer RFC 5322 mail, i.e. **ciphertext**; head columns
are filled once a key opens it), `mail_object_uids` (the UID → Message-ID /
item-HMAC index), `mail_object_clocks` (the per-item version vector of
5.4) and `mail_object_devices` (the DB side of the deviceId, 5.3). Until
the beta switch, the store only pulls folders the listing recorded and
creates folders only for a local row to upload. For the key lifecycle
(#1366) it treats `SharedInbox/Keys` as opaque raw mails: `observe`,
`appendRaw` (idempotent by Message-ID), `deleteRaw` (foreground) and
`reopen` after an unlock. A key mail that vanishes is uploaded again only
if the key lifecycle keeps it (`KeepVanishedKeyMail`, 4.3).

**Key lifecycle (#1366)**: `EncryptedKeyService`
(`lib/core/services/encrypted_key_service.dart`) reads and writes the key
mails through the store, runs the race of 4.3 and unlocks with the recovery
key; it fills one in-memory `KeyRing` (`key_ring.dart`) that the store uses
as its key lookups (also in the background isolate). Its state per account
is the `SyncStates` row `mos:key-state`, JSON
`{phase: none|pending|won|lost, ownMessageId, committed}` — never key
material. It runs after each object sync (`afterSync`), only while the
"Personal data (beta)" switch (`UserPreferences.personalDataBeta`, schema
v83) is on; the background only reads.

**JMAP store (#1371)**: `MailObjectStoreJmap`
(`lib/data/repositories/mail_object_store_jmap.dart`); the transport-free
part (local-first writes, merge, version vector, HLC, vanished and missing
folders) is `MailObjectStoreBase`, and `MailObjectStoreRouter` sends each
call to the store of the account's type. Same tables, no UID index:
`mail_objects.serverId` holds the JMAP email id. The folders are found by
`Mailbox/get` (top-level `SharedInbox`, children `Keys`/`Data`), recorded by
mailbox id, and made with `Mailbox/set` only for a row to upload. The
checkpoint under `mos:keys`/`mos:data` is `{mailboxId, queryState,
emailState}`: a pull asks `Email/queryChanges` (inMailbox) and
`Email/changes` (followed while `hasMoreChanges`); without a checkpoint, for
another mailbox id, or on `cannotCalculateChanges` / `tooManyChanges` /
`unsupportedFilter` / `invalidArguments` (Stalwart, for a state it cannot
parse) it lists the mailbox again (`mos.full_resync`): rows the
listing lacks are gone (5.4), rows are matched by Message-ID, so nothing is
uploaded twice. Upload: blob upload + `Email/import` with `$seen`, no
`receivedAt`; first a `header` filter on the Message-ID (each hit checked
exactly), and `alreadyExists` confirms with its `existingId`. A superseded
version (and a duplicate email of a version) is destroyed in an `Email/set`
of its own, after the import of its successor was confirmed. `maxSizeUpload`
is cached under `mos:maxSizeUpload`; `put` seals at most what fits into it
after base64 and headers (`ObjectTooLargeException`), and a row too large
for the server stays local (`mos.push.too_large`). The background isolate
only pulls.

**Logs, blobs, device-state (#1372)**: all three are ordinary documents in
`SharedInbox/Data` (`log_segment.dart`, `device_state.dart`), and the merge
projects their heads into tables (schema v84). `mail_object_log_events`
holds every event of a `<log>-seg` / `<log>-pack`, keyed by
`(accountId, log, deviceId, seq)`, so events are deduped by the key and
outlive their segment. `mail_object_device_states` holds one row per key and
device; the effective value of a key is the one with the highest HLC.
`mail_object_blobs` is the decrypted blob cache. A segment or pack that a
pack covers gets `mail_objects.coveredBy` (the pack's Message-ID) and is
hidden from readers. If it vanishes from the server it is dropped, not
uploaded again. Only rows of this device are also marked `pendingDelete`.
Such a delete waits until the pack is confirmed (`deletableNow`): APPEND →
confirm (APPENDUID, or by Message-ID) → expunge. `compact` writes the pack
and marks the covered rows in one transaction, so a crash in between is
repaired by the next sync. The services are `MailObjectLog` (`append`,
`segments`, `events`, `compact`; owner-only through `CompactionAuthority`,
which #1382 extends with the 90-day takeover), `MailObjectBlobStore`
(`putBlob`, `blob`; blobs are immutable) and `DeviceStateStore`. The blob
cache holds 100 MiB of decrypted bytes per account. Eviction drops the
least recently used confirmed blobs, and for those over 256 KiB also the
local ciphertext (the next read downloads it again). A pending blob is
never evicted.

## 4. Keys

### 4.1 Hierarchy

```text
account key  (per mail account, random 256 bit, accountKeyId = 16 random bytes)
  ├─ HKDF ─> k_slots (MAC over the slot list)
  ├─ HKDF ─> k_wrap  (wraps collection keys)
  └─ wraps ─> collection key  (per collection, random 256 bit, keyId = 16 random bytes)
                 ├─ HKDF ─> k_obj   (object AEAD)
                 └─ HKDF ─> k_item  (item-id HMAC)
```

- **Account key**: one per mail account (the key mail lives in that account;
  accounts may be used on different sets of devices). Local storage key
  `enc-account-key/<accountId>`.
- **Collection**: the unit of encryption — and later of sharing. Every
  account has a default collection `personal`. A todo list, a journal, a
  notebook or a card deck *may* be its own collection; v1 UI only needs
  `personal` plus one collection per card deck.
- **Review logs always use the `personal` collection**, even for cards of
  another (later possibly shared) deck — one's own study history is never
  shared.
- HKDF-SHA256 with **empty salt** and these info strings: `sharedinbox-obj-v1`,
  `sharedinbox-itemid-hmac-v1`, `sharedinbox-slots-mac-v1`,
  `sharedinbox-collection-wrap-v1`, `sharedinbox-kek-recovery-v1`,
  `sharedinbox-kek-passphrase-v1`, `sharedinbox-kek-passkey-v1`,
  `sharedinbox-pairing-v1`. Never use a root key directly.
- Collection keys are wrapped under the derived wrap key (same AEAD as the
  slots), AAD =
  `"SICK1" ‖ accountKeyId ‖ collectionId ‖ keyId ‖ wrapType`, so the server
  cannot relabel a key (e.g. a deck key as `personal`).
- A reader **rejects an object whose head `collectionId` differs from the
  collection that `keyId` belongs to.**
- A blob belongs to the collection of the object that references it;
  `si-img:` resolves only within the same collection. Moving an item to
  another collection = a new itemId in the target + a tombstone of the old one.

### 4.2 Unlock slots (key mail)

The key mail in `SharedInbox/Keys` holds `accountKeyId`, the account key
wrapped in **slots** (like LUKS) and `slotListVersion` (monotonic), as one
`application/json` part; the MAC (HMAC-SHA256 with `k_slots`) covers **the
exact stored bytes of that part** and is carried next to it. Slot AEAD:
XChaCha20-Poly1305, fresh random 24-byte nonce,
AAD = `accountKeyId ‖ slotId ‖ type`.

**Key-mail lifecycle:** changing slots appends a new key mail with
`slotListVersion + 1`, then deletes the old one. Key mails are grouped by
`accountKeyId`; within a group the highest valid `slotListVersion` wins;
equal versions with different slots merge (union) into version N+1.
**Removing a slot is not revocation** — old key mails may persist on the
server or in backups. A compromised slot needs account-key rotation
(new account key, re-wrap all collection keys; 4.5).

| Slot | KEK | Notes |
| --- | --- | --- |
| `recovery` (mandatory, created first) | HKDF(recovery key) | Recovery key = 128 bit random + 32 bit SHA-256 checksum = 160 bit = 32 Crockford base32 chars, shown as 8 groups of 4; shown once, printable, QR. |
| `passphrase` (optional) | Argon2id(passphrase, salt) | Salt = 16 random bytes stored in the slot. Defaults m=64 MiB, t=3, p=1 (pure-Dart `cryptography`, run in an isolate); the params used are stored in the slot. Minimum strength + warning. |
| `passkey-prf` (optional, #1360) | HKDF(WebAuthn PRF output) | One labelled slot per added passkey; credential id and PRF salt in clear in the slot. |

Not slots, but ways to get the key onto a device:

- **Device storage**: the unwrapped account key in `flutter_secure_storage`,
  **without a biometric gate**, so the background isolate can decrypt. On iOS
  this needs per-key `IOSOptions(accessibility: first_unlock_this_device)` —
  new in the storage wrapper (`lib/data/storage/flutter_secure_storage_impl.dart`
  uses the package default today). A biometric app lock may come later as a
  UI-only feature.
- **Pairing**: an unlocked device sends the account key to a new device via
  X25519/ECIES (`ShareEncryptionService.encryptBytes`, info
  `sharedinbox-pairing-v1`). The new device's ephemeral **public key travels
  only out-of-band** (QR shown by the new device, or paste) — never via the
  server, which could otherwise sit in the middle. Linux cannot scan QR codes
  (`mobile_scanner`), so the *reply* goes as a pairing mail in
  `SharedInbox/Keys` encrypted to that public key (fallback: paste). The
  pairing plaintext includes `accountKeyId`; the receiver checks the key
  against the slot-list MAC of the **winning** key mail (4.3), matches the
  account by server + username, deletes the pairing mail; it expires after
  `ShareKeyMaterial.lifetime` (20 min).
  - The request carries `keyId ‖ publicKey` plus the server and username of
    the account (server: the lowercased IMAP host, or the host of the JMAP
    URL; username: the login username, or the email if it is empty, also
    lowercased). The **sender refuses** a request of another account before
    it encrypts anything.
  - The receiver's key pair is stored with a 20-min expiry (it survives an
    app restart). The receiver rejects a payload whose key pair is unknown or
    expired, whose `issuedAt` is older than 20 min or more than 5 min in the
    future, of another account, that does not authenticate, or whose key is
    not the winning group's or fails its slot-list MAC.
  - A pairing mail is never uploaded again when it vanishes. Every device
    with the beta switch on deletes pairing mails whose `Date` is older than
    20 + 5 min in its **foreground** keys-folder sync; pairing mails of other
    devices are otherwise left alone.

Only an unlocked device may add or remove slots.

**Passphrase slot** (`lib/core/encrypted_objects/passphrase.dart`):

- KEK = HKDF(Argon2id(passphrase, salt), `sharedinbox-kek-passphrase-v1`);
  Argon2id gives 32 bytes, the passphrase is its exact UTF-8 bytes (no
  trimming, no normalization).
- Slot fields next to the known ones: `salt` (16 random bytes, base64url)
  and `kdf: {"alg": "argon2id", "v": 19, "m": <KiB>, "t": <iterations>,
  "p": <parallelism>}`. Unlock always reads them from the slot. The slot MAC
  can only be checked after the unwrap, so params above the caps
  `m ≤ 262144` (256 MiB), `t ≤ 10`, `p ≤ 4` (or another `alg`/`v`) make the
  slot invalid; it is skipped.
- Minimum strength: at least 12 characters; not on the bundled list of
  common passwords (also not a common word with a few digits or symbols);
  no single character or short unit repeated, at most 3 distinct
  characters, no runs along the alphabet, the digits or a keyboard row; not
  containing the email address, its local part or the username (3+
  characters, case-insensitive).
- At most one passphrase slot per account: changing it replaces the slot in
  the same key-mail rewrite.
- Changing slots needs the server: the keys folder is pulled first and,
  offline, nothing is written. The old key mails are deleted only after the
  server took the new one.

**Passkey slot** (`lib/core/encrypted_objects/passkey_slot.dart`):

- KEK = HKDF(PRF output, `sharedinbox-kek-passkey-v1`); the PRF output is
  `prf.results.first` (32 bytes) of a WebAuthn assertion with the PRF
  extension. No server takes part: the challenge is 32 random bytes made on
  the device, and only the PRF output is used, never the signature.
- Slot fields next to the known ones, all in clear: `credentialId`
  (base64url), `prfSalt` (32 random bytes, base64url; the PRF input),
  `rpId` (`sharedinbox.de`) and `label` (chosen by the user, e.g. the name
  of the password manager; may be empty). A slot with a missing or
  malformed field is skipped.
- Each "Add passkey" registers a new discoverable passkey (`residentKey` and
  `userVerification` required) and adds one more slot; "one slot per
  password manager" is a convention, not a limit. Right after creating it,
  the device evaluates the PRF of the new credential with the new salt and
  checks that the new slot opens; a password manager without PRF (or one
  that answers with another credential) fails cleanly and nothing is
  written. Each passkey slot can be removed on its own; the `recovery` slot
  always stays.
- Unlock asks once for any of the passkeys of every key mail
  (`allowCredentials` + `extensions.prf.evalByCredential`, one salt per
  credential) and tries the slots of the credential that answered. It works
  offline from the key mails seen before.
- Deleting the passkey in the password manager removes this way to unlock.
- Android only for now (Credential Manager; `assetlinks.json` with
  `delegate_permission/common.get_login_creds` for `de.sharedinbox.mua` on
  `sharedinbox.de`). Linux, iOS and macOS show no passkey UI.

### 4.3 Key creation race and missing key folder

- Two devices creating a key at the same time: after APPEND, re-list the
  folder. Winner = the `accountKeyId` group whose **first** key mail has the
  lowest IMAP UID (JMAP: earliest `receivedAt`, tie → lowest accountKeyId).
  Later key mails of the same group (slot changes) do not affect the race. The
  recovery key is shown **only after** the re-list confirmed the win.
- A device that has already written objects with its key **never yields**; a
  foreign key mail appearing later only raises a warning. Unlock tries every
  key mail in the folder.
- `SharedInbox/Keys` missing while this device holds the key: re-upload from
  the local copy of the key mail. **Never wipe a local key because a folder
  is missing.**
- A device that lost the race never shows its recovery key and never keeps
  its key; it deletes its own key mail in the **foreground only, after the
  re-list** confirmed the loss, and offers the unlock. The re-list is a pull
  after the own APPEND was confirmed, so every key mail with a lower UID is
  seen.
- A setup interrupted between APPEND and the decision (`phase: pending`;
  the new key waits under `enc-account-key-pending/<accountId>`) is decided
  from the listing by the next foreground run. A loss is cleaned up as
  above; a win gets a **fresh recovery slot** (the first recovery key was
  never shown): a new key mail at `slotListVersion + 1`, then the old one
  is deleted.
- A vanished keys-folder mail is uploaded again only when it is the own
  pending key mail, the newest key mail of the key this device holds, or a
  collection-key mail of that key. A race loser's mail, a replaced slot list
  and mails of a key this device does not hold are dropped locally, so other
  devices do not resurrect them.
- The first write with a key marks the device `committed`; after that a
  foreign `accountKeyId` group only raises a warning (`mos.foreign_key_mail`
  with a count).

### 4.4 Prepared for sharing (not implemented)

A collection key mail (`kind: collection-key`, in `SharedInbox/Keys`) holds a
list of **wraps**: v1 has exactly one, `{type: account, wrapped}`. Sharing
later adds `{type: x25519, recipient, wrapped}` wraps; existing objects are not
re-encrypted. How another person reaches the objects (IMAP ACL shared folders,
copying between mailboxes) is undecided and out of scope.

### 4.5 Rotation (not implemented, path defined)

Account-key rotation: new account key and key mail (new `accountKeyId`),
all collection keys re-wrapped, old key mails deleted. Collection-key
rotation: a new collection key gets a new `keyId`; new writes use it; old objects are
re-encrypted lazily on their next edit or by a background job; the old key
is kept until no object references it. Rotation does not protect data that a
lost device already had.

### 4.6 Wire details

Implemented in `lib/core/encrypted_objects/` (pure Dart).

- **AAD encoding**: fixed-size 16-byte ids are written raw; every string
  field is written as `enc(s) = u16be(len) ‖ utf8(s)`.
  - Slot AAD: `accountKeyId (16) ‖ slotId (16) ‖ enc(type)`.
  - Collection-key wrap AAD:
    `"SICK1" ‖ accountKeyId (16) ‖ enc(collectionId) ‖ keyId (16) ‖ enc(wrapType)`.
- `slotId`: 16 random bytes for every slot, including `recovery`.
- Wrapped values are `ciphertext ‖ tag (16)` of the raw 32-byte key.
- In JSON, every binary value is **base64url without padding**.
- Key mail (`application/json`):
  `{"v": 1, "kind": "account-key", "accountKeyId", "slotListVersion", "slots": [...]}`;
  a slot is `{"slotId", "type", "nonce", "wrapped", ...}` (types
  `recovery`, `passphrase`, `passkey-prf`; type-specific fields such as the
  passphrase salt and params or the passkey `credentialId`, `prfSalt`,
  `rpId` and `label` sit next to them). The MAC is
  HMAC-SHA256(`k_slots`, the exact stored bytes) — never a re-serialization;
  JSON with the same content in another key order does not verify.
- Collection-key mail (`application/json`, no separate MAC):
  `{"v": 1, "kind": "collection-key", "accountKeyId", "collectionId", "keyId", "wraps": [{"type": "account", "nonce", "wrapped"}]}`.
- Readers preserve unknown fields (top level, slots, wraps) and skip unknown
  wrap types.
- **Outer key mail** (`key_mail_message.dart`): `Date`, `Subject:
  SharedInbox key`, `Message-ID` (as in 5.6), `MIME-Version`,
  `X-SharedInbox-Schema: 1`, `X-SharedInbox-Key-Kind: account-key |
  collection-key`, then `multipart/mixed` with a `7bit` `text/plain` notice
  and the JSON as a `base64` `application/json` part (76-char lines, CRLF).
  An account-key mail carries its MAC as the part header
  `X-SharedInbox-Key-Mac: base64url(mac)`; it covers the **decoded** part
  bytes. A reader rejects a missing or duplicate MAC header, another schema
  or kind, and any other mail (e.g. a pairing mail).
- **Pairing** (`pairing.dart`):
  - Request: `sharedinbox.de:pair:v1:<base64url(keyId (16) ‖ publicKey (32)
    ‖ enc(server) ‖ enc(username))>`; its own prefix, so an account-transfer
    code is rejected.
  - Plaintext (JSON, encrypted with `ShareEncryptionService.encryptBytes`,
    info `sharedinbox-pairing-v1`, to the request's key):
    `{"v": 1, "kind": "pairing", "accountKeyId", "accountKey", "server",
    "username", "issuedAt"}`; `issuedAt` is ISO 8601 UTC.
  - Pairing mail: `Date`, `Subject: SharedInbox pairing`, `Message-ID`,
    `MIME-Version`, `X-SharedInbox-Schema: 1`, `X-SharedInbox-Key-Kind:
    pairing`, and one `base64` `application/octet-stream` body with the
    ECIES bytes `keyId ‖ ephPub ‖ nonce ‖ ciphertext ‖ mac`.
  - Paste fallback: `sharedinbox.de:pairing:v1:<base64url(ECIES bytes)>`.
- **Recovery key**: checksum = the first 4 bytes of SHA-256 of the raw 16
  bytes; `raw ‖ checksum` (160 bit) is written MSB-first in Crockford base32
  (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`) as 8 groups of 4 joined by `-`.
  Parsing is case-insensitive, ignores spaces, `-` and `_`, and reads `O` as
  `0` and `I`/`L` as `1`. The KEK input is the raw 16 bytes only (not the
  checksum).
- **Merge** of equal `slotListVersion`s: union of slots by `slotId` at
  `max + 1`; for the same `slotId` with different content (and for a
  conflicting unknown top-level field) the value whose canonical JSON
  (recursively sorted keys) sorts smallest wins. Slots are written in
  `slotId` order, so the result does not depend on the input order.

## 5. Object format

### 5.1 Outer mail (RFC 5322)

- `Subject: SharedInbox item`, `Message-ID:
  <base32(16 random bytes)@sharedinbox.invalid>` (valid RFC 5322, no real
  hostname; chosen **before** upload and persisted, it identifies this
  *version*), `\Seen`. Mails with the same item HMAC and versionId are one
  version; expunge duplicates.
- Header `X-SharedInbox-Schema: 1`.
- Header `X-SharedInbox-Item: base64url(HMAC-SHA256(k_item, itemId))`.
- `multipart/mixed`: a short `text/plain` "encrypted SharedInbox data, do not
  delete" + one `application/octet-stream` part with this byte layout:

```text
"SIE1" (4) ‖ keyId (16) ‖ nonce (24) ‖ XChaCha20-Poly1305_k_obj( u32be len ‖ innerMIME ‖ zero padding )
AAD = "SIE1" ‖ keyId ‖ itemHmac (raw 32 bytes)     -- built from parsed values, never raw header bytes
```

- **Padding**: with `P = 4 + len(innerMIME)`, the padded length is
  `max(1024, nextPow2(P))` if `P ≤ 64 KiB`, else `ceil(P / 64 KiB) · 64 KiB`.
- **Size limit**: ciphertext ≤ 8 MiB per mail (≈ 11 MB after base64; below
  Gmail / M365 limits) and ≤ JMAP `maxSizeUpload`. Larger blobs are rejected
  with a user-visible error (chunking is a later issue).
- After decrypting, check `HMAC(k_item, itemId) == X-SharedInbox-Item`.
- JMAP uploads the **same RFC 5322 bytes** via the upload endpoint +
  `Email/import` (one format, one parser; omit `receivedAt`).

### 5.2 Inner MIME

`multipart/related`:

1. `application/json` head:
   `{v: 1, itemId, collectionId, versionId, parents: [versionId…], deleted?, kind, ...kind fields}`.
   `itemId`, `collectionId`, `versionId`, `parents` and `deleted` are a
   **`v`-independent prefix** every future version must keep, so every reader
   can always build the version graph.
2. content parts, e.g. `text/markdown`, small images (< 50 KiB) as `cid:`.

**Forward compatibility:** readers ignore unknown `kind`s and unknown fields,
and **preserve unknown fields when rewriting** an object. An item whose head
has a `v` the reader cannot parse is kept untouched, shown as "needs a newer
app" and **never edited** by that reader (editing would fork history).

### 5.3 Identity and clocks (used by all features)

- **deviceId**: 16 random bytes per install per account (22 chars
  base64url); stored in the DB *and* in a secure-storage marker that also
  holds the HLC and `seq` high-water marks. Marker missing or not matching the
  DB (DB restored by Android auto backup; iOS keychain surviving a reinstall
  with a rolled-back DB) → **new deviceId**. Before the first write, advance
  HLC and `seq` past everything with this deviceId seen locally or on the server.
- **HLC**: `(wallMs, counter, deviceId)`, encoded as a sortable string
  `wallMs` (13 decimal digits) `-` counter (4 hex digits) `-` deviceId;
  standard HLC send/receive rules; a remote timestamp > now + 5 min is not
  used to advance the local clock.
- **versionId** = the HLC of the write (it contains the deviceId).

### 5.4 Object classes and merge rules

1. **Document** — one mail per object; an edit writes a new version and,
   **only after the server confirmed it** (IMAP APPEND OK / APPENDUID; JMAP
   `created`), deletes the old one (IMAP `UID EXPUNGE` via
   `deleteAndExpungeUids`, Gmail via a new MOVE-to-Trash helper (5.5); JMAP a
   **separate** `Email/set` destroy — never create and destroy in one call).
   - **User delete = a tombstone version** `{deleted: true, parents: [heads]}`;
     superseded versions are expunged, the tombstone stays (small).
   - **A mail that vanishes from the server without a tombstone never deletes
     local data**: the device re-uploads its head and logs a warning
     (OFFLINE-FIRST rule: the server is not trusted to delete).
   - **Superseded**: a version whose versionId appears in another version's
     `parents`, or an older version of a device that has a newer accepted
     version of the item (a device's versions are linear, so it is an
     ancestor even when the version between them never reached this
     device) → deleted silently (foreground only).
   - **Heads**: the rest. One head = normal. Several heads = **conflict**: the
     newest HLC is shown, all heads are listed in the conflict view, never
     silently deleted. Heads with identical content resolve automatically:
     they count as **one logical head** (no conflict badge) and nothing is
     written for them; the next real edit collapses them with
     `parents = [all heads]`. Resolving writes a version with
     `parents = [all heads]`.
   - **Rollback guard**: per item a local version vector
     `deviceId → max HLC seen`. A device's versions of one item are linear, so
     a version V is accepted only if `V.hlc > vv[V.deviceId]`; otherwise it is
     a replay and ignored.
   - Edit on one device and delete on another → two heads (an edit and a
     tombstone) → a normal conflict.
   - **Idempotent upload** checks the version's `Message-ID`
     (`messageIdSearchCriteria`, JMAP `header` filter), **not** the item HMAC
     (all versions share it).
2. **Log segment** — an immutable batch of events, identity
   `(deviceId, seq)` per event; only the **owning device** compacts its own
   segments into a pack (APPEND pack → confirm → expunge covered segments;
   without UIDPLUS confirm by re-fetching the pack's `Message-ID`). Readers
   ignore segments covered by a pack and **always dedupe events by
   `(deviceId, seq)`**, so overlapping packs after a crash are harmless. A
   pack may cover segments and older packs of the same open month (`covers`
   lists `(deviceId, seqFrom, seqTo)` ranges). Segments of a deviceId not seen
   for 90 days may be compacted by any device. A deleted segment never means
   its events are gone.
3. **Blob** — immutable document (image), referenced by its itemId.
4. **Device-state** — one document per device (a key → value map with an HLC
   per key); the effective value of a key is the one with the highest HLC
   across all devices' docs; a value `null` means unset.

### 5.5 Provider specifics

- **Gmail** (`X-GM-EXT-1`): expunge from a label only removes the label.
  Delete = MOVE to `\Trash`, then `UID EXPUNGE` the COPYUID there.
  Without COPYUID the copy is found in Trash by Message-ID. Without a
  `\Trash` folder the superseded version stays on the server (harmless: the
  merge keeps it superseded) and a warning is logged.
- **No UIDPLUS**: no APPENDUID/COPYUID — confirm by `Message-ID` search.
- **No reliable `SEARCH HEADER`** (Exchange/M365 reportedly): use the local
  UID → item-HMAC index filled during sync.
- Sync fetches headers + `RFC822.SIZE`; bodies ≤ 256 KiB eagerly, larger ones
  (blobs) on demand.
- The background isolate only pulls and **never deletes on the server**.

### 5.6 Wire details

Implemented in `lib/core/encrypted_objects/` (`envelope.dart`,
`inner_mime.dart`, `object_mail.dart`, `hlc.dart`, `device_identity.dart`,
`merge.dart`; pure Dart).

- **itemId**: any string; new ones are base64url (no padding) of 16 random
  bytes (22 chars). The item HMAC is `HMAC-SHA256(k_item, utf8(itemId))`.
- **Message-ID**: `<` + RFC 4648 base32 of 16 random bytes, lowercase,
  without padding (26 chars) + `@sharedinbox.invalid>`.
- **Outer mail**: `Date`, `Subject`, `Message-ID`, `MIME-Version`,
  `X-SharedInbox-Schema`, `X-SharedInbox-Item`, then `multipart/mixed` with a
  `7bit` `text/plain` notice and the blob as a `base64`
  `application/octet-stream` part (76-char lines, CRLF). A reader rejects a
  missing header, a schema other than `1` and a mail without that part.
- **Inner MIME**: `multipart/related; type="application/json"`, CRLF line
  endings, boundary `si-` + base64url of 12 random bytes (redrawn if a part
  contains it). The JSON head (`application/json; charset=utf-8`) is the
  first part; every part is written with `Content-Transfer-Encoding: binary`
  (it is inside the ciphertext); readers also accept `8bit`, `7bit` and
  `base64`. Unknown parts are kept.
- **Size limit**: the 8 MiB rule applies to the whole envelope blob (the
  decoded `application/octet-stream` part, header and tag included); a
  smaller JMAP `maxSizeUpload` lowers it.
- **Open order**: magic and minimum length, size, `keyId` known, AEAD,
  `len ≤ plaintext − 4`; then the inner MIME is parsed and
  `HMAC(k_item, head.itemId)` must equal the item header and
  `head.collectionId` the collection of `keyId`.
- **HLC**: fields are read at fixed positions (`deviceId` may contain `-`).
  If the counter would pass `ffff`, `wallMs` goes up by 1 and the counter
  restarts at 0.
- **deviceId marker**: secure-storage key `enc-device-marker/<accountId>`
  (`first_unlock_this_device`), JSON `{deviceId, hlcHigh, seqHigh}`. A new
  deviceId is created if the marker is missing or corrupt, the DB has no
  record, the deviceIds differ, or a marker high-water mark is above the
  DB's (DB rolled back). The DB is written before the marker, so a marker
  that lags behind the DB is harmless.
- **contentDigest** (identical-content check of 5.4): SHA-256 over
  `u32be(len) ‖ bytes` of the canonical JSON of the head without `versionId`
  and `parents`, then of every part's content type, Content-ID (empty if
  none) and bytes.

## 6. Entries (notes, todos, journal)

One kind `entry`. Fields in the JSON head:

| Field | Meaning |
| --- | --- |
| `title` (optional) | |
| `tags` | list of strings |
| `date` (optional, `YYYY-MM-DD`) | makes it a **journal** entry |
| `task` (optional) `{due?, priority?, done, doneAt?}` | makes it a **todo** |
| `links` | list of RFC 2822 Message-IDs of mails it belongs to (former "email notes") |
| `createdAt` (optional, ISO 8601) | when it was created, e.g. the date of a migrated note; lists sort by it, else by the version's wall clock |

Body: a `text/markdown` part. Markdown task lists (`- [ ]`) are rendered and
toggling one is an edit. Images: `![](si-img:<blobItemId>)`, resolved from the
local decrypted blob cache, downloaded on demand.

**Views** are filters over one projection table `Entries` (keyed
`(accountId, itemId)`, FK cascade, no sync columns — all writes go through
`MailObjectStore`):

- **Notes**: all entries (incl. those linked to a mail; the mail detail screen
  shows entries whose `links` contain the mail's Message-ID or a related one,
  as `observeNotesForMessages` does today).
- **Todos**: entries with `task`; filters open / today / done.
- **Journal**: entries with `date`; several per day allowed.

An entry may be several at once (a journal entry with a task).

Implemented in `lib/core/encrypted_objects/entry_object.dart` (the kind:
new entry, read, edit keeping unknown fields and parts),
`lib/data/repositories/entry_projector.dart` (the `Entries` projection) and
`lib/data/repositories/entry_repository_impl.dart` (reads the projection,
writes through the store). The body is rendered by `lib/ui/widgets/entry_markdown.dart`;
`lib/core/utils/markdown_tasks.dart` finds and toggles task-list items, and a
toggle saves a new version. `si-img:` images show a placeholder until #1377;
no image URL is ever fetched. **A projection is written only by the store's
merge**: the store calls the `ObjectProjector` of the item's kind inside the
transaction that writes the item's head columns, on a local write, a pull and
a reopen after an unlock (which also re-projects every item of the kind). It
gets the newest head that is not a tombstone (so an edit racing a delete
stays visible as a conflict), or none once every head is a tombstone.

**Conflict view** (#1374), generic over kinds: `MailObjectStore.observeConflicts`
lists the items whose heads carry `conflictOf`; `item()` returns one opened
version per distinct head. `resolve(keep:)` writes an `edit()` of that head
(a `tombstone()` if it is one) with `parents = all heads`; `keepAll(keep:)`
first copies every other distinct head that is not a tombstone into a new
item (`forkObject`: new itemId, same kind, fields and parts), then resolves.
Edit vs delete has no "keep both": the user keeps the edit or the deletion.
A `ConflictPresenter` per kind (`lib/core/encrypted_objects/conflict_presenter.dart`)
gives the list title and the text each version is diffed by against the
newest one (an entry: title, one line per field, the body); other kinds fall
back to the head JSON plus the text parts.

**Todos** (#1357): the entries home has the tabs Notes | Todos | Journal. The
Todos tab lists the todos of **every unlocked account** together (Notes stays
per account). Its filters are:

- **open**: `!done`.
- **today**: `!done` and `due <= today`, where today is the local
  `YYYY-MM-DD`. So overdue todos show here too.
- **done**: `done`.

A tick or an untick is an edit of `task.done` (`editEntryTask`). Title, body,
other fields and unknown `task` keys stay. A tick writes **no** `doneAt`, and an
untick removes it. So two devices ticking the same version write identical
content, which merges as one logical head, not a conflict.

New todos (quick-add) go to the preference "Default account for new items"
while that account is unlocked. Otherwise they go to the open account, and
otherwise to the first unlocked one. "Create todo" on a mail creates the todo
in that mail's account, with `links: [messageId]`.

**Journal** (#1358): the Journal tab (`lib/ui/widgets/journal_view.dart`)
shows one day of one account at a time, today first. Its entries are the
ones whose `date` is that day, oldest edit first. It can go a day back or
forward, jump to the previous or next day with entries, pick a day in a
calendar and go back to today. The grouping by day is in
`lib/core/utils/journal_days.dart`; a `date` that is not a real `YYYY-MM-DD`
is not shown. "New entry" sets `date` to the day shown. In the editor, a date
chip sets or changes it, and "Remove from journal" removes the field; an edit
that does not touch it keeps it.

Legacy plaintext notes (`Notes` folder, `X-SharedInbox-Note-*` headers) are
migrated into entries with `links: [messageId]` (#1375). Only mails with
`X-SharedInbox-Note-Id` are touched — Apple Notes uses a `Notes` folder too;
the folder itself is never deleted or renamed.

- **No plaintext once a key mail exists.** An account with a key mail is an
  encrypted account: this device never writes or uploads a new plaintext note
  for it. Locked, adding a note is disabled ("Unlock personal data to add
  notes") and notes still pending upload stay on the device. Unlocked, a new
  note is an entry. Accounts without a key mail keep plaintext notes.
- **Deterministic itemId**: base64url of the first 16 bytes of
  `SHA-256("sharedinbox-legacy-note:" + noteId)`. The content depends on the
  note only (body = text, `links: [messageId]`, no title, no tags,
  `createdAt` = the note's date), so two devices migrating the same note
  write the same content digest: one head, no conflict, no duplicate.
- **Passes** (foreground sync only, `LegacyNoteMigrator`):
  - **A0** before the object sync, no confirmation needed: a note pending
    upload becomes an entry and its local row goes; it never reaches the
    server.
  - **A** before the object sync, once the user confirmed on this device: each
    synced note becomes an entry unless any version of its item exists here
    (a tombstone too, so a delete is never undone).
  - **B** after the object sync, once confirmed: a note whose entry has a
    version confirmed on the server is deleted from `Notes` (on Gmail through
    Trash). An interrupted migration resumes from this state alone.
- The mail detail screen shows the entries linked to the mail and its related
  mails (`entry_links`) next to the notes not migrated yet; note search
  covers both.

### 6.1 Plaintext export (#1356)

Personal data → "Export personal data" writes every entry of one unlocked
account, decrypted, into a ZIP: a backup against the server deleting data
(section 2) and the input of a later "import from export". The user is warned
first that the file is **not encrypted**. Linux saves it with the save dialog;
Android and iOS hand it to the share sheet.

```text
sharedinbox-export-<accountEmail>-<YYYYMMDD-HHMMSS>.zip
  README.txt            # "This export is NOT encrypted" + format pointer
  manifest.json         # {format: "sharedinbox-export", version: 1,
                        #  exportedAt, accountId, accountEmail,
                        #  entries: <n>, conflictVersions: <n>,
                        #  images: <n>, missingImages: [<blobItemId>…]}
  entries/<itemId>.md                         # the displayed head
  entries/<itemId>.conflict-<versionId>.md    # every other distinct head
  images/<blobItemId>.<ext>   # ext from content type: png, jpg, gif, webp, else bin
```

- **Deterministic**: file names come from ids only, never from titles. In a
  file name every character of an id outside `[A-Za-z0-9_-]` becomes `_`
  (the real `versionId` is in the front matter). Files are sorted by path and
  every ZIP entry gets the mtime `exportedAt`, so only `manifest.exportedAt`
  and the ZIP name differ between two exports of the same data.
- **Entry file**: a YAML front matter, then the Markdown body. Keys in this
  order, absent ones left out:

  ```markdown
  ---
  itemId: "…"
  versionId: "…"
  title: "…"
  tags: ["a", "b"]
  date: "YYYY-MM-DD"
  task: {"done": false, "due": "…", "priority": 1, "doneAt": "…"}
  links: ["<msgid@host>"]
  createdAt: "…ISO 8601 UTC…"
  updatedAt: "…ISO 8601 UTC…"
  conflict: true
  ---
  <body markdown>
  ```

  Every string is JSON-quoted (a JSON string is a valid YAML double-quoted
  scalar); `task` has the keys of `EntryTask.toJson()`. `conflict: true` is on
  every file of an item in conflict.
- **Conflicts**: no version is dropped. The displayed head is
  `<itemId>.md`; every other distinct head is
  `<itemId>.conflict-<versionId>.md`. A tombstone head (edit vs delete) has
  only `itemId`, `versionId`, `updatedAt`, `conflict: true` and
  `deleted: true`, and an empty body.
- **Images**: `![alt](si-img:<id>)` becomes `![alt](../images/<id>.<ext>)`, so
  plain Markdown viewers show it; an importer maps it back, the file name being
  the blob id. A blob that is neither here nor downloadable keeps its
  `si-img:` link and is listed in `missingImages`; the user is told the export
  is not a complete backup before it is saved.

Implemented in `lib/core/encrypted_objects/entry_export.dart` (layout, front
matter, `parseExportedEntry` as the inverse) and
`lib/data/repositories/entry_export_service.dart` (collects the entries, the
other heads from `MailObjectStore.item` and the blobs). Cards and the review
log are added by the cards issues.

## 7. Flash cards

- **Card** documents (`kind: card`): front/back Markdown, tags, `collectionId`
  = the deck. **Card batches** (`kind: card-batch`, ≤ 500 cards) for imports;
  **each batch member carries its own `h` (HLC)**. A later edit of one card
  writes a `card` doc that overrides the member if its `h` is higher; deleting
  a member writes a `card` tombstone. Batch merge = per cardId, max `h` — an
  explicit **exception to the conflict view of 5.4**: concurrent rewrites of
  the same batch merge automatically.
- **Reviews**: log segments (`kind: review-seg` / `review-pack`) in the
  `personal` collection. Event union:
  - `{op: "review", c: cardId, s: seq, h: hlc, t: wallMs, r: rating, ms: durationMs}`
  - `{op: "undo", s: seq, h: hlc, ref: [deviceId, seq]}`
  Body: gzip JSONL. Head: `{device, seqFrom, seqTo, covers, period, hlcMax}`.
- **Tapping a rating never touches the network**: one local insert + recompute
  of that card's schedule. Upload triggers (debounced): app to background,
  session end, 5 min idle, ≥ 300 pending events, regular sync cycle.
- **Schedule is derived, never synced**: replay events per card ordered by
  `h` (then deviceId, seq); FSRS elapsed time from `t`, clamped ≥ 0. The same
  card reviewed offline on two devices → both reviews count.
- **Deck options / FSRS params**: device-state docs, effective value
  account-global (5.4 item 4); a change triggers a full replay. A study day
  starts at **04:00 local time** by default (like Anki; `dayStartHour` is a
  deck option), so a late-night session still counts as the same day.
- **Interval fuzz** is kept but deterministic: the PRNG is seeded from
  `(cardId, h of the review)`, so a replay gives the same due dates on every
  device.
- **Compaction**: owner device only, at > 30 own segments or month rollover;
  packs of closed months are immutable. Events of deleted cards are dropped at
  the next pack **only** if a synced tombstone exists.

Implemented in `lib/core/encrypted_objects/card_object.dart` (the kinds
`card`, `card-batch` and `deck`: new, read, edit, delete, import packing,
batch merge and rewrite), `lib/data/repositories/card_projector.dart` (the
projections) and `lib/data/repositories/card_repository_impl.dart` (reads
the projections, writes through the store); #1379.

- **`card`**: itemId = cardId (item HMAC `HMAC(k_item, cardId)` in the deck's
  collection), `tags` in the head, front and back as `text/markdown` parts
  with Content-ID `front` / `back`. Its `h` is the version's `versionId`. The
  first doc of a batch member (an edit or a delete) has `parents: []` and an
  `h` above the member's.
- **`card-batch`**: `count` in the head, one `application/jsonl+gzip` part
  (the codec of the log segments), one line per member
  `{c: cardId, h, f: front, b: back, tags}`; unknown member fields are kept on
  rewrite. A batch holds **at most 500 cards and at most 200 KiB of gzip
  body**, so it always stays below the 256 KiB eager-fetch limit (5.5) and
  arrives with the normal sync. An import packs cards greedily; a card whose
  line alone is over 200 KiB is written as a `card` doc. A rewrite never
  drops members (only a `card` tombstone deletes one), except when they no
  longer fit: the members that do not fit move to new batches with a new `h`.
- **The exception to 5.4** is the store hook `ObjectProjector.mergesHeads`
  (true for `card-batch`): its heads never get `conflictOf` (so they never
  show in the conflict view) and its projector gets `conflict: false` and
  every head; superseding, the rollback guard and the expunge after a
  collapse stay as they are. The next rewrite (`parents = all heads`)
  collapses concurrent heads.
- **Projections** (schema v86): `CardSources` holds one row per card per
  source item (batch member or `card` doc; a `card` doc whose heads are all
  tombstones is a `deleted` row); `Cards` holds per cardId the source with the
  highest `h` (ties: a doc beats a member, then the greater item HMAC). A
  winning tombstone stays, so a batch arriving later with a lower `h` cannot
  bring a deleted card back.
- **Decks**: a deck is a collection of its own (`collectionId` =
  `deck-` + a random itemId) whose key comes from
  `EncryptedKeyService.ensureCollection` (a collection-key mail in the keys
  folder; other devices load it like the `personal` key). The deck name is
  encrypted in a `deck` doc (itemId = collectionId) inside the deck's own
  collection — never in the collection-key mail, whose fields are plaintext
  on the server. The `Decks` projection lists them. Deleting a deck comes
  with the deck UI (#1381).
- **Import** (#1383, `lib/core/import/`, `lib/data/import/`; the UI is
  #1381): an Anki `.apkg` is a ZIP whose collection is read from
  `collection.anki21`, else `collection.anki2` (newer exports hold a dummy
  `anki2` next to the real one), in the legacy schema 11 (note types and
  decks as JSON in `col`). Each row of `cards` is a card: the front is the
  question template (`qfmt`) of its `ord`, the back the answer template
  (`afmt`) without `{{FrontSide}}` and the `<hr id=answer>` after it, with
  `{{Field}}`, `{{text:Field}}`, `{{#F}}…{{/F}}` and `{{^F}}…{{/F}}`. The deck
  is the Anki deck name (the `::` hierarchy stays in it), the tags those of
  the note. HTML becomes Markdown: `<br>`, `<div>`, `<p>` line breaks,
  `<b>`/`<strong>` `**`, `<i>`/`<em>` `*`, `<img src>` `![](si-img:<blobId>)`,
  entities decoded, other tags stripped, `[sound:…]` dropped. A CSV file has
  the columns `front, back, tags, deck` (RFC 4180, optional header, empty
  deck = `Default`). Ids are base64url of the first 16 bytes of a SHA-256:
  cardId = `"anki-card\0" + guid + "\0" + ord` or `"csv-card\0" + deck +
  "\0" + front`, blob itemId = `"blob\0" + bytes` (content-addressed: a blob
  that is already in the deck's collection is not written again). A
  re-import looks each cardId up: a deleted card stays deleted (the
  tombstone wins), an unchanged one is not written, a changed one gets a new
  batch member in the deck it is in (its fresh `h` wins: the file's content
  replaces a local edit), an unknown one is added. Cloze notes, `anki21b`
  (#1384), the review history (#1385) and sound and video media are not
  imported yet.

Reviews, schedules and upload are implemented in #1380:

- **Device-state keys** of the params (effective value account-global,
  5.4 item 4):
  - `fsrs.params` = `{weights, desiredRetention, maximumInterval,
    enableFuzz}`, for every deck;
  - `deck.<deckId>.options` = `{learningSteps, relearningSteps,
    dayStartHour, desiredRetention?}` (steps in seconds); a deck value
    overrides the global one.
  A missing or invalid field falls back to its default
  (`lib/core/flashcards/review_params.dart`).
- **Tables** (schema v89): `review_log` holds every review and undo seen on
  this device, own and remote, deduped by `(deviceId, seq)`; an own event
  with `segmentItemId` NULL is pending (in no segment yet). `card_schedule`
  is the derived cache per card (never synced), with the `paramsKey` of the
  effective params it was computed with; a card without a counted review
  has no row.
- **Rating** (`ReviewRepositoryImpl`): one transaction — `seq` and `h` from
  the store's clock, the insert, the recompute of that card
  (`CardScheduleWriter`) — then the HLC and `seq` high-water marks go to
  secure storage (`MailObjectStore.recordHighWater`); no `put`, no sync.
  `clockFor` also advances past this device's own `review_log` rows, since
  pending ones are in no segment.
- **Projection hook** `LogProjector`: the store calls it inside the merge
  transaction right after it stores the events of a segment or pack head (a
  local put, a pull, a reopen). `ReviewLogProjector` inserts the events,
  marks own pending rows with the segment's itemId (atomic with its local
  put) and recomputes the cards that new events touch. A card whose deck
  changes (it arrived after its reviews) is recomputed by the card
  projectors; a change of the params keys replays the affected decks
  (`CardScheduleWriter.watchParams`).
- **Upload** (`ReviewUploader`, `ReviewUploadScheduler`): a flush writes the
  pending own rows in `seq` order as `review-seg` segments of at most 1 000
  events (`MailObjectLog.appendStamped`), which the store's sync uploads.
  Triggers, debounced (2 s) and coalesced into one flush per account: app to
  the background, session end, 5 min after the last rating, ≥ 300 pending
  events (at once), and each regular sync cycle. Without a write key the
  rows stay pending; a crash after the put at worst writes the events
  again, which the `(deviceId, seq)` dedupe makes harmless. Compaction is
  #1382.
- **Export serializers** (`lib/core/flashcards/card_export.dart`, wired into
  the ZIP by #1356): `cardsCsv` (RFC 4180, columns
  `cardId,deckId,deckName,front,back,tags,h`, `si-img:<itemId>` rewritten to
  `media/<itemId>`, returning the referenced media) and `reviewLogJsonl`
  (one wire event plus `device` per line, ordered by `(h, deviceId, seq)`).

## 8. Test vectors

`test/fixtures/encrypted_objects/vectors.json` holds fixed keys, nonces,
plaintexts and the expected bytes, with **one top-level section per slice**.
The key-hierarchy slice (#1365) created it with `hkdf`, `recoveryKey`,
`slotWrap`, `collectionWrap` and `keyMailMac`, computed independently by
`scripts/gen_encrypted_objects_vectors.py`. The envelope slice (#1369) added
`itemHmac`, `padding`, `envelope`, `hlc` and `messageId`; the log-segment
slice (#1372) `logSegment`; the passkey slot (#1360) `passkeySlot`; the
card batches (#1379) `cardBatch`. Once
merged, a section is **frozen**: changing it requires a new magic (`SIE2`)
or schema version and a migration. New slices add sections; they never edit existing ones.

## 9. Rollout and user flows

**Rollout**: everything behind a debug/beta switch "Personal data (beta)"
until the format review (section 2) is done; then opt-in per account.

**Setup** (per account, from settings or the first time a feature opens):

```text
[Enable encrypted personal data]
  1. Explain: end-to-end encrypted, the server cannot read it, losing all
     unlock methods = losing the data.
  2. Generate key → re-list (4.3) → show recovery key (groups of 4 + QR)
  3. "Type the last group to confirm you saved it"
  4. Optional: add passphrase / passkey
  5. Done → entries home
```

**New device**: key mail found but no local key → "Unlock: [Pair with another
device] [Enter recovery key] [Passphrase] [Passkey]".

**Pairing** (4.2):

```text
New device:  [Pair with another device] → shows the request as QR + text,
             a 20-min countdown, checks SharedInbox/Keys every ~10 s,
             a paste field for the fallback code → unlocks by itself
Old device:  [Pair a new device] → scan (Android/iOS) or paste the request
             → refused if it is for another account
             → pairing mail appended (offline first) → "Sent — the new
               device unlocks on its next sync" + the paste code (text + QR)
```

**Legacy notes** (#1375): once unlocked, the personal-data screen offers
"Move N email notes into encrypted entries". The dialog warns that older
SharedInbox versions on other devices no longer see these notes, that the
provider may keep copies of the deleted plaintext (Gmail All Mail / Trash,
Exchange Recoverable Items), and that the `Notes` folder and other mail in it
stay. Confirming is stored per account on this device and starts a sync; until
then the mail detail screen shows a hint leading there.

**Entries home**: tabs Notes | Todos | Journal | Cards, quick-add field,
search (local). Conflict badge → conflict list → conflict view: one card
per version (two columns from 600 dp, stacked below), each with a diff against
the newest, "Keep this" / "Keep deleted", and "Keep both" (more than two live
versions: "Keep all (n)") only when another live version exists (#1374).

## 10. Success criteria

Measured on a mid-range Android phone (release build) and Linux desktop:

- Creating or ticking an entry offline: visible in the UI < 100 ms.
- Rating a card: next card shown < 50 ms, no network access.
- New device with recovery key, 1 000 entries: usable < 2 min.
- Initial sync of 10 000 small objects: < 5 min on Wi-Fi, no ANR.
- No plaintext content or key material in logs, sync logs or bug reports.
