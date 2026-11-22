import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/collection_key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  final accountKey = testAccountKey;
  final deckKey = testDeckKey;

  Map<String, Object?> jsonOf(CollectionKeyMail m) =>
      jsonDecode(utf8.decode(m.bytes)) as Map<String, Object?>;

  Uint8List bytesOf(Object json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));

  test('round-trips', () async {
    final mail = await CollectionKeyMail.create(accountKey, deckKey);
    expect(jsonOf(mail)['kind'], 'collection-key');
    expect(mail.wraps.single['type'], 'account');
    final parsed = CollectionKeyMail.parse(mail.bytes);
    expect(parsed.collectionId, 'deck-1');
    expect(parsed.keyId, deckKey.keyId);
    final key = await parsed.unwrapWith(accountKey);
    expect(key.key.bytes, deckKey.key.bytes);
    expect(key.collectionId, 'deck-1');
  });

  test('unknown wrap types and fields are preserved and skipped', () async {
    final mail = await CollectionKeyMail.create(accountKey, deckKey);
    final json = jsonOf(mail);
    final x25519 = {'type': 'x25519', 'recipient': 'AAAA', 'wrapped': 'BBBB'};
    final bytes = bytesOf({
      ...json,
      'wraps': [x25519, ...(json['wraps']! as List)],
      'future': true,
    });
    final parsed = CollectionKeyMail.parse(bytes);
    expect(parsed.wraps.first, x25519);
    expect(parsed.extra, {'future': true});
    expect((await parsed.unwrapWith(accountKey)).key.bytes, deckKey.key.bytes);
    final rewritten = CollectionKeyMail(
      accountKeyId: parsed.accountKeyId,
      collectionId: parsed.collectionId,
      keyId: parsed.keyId,
      wraps: parsed.wraps,
      extra: parsed.extra,
    );
    expect(jsonOf(rewritten), jsonDecode(utf8.decode(bytes)));
  });

  test('a mail of another accountKeyId is rejected', () async {
    final mail = await CollectionKeyMail.create(accountKey, deckKey);
    final other = AccountKey(seqBytes(0xa1, 16), seqBytes(0x00, 32));
    expect(mail.unwrapWith(other), throwsA(isA<KeyUnwrapException>()));
  });

  test('a mail relabelled as personal is rejected', () async {
    final mail = await CollectionKeyMail.create(accountKey, deckKey);
    final relabelled = CollectionKeyMail.parse(
      bytesOf({...jsonOf(mail), 'collectionId': personalCollectionId}),
    );
    expect(
      relabelled.unwrapWith(accountKey),
      throwsA(isA<KeyUnwrapException>()),
    );
  });

  test('missing or malformed account wraps are rejected', () async {
    final mail = await CollectionKeyMail.create(accountKey, deckKey);
    final none = CollectionKeyMail.parse(
      bytesOf({
        ...jsonOf(mail),
        'wraps': [
          {'type': 'x25519'},
        ],
      }),
    );
    expect(none.unwrapWith(accountKey), throwsA(isA<KeyUnwrapException>()));
    final malformed = CollectionKeyMail.parse(
      bytesOf({
        ...jsonOf(mail),
        'wraps': [
          {'type': 'account', 'nonce': 'AA'},
        ],
      }),
    );
    expect(
      malformed.unwrapWith(accountKey),
      throwsA(isA<KeyUnwrapException>()),
    );
  });

  test('parse rejects malformed mails', () async {
    final good = jsonOf(await CollectionKeyMail.create(accountKey, deckKey));
    for (final bad in [
      {...good, 'v': 2},
      {...good, 'kind': 'account-key'},
      {...good, 'wraps': 'x'},
      {
        ...good,
        'wraps': [
          {'nonce': 'AA'},
        ],
      },
      {...good, 'collectionId': 1},
      {...good, 'keyId': 'AA'},
    ]) {
      expect(
        () => CollectionKeyMail.parse(bytesOf(bad)),
        throwsFormatException,
        reason: '$bad',
      );
    }
    expect(
      () => CollectionKeyMail(
        accountKeyId: accountKey.accountKeyId,
        collectionId: 'x',
        keyId: deckKey.keyId,
        wraps: const [],
        extra: {'wraps': 1},
      ),
      throwsArgumentError,
    );
  });
}
