// What the unit tests of the card and review repositories (#1379, #1380)
// share: one account on a StatefulFakeImapServer, and the collection keys
// its devices hold.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart';

import '../db_test_helper.dart';
import 'stateful_fake_imap.dart';

const fakeObjectAccountId = 'acc-1';
const fakeObjectDataPath = 'SharedInbox/Data';

const fakeObjectAccount = Account(
  id: fakeObjectAccountId,
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

/// The collection keys of the account, as the key lifecycle shares them
/// between devices through the keys folder; [collections] get one at the
/// start.
class SharedCollectionKeys {
  SharedCollectionKeys([Iterable<String> collections = const []])
      : byCollection = {
          for (final c in collections) c: CollectionKey.generate(c),
        };

  final Map<String, CollectionKey> byCollection;

  CollectionKey? lookup(Uint8List keyId) {
    for (final k in byCollection.values) {
      if (constantTimeEquals(k.keyId, keyId)) return k;
    }
    return null;
  }
}

/// Before each test of the file: a new fake server and new keys (with
/// [collections]), handed to [onEach].
void setUpFakeObjectServer(
  void Function(StatefulFakeImapServer server, SharedCollectionKeys keys)
      onEach, {
  Iterable<String> collections = const [],
}) {
  setUpAll(configureSqliteForTests);
  setUp(
    () => onEach(
      StatefulFakeImapServer(uidValidityByFolder: {'INBOX': 1}),
      SharedCollectionKeys(collections),
    ),
  );
}
