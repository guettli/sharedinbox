// The account, folder listing and object store of one install on a
// StatefulFakeImapServer, shared by the object-store backed repository
// tests.

import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'fake_secure_storage.dart';
import 'stateful_fake_imap.dart';

/// [accounts], [mailboxes] and [store] over [db] and [storage]; every
/// connection goes through [connectImap].
mixin FakeImapInstall {
  AppDatabase get db;
  FakeSecureStorage get storage;

  /// A connection to the fake server (may throw to simulate offline).
  StatefulFakeImapClient connectImap();

  /// The key of [keyId] this install holds, or null.
  CollectionKey? lookupKey(String accountId, Uint8List keyId);

  /// The key new versions of [collectionId] are written with, or null.
  CollectionKey? writeKeyFor(String accountId, String collectionId);

  List<MailObjectProjector> get projectors;

  late final accounts = AccountRepositoryImpl(db, storage);
  late final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __, ___) async => connectImap(),
    namespace: _namespace,
  );
  late final store = MailObjectStoreImap(
    db,
    accounts,
    mailboxes,
    storage,
    imapConnect: (_, __, ___) async => connectImap(),
    namespace: _namespace,
    keyLookup: lookupKey,
    writeKey: writeKeyFor,
    projectors: projectors,
  );

  static Future<String> _namespace(Object client) =>
      (client as StatefulFakeImapClient).namespace();
}
