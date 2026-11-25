import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/recovery_key.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Key-mail payload and unlock slots (`ENCRYPTED-OBJECTS.md` 4.2, 4.6).
///
/// Only the `application/json` part and its MAC are produced here; how the
/// MAC travels in the mail is up to the key-mail store.

/// Slot types of 4.2.
abstract final class UnlockSlotType {
  static const recovery = 'recovery';
  static const passphrase = 'passphrase';
  static const passkeyPrf = 'passkey-prf';
}

const keyMailKind = 'account-key';

/// The account key wrapped under one KEK.
class UnlockSlot {
  UnlockSlot({
    required this.slotId,
    required this.type,
    required this.nonce,
    required this.wrapped,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra) {
    if (extra.keys.any(_known.contains)) {
      throw ArgumentError.value(extra, 'extra', 'overrides a known field');
    }
  }

  factory UnlockSlot.fromJson(Map<String, Object?> json) => UnlockSlot(
        slotId: readBytesField(json, 'slotId', idLength),
        type: readAadStringField(json, 'type'),
        nonce: readBytesField(json, 'nonce', nonceLength),
        wrapped: readBytesField(json, 'wrapped', null),
        extra: unknownFields(json, _known),
      );

  static const _known = {'slotId', 'type', 'nonce', 'wrapped'};

  final Uint8List slotId;
  final String type;
  final Uint8List nonce;

  /// `ciphertext ‖ tag(16)` of the raw 32-byte account key.
  final Uint8List wrapped;

  /// Fields this version does not know (e.g. passphrase salt and params);
  /// preserved on rewrite.
  final Map<String, Object?> extra;

  String get slotIdB64 => b64url(slotId);

  Map<String, Object?> toJson() => {
        'slotId': b64url(slotId),
        'type': type,
        'nonce': b64url(nonce),
        'wrapped': b64url(wrapped),
        ...extra,
      };
}

/// AAD of a slot: `accountKeyId ‖ slotId ‖ enc(type)`.
Uint8List slotAad({
  required Uint8List accountKeyId,
  required Uint8List slotId,
  required String type,
}) =>
    buildAad([accountKeyId, slotId, type]);

/// Wraps [accountKey] under [kek] into a new slot with a fresh random
/// `slotId` and nonce.
Future<UnlockSlot> wrapSlot(
  AccountKey accountKey,
  SecretKey kek,
  String type, {
  Map<String, Object?> extra = const {},
  RandomBytes random = secureRandomBytes,
}) async {
  final slotId = random(idLength);
  final nonce = random(nonceLength);
  final wrapped = await aeadSeal(
    key: kek,
    nonce: nonce,
    plaintext: accountKey.key.bytes,
    aad: slotAad(
      accountKeyId: accountKey.accountKeyId,
      slotId: slotId,
      type: type,
    ),
  );
  return UnlockSlot(
    slotId: slotId,
    type: type,
    nonce: nonce,
    wrapped: wrapped,
    extra: extra,
  );
}

/// Unwraps the account key from [slot]. Throws [KeyUnwrapException] for a
/// wrong KEK or a tampered slot.
Future<AccountKey> unwrapSlot(
  UnlockSlot slot,
  SecretKey kek,
  Uint8List accountKeyId,
) async {
  final clear = await aeadOpen(
    key: kek,
    nonce: slot.nonce,
    sealed: slot.wrapped,
    aad: slotAad(
      accountKeyId: accountKeyId,
      slotId: slot.slotId,
      type: slot.type,
    ),
  );
  if (clear.length != keyLength) {
    throw const KeyUnwrapException('unwrapped key has wrong length');
  }
  return AccountKey(accountKeyId, clear);
}

/// Creates the mandatory `recovery` slot.
Future<UnlockSlot> wrapRecoverySlot(
  AccountKey accountKey,
  RecoveryKey recoveryKey, {
  RandomBytes random = secureRandomBytes,
}) async =>
    wrapSlot(
      accountKey,
      await recoveryKey.kek(),
      UnlockSlotType.recovery,
      random: random,
    );

/// Unlocks with a recovery key. Throws [KeyUnwrapException] for a wrong one.
Future<AccountKey> unwrapRecoverySlot(
  UnlockSlot slot,
  RecoveryKey recoveryKey,
  Uint8List accountKeyId,
) async =>
    unwrapSlot(slot, await recoveryKey.kek(), accountKeyId);

/// The `application/json` part of a key mail.
///
/// [bytes] are the exact bytes the MAC covers: for a parsed payload the bytes
/// as stored, for a new one their JSON encoding at construction time.
class KeyMailPayload {
  factory KeyMailPayload({
    required Uint8List accountKeyId,
    required int slotListVersion,
    required List<UnlockSlot> slots,
    Map<String, Object?> extra = const {},
  }) {
    if (extra.keys.any(_known.contains)) {
      throw ArgumentError.value(extra, 'extra', 'overrides a known field');
    }
    final json = {
      'v': 1,
      'kind': keyMailKind,
      'accountKeyId': b64url(accountKeyId),
      'slotListVersion': slotListVersion,
      'slots': [for (final s in slots) s.toJson()],
      ...extra,
    };
    return KeyMailPayload._(
      accountKeyId: accountKeyId,
      slotListVersion: slotListVersion,
      slots: slots,
      extra: extra,
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(json))),
    );
  }

  KeyMailPayload._({
    required this.accountKeyId,
    required this.slotListVersion,
    required List<UnlockSlot> slots,
    required Map<String, Object?> extra,
    required this.bytes,
  })  : slots = List.unmodifiable(slots),
        extra = Map.unmodifiable(extra);

  /// Parses stored bytes. Throws [FormatException] if they are not a v1
  /// key-mail payload. The bytes are kept for [SignedKeyMail.verify].
  factory KeyMailPayload.parse(Uint8List bytes) {
    final json = decodeJsonObject(bytes);
    if (json['v'] != 1) throw const FormatException('unsupported key mail v');
    if (json['kind'] != keyMailKind) {
      throw const FormatException('not an account-key mail');
    }
    final version = json['slotListVersion'];
    if (version is! int || version < 0) {
      throw const FormatException('invalid slotListVersion');
    }
    final rawSlots = json['slots'];
    if (rawSlots is! List) throw const FormatException('missing slots');
    final slots = [
      for (final s in rawSlots)
        if (s is Map<String, Object?>)
          UnlockSlot.fromJson(s)
        else
          throw const FormatException('slot is not an object'),
    ];
    return KeyMailPayload._(
      accountKeyId: readBytesField(json, 'accountKeyId', idLength),
      slotListVersion: version,
      slots: slots,
      extra: unknownFields(json, _known),
      bytes: Uint8List.fromList(bytes),
    );
  }

  static const _known = {
    'v',
    'kind',
    'accountKeyId',
    'slotListVersion',
    'slots',
  };

  final Uint8List accountKeyId;
  final int slotListVersion;
  final List<UnlockSlot> slots;

  /// Unknown top-level fields; preserved on rewrite.
  final Map<String, Object?> extra;

  /// The exact bytes covered by the MAC.
  final Uint8List bytes;

  /// Returns the stored [bytes] and their MAC under [kSlots].
  Future<SignedKeyMail> serialize(SecretKey kSlots) async =>
      SignedKeyMail(this, await keyMailMac(bytes, kSlots));

  /// A copy with [slot] appended and `slotListVersion + 1`.
  KeyMailPayload withSlotAdded(UnlockSlot slot) {
    if (slots.any((s) => s.slotIdB64 == slot.slotIdB64)) {
      throw ArgumentError.value(slot.slotIdB64, 'slot', 'slotId exists');
    }
    return KeyMailPayload(
      accountKeyId: accountKeyId,
      slotListVersion: slotListVersion + 1,
      slots: [...slots, slot],
      extra: extra,
    );
  }

  /// A copy without the slot [slotId] and `slotListVersion + 1`.
  ///
  /// Removing a slot is not revocation (4.2).
  KeyMailPayload withSlotRemoved(Uint8List slotId) {
    final id = b64url(slotId);
    if (!slots.any((s) => s.slotIdB64 == id)) {
      throw ArgumentError.value(id, 'slotId', 'no such slot');
    }
    return KeyMailPayload(
      accountKeyId: accountKeyId,
      slotListVersion: slotListVersion + 1,
      slots: [
        for (final s in slots)
          if (s.slotIdB64 != id) s,
      ],
      extra: extra,
    );
  }
}

/// HMAC-SHA256(k_slots, bytes).
Future<Uint8List> keyMailMac(Uint8List bytes, SecretKey kSlots) async {
  final mac = await Hmac.sha256().calculateMac(bytes, secretKey: kSlots);
  return Uint8List.fromList(mac.bytes);
}

/// A key-mail payload together with the MAC carried next to it.
class SignedKeyMail {
  SignedKeyMail(this.payload, this.mac);

  /// Parses stored [bytes]; the [mac] is checked by [verify].
  factory SignedKeyMail.parse(Uint8List bytes, Uint8List mac) =>
      SignedKeyMail(KeyMailPayload.parse(bytes), Uint8List.fromList(mac));

  final KeyMailPayload payload;
  final Uint8List mac;

  Uint8List get bytes => payload.bytes;

  /// Recomputes the MAC over the stored bytes (never a re-serialization) and
  /// compares in constant time.
  Future<bool> verify(SecretKey kSlots) async =>
      constantTimeEquals(await keyMailMac(payload.bytes, kSlots), mac);
}

/// Groups key mails by `accountKeyId` (base64url).
Map<String, List<SignedKeyMail>> groupByAccountKeyId(
  Iterable<SignedKeyMail> mails,
) {
  final groups = <String, List<SignedKeyMail>>{};
  for (final m in mails) {
    groups.putIfAbsent(b64url(m.payload.accountKeyId), () => []).add(m);
  }
  return groups;
}

/// Picks the effective key mail of one group (4.2 lifecycle).
///
/// Drops entries with an invalid MAC or another `accountKeyId`; the highest
/// `slotListVersion` wins; several winners with different slot sets are
/// merged into version N+1. Returns null if no entry is valid.
Future<SignedKeyMail?> selectWinner(
  Iterable<SignedKeyMail> group,
  AccountKey accountKey,
) async {
  final kSlots = await accountKey.kSlots();
  final valid = <SignedKeyMail>[];
  for (final m in group) {
    if (!constantTimeEquals(m.payload.accountKeyId, accountKey.accountKeyId)) {
      continue;
    }
    if (!await m.verify(kSlots)) continue;
    valid.add(m);
  }
  if (valid.isEmpty) return null;
  final top = valid.map((m) => m.payload.slotListVersion).reduce(max);
  final best = valid.where((m) => m.payload.slotListVersion == top).toList();
  final slotSets = best.map((m) => _slotSetKey(m.payload)).toSet();
  if (slotSets.length == 1) return best.first;
  return mergeKeyMails(best.map((m) => m.payload), kSlots);
}

/// Merges two key mails of the same account: see [mergeKeyMails].
Future<SignedKeyMail> merge(
  KeyMailPayload a,
  KeyMailPayload b,
  SecretKey kSlots,
) =>
    mergeKeyMails([a, b], kSlots);

/// Union of all slots by `slotId` at `max(slotListVersion) + 1`.
///
/// Same `slotId` with different content: the slot whose canonical JSON sorts
/// smallest wins; the same rule settles unknown top-level fields. Slots and
/// unknown fields are written in sorted order, so the result does not depend
/// on the order of [payloads].
Future<SignedKeyMail> mergeKeyMails(
  Iterable<KeyMailPayload> payloads,
  SecretKey kSlots,
) {
  final list = payloads.toList();
  if (list.isEmpty) throw ArgumentError.value(list, 'payloads', 'empty');
  final accountKeyId = list.first.accountKeyId;
  final slots = <String, UnlockSlot>{};
  final slotJson = <String, String>{};
  final extra = <String, Object?>{};
  final extraJson = <String, String>{};
  for (final p in list) {
    if (!constantTimeEquals(p.accountKeyId, accountKeyId)) {
      throw ArgumentError.value(p, 'payloads', 'different accountKeyId');
    }
    for (final s in p.slots) {
      final c = canonicalJson(s.toJson());
      final known = slotJson[s.slotIdB64];
      if (known != null && known.compareTo(c) <= 0) continue;
      slots[s.slotIdB64] = s;
      slotJson[s.slotIdB64] = c;
    }
    for (final e in p.extra.entries) {
      final c = canonicalJson(e.value);
      final known = extraJson[e.key];
      if (known != null && known.compareTo(c) <= 0) continue;
      extra[e.key] = e.value;
      extraJson[e.key] = c;
    }
  }
  final slotIds = slots.keys.toList()..sort();
  final extraKeys = extra.keys.toList()..sort();
  final merged = KeyMailPayload(
    accountKeyId: accountKeyId,
    slotListVersion: list.map((p) => p.slotListVersion).reduce(max) + 1,
    slots: [for (final id in slotIds) slots[id]!],
    extra: {for (final k in extraKeys) k: extra[k]},
  );
  return merged.serialize(kSlots);
}

String _slotSetKey(KeyMailPayload p) {
  final slots = [for (final s in p.slots) canonicalJson(s.toJson())]..sort();
  return jsonEncode(slots);
}
