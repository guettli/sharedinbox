import 'package:sharedinbox/core/encrypted_objects/key_ring.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  test('collection keys are found by keyId; writes by collection', () {
    final ring = KeyRing()..setAccountKey('a', testAccountKey);
    expect(ring.addCollectionKey('a', testDeckKey), isTrue);
    expect(ring.addCollectionKey('a', testDeckKey), isFalse);

    expect(ring.lookup('a', testDeckKey.keyId), same(testDeckKey));
    expect(ring.lookup('b', testDeckKey.keyId), isNull);
    expect(ring.hasWriteKey('a', 'deck-1'), isFalse);
    expect(ring.writeKey('a', 'deck-1'), isNull);

    ring.setWriteKey('a', testDeckKey);
    expect(ring.hasWriteKey('a', 'deck-1'), isTrue);
    expect(ring.writeKey('a', 'deck-1'), same(testDeckKey));
    expect(ring.collectionKeys('a').keys, hasLength(1));
  });

  test('the first write-key hit per account is reported once', () {
    final used = <String>[];
    final ring = KeyRing(onWriteKeyUsed: used.add)
      ..setWriteKey('a', testDeckKey);

    expect(ring.hasWriteKey('a', 'deck-1'), isTrue);
    expect(used, isEmpty);
    ring
      ..writeKey('a', 'deck-1')
      ..writeKey('a', 'deck-1');
    expect(used, ['a']);
  });

  test('another account key drops the collection keys; clear drops all', () {
    final ring = KeyRing()
      ..setAccountKey('a', testAccountKey)
      ..setWriteKey('a', testDeckKey);

    ring.setAccountKey('a', testAccountKey);
    expect(ring.lookup('a', testDeckKey.keyId), isNotNull);

    final other = AccountKey(seqBytes(0x10, 16), seqBytes(0x50, 32));
    ring.setAccountKey('a', other);
    expect(ring.accountKey('a'), same(other));
    expect(ring.lookup('a', testDeckKey.keyId), isNull);

    ring.clear('a');
    expect(ring.accountKey('a'), isNull);
  });
}
