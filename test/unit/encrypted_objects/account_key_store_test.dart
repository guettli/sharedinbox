import 'package:sharedinbox/core/encrypted_objects/account_key_store.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:test/test.dart';

import '../helpers/fake_secure_storage.dart';
import 'test_helpers.dart';

void main() {
  late FakeSecureStorage storage;
  late AccountKeyStore store;
  final key = AccountKey(seqBytes(0xa0, 16), seqBytes(0x00, 32));

  setUp(() {
    storage = FakeSecureStorage();
    store = AccountKeyStore(storage);
  });

  test('storage key is enc-account-key/<accountId>', () {
    expect(AccountKeyStore.storageKey('acc-1'), 'enc-account-key/acc-1');
  });

  test('save, load and delete round-trip', () async {
    expect(await store.load('acc-1'), isNull);
    await store.save('acc-1', key);
    final back = await store.load('acc-1');
    expect(back!.accountKeyId, key.accountKeyId);
    expect(back.key.bytes, key.key.bytes);
    expect(await store.load('acc-2'), isNull);
    await store.delete('acc-1');
    expect(await store.load('acc-1'), isNull);
  });

  test('every call uses afterFirstUnlockThisDevice', () async {
    await store.save('acc-1', key);
    await store.load('acc-1');
    await store.delete('acc-1');
    expect(storage.accessLog['enc-account-key/acc-1'], [
      SecureStorageAccess.afterFirstUnlockThisDevice,
      SecureStorageAccess.afterFirstUnlockThisDevice,
      SecureStorageAccess.afterFirstUnlockThisDevice,
    ]);
  });

  test('a corrupt stored value throws', () async {
    await storage.write(key: 'enc-account-key/acc-1', value: '{"key":"AA"}');
    expect(store.load('acc-1'), throwsFormatException);
  });
}
