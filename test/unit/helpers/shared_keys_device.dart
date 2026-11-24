// One install of the fake object account over a StatefulFakeImapServer,
// whose collection keys come from the SharedCollectionKeys of the test;
// the base of the card (#1379, #1383) and review (#1382) test devices.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';

import '../db_test_helper.dart';
import 'fake_imap_install.dart';
import 'fake_object_account.dart';
import 'fake_secure_storage.dart';
import 'stateful_fake_imap.dart';

/// One install talking to the shared fake [server], holding [keys];
/// subclasses add the [projectors] and repositories under test.
abstract class SharedKeysDevice with FakeImapInstall {
  SharedKeysDevice(this.server, this.keys);

  final StatefulFakeImapServer server;
  final SharedCollectionKeys keys;
  @override
  final db = openTestDatabase();
  @override
  final storage = FakeSecureStorage();

  @override
  StatefulFakeImapClient connectImap() => server.connect();

  @override
  CollectionKey? lookupKey(String _, Uint8List keyId) => keys.lookup(keyId);

  @override
  CollectionKey? writeKeyFor(String _, String collectionId) =>
      keys.byCollection[collectionId];

  /// Adds the account and closes the device after the test.
  Future<T> init<T extends SharedKeysDevice>() async {
    addTearDown(() async {
      await store.waitForIdle();
      await db.close();
    });
    await accounts.addAccount(fakeObjectAccount, 'pw');
    return this as T;
  }

  Future<void> sync() async {
    await mailboxes.syncMailboxes(fakeObjectAccountId);
    await store.sync(fakeObjectAccountId);
    await store.waitForIdle();
  }
}
