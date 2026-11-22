import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/recovery_key.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  final accountKey = AccountKey(seqBytes(0xa0, 16), seqBytes(0x00, 32));
  final recoveryKey = RecoveryKey(seqBytes(0x40, 16));

  Future<UnlockSlot> slot(int seed, {String type = 'recovery'}) async =>
      wrapSlot(
        accountKey,
        await recoveryKey.kek(),
        type,
        random: counterRandom(seed),
      );

  KeyMailPayload payload(int version, List<UnlockSlot> slots) => KeyMailPayload(
        accountKeyId: accountKey.accountKeyId,
        slotListVersion: version,
        slots: slots,
      );

  group('slots', () {
    test('recovery slot round-trips', () async {
      final s = await wrapRecoverySlot(accountKey, recoveryKey);
      expect(s.type, UnlockSlotType.recovery);
      expect(s.slotId, hasLength(16));
      expect(s.nonce, hasLength(24));
      final back =
          await unwrapRecoverySlot(s, recoveryKey, accountKey.accountKeyId);
      expect(back.key.bytes, accountKey.key.bytes);
      expect(back.accountKeyId, accountKey.accountKeyId);
    });

    test('a wrong recovery key throws', () async {
      final s = await wrapRecoverySlot(accountKey, recoveryKey);
      expect(
        unwrapRecoverySlot(
          s,
          RecoveryKey(seqBytes(0x41, 16)),
          accountKey.accountKeyId,
        ),
        throwsA(isA<KeyUnwrapException>()),
      );
    });

    test('a different accountKeyId, slotId or type fails', () async {
      final s = await slot(1);
      final kek = await recoveryKey.kek();
      expect(
        unwrapSlot(s, kek, seqBytes(0xa1, 16)),
        throwsA(isA<KeyUnwrapException>()),
      );
      final otherId = UnlockSlot(
        slotId: seqBytes(0, 16),
        type: s.type,
        nonce: s.nonce,
        wrapped: s.wrapped,
      );
      expect(
        unwrapSlot(otherId, kek, accountKey.accountKeyId),
        throwsA(isA<KeyUnwrapException>()),
      );
      final otherType =
          UnlockSlot.fromJson({...s.toJson(), 'type': 'passphrase'});
      expect(
        unwrapSlot(otherType, kek, accountKey.accountKeyId),
        throwsA(isA<KeyUnwrapException>()),
      );
    });

    test('unknown slot fields survive a JSON round trip', () async {
      final s = await wrapSlot(
        accountKey,
        await recoveryKey.kek(),
        UnlockSlotType.passphrase,
        extra: {
          'salt': 'AAAA',
          'params': {'m': 65536, 't': 3, 'p': 1},
        },
      );
      final back = UnlockSlot.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>,
      );
      expect(back.extra, {
        'salt': 'AAAA',
        'params': {'m': 65536, 't': 3, 'p': 1},
      });
      expect(back.toJson(), s.toJson());
    });

    test('extra may not override known fields', () {
      expect(
        () => UnlockSlot(
          slotId: seqBytes(0, 16),
          type: 'recovery',
          nonce: seqBytes(0, 24),
          wrapped: seqBytes(0, 48),
          extra: {'type': 'x'},
        ),
        throwsArgumentError,
      );
    });
  });

  group('payload MAC', () {
    test('serialize → parse → verify succeeds', () async {
      final kSlots = await accountKey.kSlots();
      final signed = await payload(1, [await slot(1)]).serialize(kSlots);
      expect(signed.mac, hasLength(32));
      final parsed = SignedKeyMail.parse(signed.bytes, signed.mac);
      expect(await parsed.verify(kSlots), isTrue);
      expect(parsed.payload.slotListVersion, 1);
      expect(parsed.payload.slots.single.toJson(), (await slot(1)).toJson());
      expect(
        (await unwrapRecoverySlot(
          parsed.payload.slots.single,
          recoveryKey,
          parsed.payload.accountKeyId,
        ))
            .key
            .bytes,
        accountKey.key.bytes,
      );
    });

    test('a flipped byte or a changed MAC is rejected', () async {
      final kSlots = await accountKey.kSlots();
      final signed = await payload(1, [await slot(1)]).serialize(kSlots);
      final json = utf8.decode(signed.bytes);
      final tampered = Uint8List.fromList(
        utf8.encode(
          json.replaceFirst('"slotListVersion":1', '"slotListVersion":2'),
        ),
      );
      expect(
        await SignedKeyMail.parse(tampered, signed.mac).verify(kSlots),
        isFalse,
      );
      final mac = Uint8List.fromList(signed.mac)..[31] ^= 1;
      expect(
        await SignedKeyMail.parse(signed.bytes, mac).verify(kSlots),
        isFalse,
      );
      final short = signed.mac.sublist(0, 16);
      expect(
        await SignedKeyMail.parse(signed.bytes, short).verify(kSlots),
        isFalse,
      );
    });

    test('same content with another key order fails with the old MAC',
        () async {
      final kSlots = await accountKey.kSlots();
      final signed = await payload(1, [await slot(1)]).serialize(kSlots);
      final json =
          jsonDecode(utf8.decode(signed.bytes)) as Map<String, Object?>;
      final reordered = Uint8List.fromList(
        utf8.encode(
          jsonEncode(Map.fromEntries(json.entries.toList().reversed)),
        ),
      );
      final parsed = SignedKeyMail.parse(reordered, signed.mac);
      expect(parsed.payload.slotListVersion, 1);
      expect(await parsed.verify(kSlots), isFalse);
    });

    test('unknown top-level fields are preserved', () async {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            ...jsonDecode(utf8.decode(payload(3, [await slot(1)]).bytes))
                as Map<String, Object?>,
            'future': {'x': 1},
          }),
        ),
      );
      final parsed = KeyMailPayload.parse(bytes);
      expect(parsed.bytes, bytes);
      expect(parsed.extra, {
        'future': {'x': 1},
      });
      final next = parsed.withSlotAdded(await slot(2));
      expect(next.extra, parsed.extra);
      expect(utf8.decode(next.bytes), contains('"future":{"x":1}'));
    });

    test('parse rejects non key mails', () {
      Uint8List bytesOf(Object json) =>
          Uint8List.fromList(utf8.encode(jsonEncode(json)));
      final good =
          jsonDecode(utf8.decode(payload(1, []).bytes)) as Map<String, Object?>;
      for (final bad in [
        {...good, 'v': 2},
        {...good, 'kind': 'collection-key'},
        {...good, 'slotListVersion': -1},
        {...good, 'slotListVersion': '1'},
        {...good, 'slots': 'x'},
        {
          ...good,
          'slots': [1],
        },
        {...good, 'accountKeyId': 'AAAA'},
      ]) {
        expect(
          () => KeyMailPayload.parse(bytesOf(bad)),
          throwsFormatException,
          reason: '$bad',
        );
      }
      expect(
        () => KeyMailPayload(
          accountKeyId: accountKey.accountKeyId,
          slotListVersion: 1,
          slots: const [],
          extra: {'v': 2},
        ),
        throwsArgumentError,
      );
    });
  });

  group('slot changes', () {
    test('withSlotAdded and withSlotRemoved bump the version', () async {
      final a = await slot(1);
      final b = await slot(5, type: UnlockSlotType.passphrase);
      final p = payload(1, [a]);
      final added = p.withSlotAdded(b);
      expect(added.slotListVersion, 2);
      expect(added.slots.map((s) => s.slotIdB64), [a.slotIdB64, b.slotIdB64]);
      expect(() => added.withSlotAdded(b), throwsArgumentError);
      final removed = added.withSlotRemoved(a.slotId);
      expect(removed.slotListVersion, 3);
      expect(removed.slots.single.slotIdB64, b.slotIdB64);
      expect(() => removed.withSlotRemoved(a.slotId), throwsArgumentError);
    });
  });

  group('lifecycle', () {
    test('groups by accountKeyId', () async {
      final kSlots = await accountKey.kSlots();
      final other = KeyMailPayload(
        accountKeyId: seqBytes(0x10, 16),
        slotListVersion: 1,
        slots: const [],
      );
      final groups = groupByAccountKeyId([
        await payload(1, [await slot(1)]).serialize(kSlots),
        await other.serialize(kSlots),
        await payload(2, [await slot(1)]).serialize(kSlots),
      ]);
      expect(groups, hasLength(2));
      expect(groups[b64url(accountKey.accountKeyId)], hasLength(2));
      expect(groups[b64url(seqBytes(0x10, 16))], hasLength(1));
    });

    test('the highest valid version wins', () async {
      final kSlots = await accountKey.kSlots();
      final v1 = await payload(1, [await slot(1)]).serialize(kSlots);
      final v2 =
          await payload(2, [await slot(1), await slot(5)]).serialize(kSlots);
      final forged = SignedKeyMail(payload(9, [await slot(9)]), Uint8List(32));
      final winner = await selectWinner([v1, forged, v2], accountKey);
      expect(winner!.payload.slotListVersion, 2);
      expect(identical(winner, v2), isTrue);
    });

    test('entries of another accountKeyId or with a bad MAC are dropped',
        () async {
      final kSlots = await accountKey.kSlots();
      final foreign = await KeyMailPayload(
        accountKeyId: seqBytes(0x10, 16),
        slotListVersion: 5,
        slots: const [],
      ).serialize(kSlots);
      final forged = SignedKeyMail(payload(9, const []), Uint8List(32));
      expect(await selectWinner([foreign, forged], accountKey), isNull);
      expect(await selectWinner([], accountKey), isNull);
    });

    test('equal versions with the same slots do not merge', () async {
      final kSlots = await accountKey.kSlots();
      final a = await payload(2, [await slot(1)]).serialize(kSlots);
      final b = await payload(2, [await slot(1)]).serialize(kSlots);
      final winner = await selectWinner([a, b], accountKey);
      expect(winner!.payload.slotListVersion, 2);
    });

    test('equal versions with different slots merge to N+1', () async {
      final kSlots = await accountKey.kSlots();
      final s1 = await slot(1);
      final s2 = await slot(5);
      final s3 = await slot(9);
      final a = await payload(2, [s1, s2]).serialize(kSlots);
      final b = await payload(2, [s1, s3]).serialize(kSlots);
      final winner = await selectWinner([a, b], accountKey);
      expect(winner!.payload.slotListVersion, 3);
      expect(
        winner.payload.slots.map((s) => s.slotIdB64).toSet(),
        {s1.slotIdB64, s2.slotIdB64, s3.slotIdB64},
      );
      expect(await winner.verify(kSlots), isTrue);
    });

    test('merge is commutative and keeps the smallest conflicting slot',
        () async {
      final kSlots = await accountKey.kSlots();
      final s1 = await slot(1);
      final s2 = await slot(5);
      // Same slotId as s1, different content.
      final s1b = UnlockSlot(
        slotId: s1.slotId,
        type: s1.type,
        nonce: seqBytes(0x99, 24),
        wrapped: s1.wrapped,
        extra: {'note': 'b'},
      );
      final a =
          payload(4, [s1, s2]).withSlotRemoved(s2.slotId).withSlotAdded(s2);
      final b = KeyMailPayload(
        accountKeyId: accountKey.accountKeyId,
        slotListVersion: 6,
        slots: [s1b],
        extra: {'z': 1, 'y': 2},
      );
      final ab = await merge(a, b, kSlots);
      final ba = await merge(b, a, kSlots);
      expect(ab.bytes, ba.bytes);
      expect(ab.mac, ba.mac);
      expect(ab.payload.slotListVersion, 7);
      expect(ab.payload.slots, hasLength(2));
      final expected = [s1.toJson(), s1b.toJson()]
        ..sort((x, y) => canonicalJson(x).compareTo(canonicalJson(y)));
      expect(
        ab.payload.slots
            .firstWhere((s) => s.slotIdB64 == s1.slotIdB64)
            .toJson(),
        expected.first,
      );
      expect(ab.payload.extra.keys, ['y', 'z']);
      expect(await ab.verify(kSlots), isTrue);
    });

    test('merging conflicting unknown fields is commutative', () async {
      final kSlots = await accountKey.kSlots();
      final a = KeyMailPayload(
        accountKeyId: accountKey.accountKeyId,
        slotListVersion: 1,
        slots: const [],
        extra: {'f': 'b'},
      );
      final b = KeyMailPayload(
        accountKeyId: accountKey.accountKeyId,
        slotListVersion: 1,
        slots: const [],
        extra: {'f': 'a'},
      );
      expect((await merge(a, b, kSlots)).payload.extra, {'f': 'a'});
      expect((await merge(b, a, kSlots)).payload.extra, {'f': 'a'});
    });

    test('merge rejects different accounts and empty input', () async {
      final kSlots = await accountKey.kSlots();
      final other = KeyMailPayload(
        accountKeyId: seqBytes(0x10, 16),
        slotListVersion: 1,
        slots: const [],
      );
      expect(
        () => merge(payload(1, const []), other, kSlots),
        throwsArgumentError,
      );
      expect(() => mergeKeyMails(const [], kSlots), throwsArgumentError);
    });
  });
}
