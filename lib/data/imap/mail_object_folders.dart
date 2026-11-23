import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;

import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';
import 'package:sharedinbox/data/imap/imap_namespace.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart'
    show appDataRootName;

/// Folder layout of the encrypted-object store on IMAP
/// (ENCRYPTED-OBJECTS.md §3): `<prefix>SharedInbox<sep>Keys|Data`, with the
/// personal NAMESPACE prefix (RFC 2342, e.g. `INBOX.`) and the server's
/// hierarchy separator.

/// [SyncStates.resourceType] of the cached personal NAMESPACE prefix.
const namespaceStateKey = 'mos:namespace';

/// The name of the subfolder of [folder].
String mailObjectFolderName(MailObjectFolder folder) => switch (folder) {
      MailObjectFolder.keys => 'Keys',
      MailObjectFolder.data => 'Data',
    };

/// The path of `SharedInbox` under [prefix].
String mailObjectRootPath(String prefix) => '$prefix$appDataRootName';

/// The path of [folder] under [prefix], joined with [separator].
String mailObjectFolderPath(
  MailObjectFolder folder, {
  required String prefix,
  required String separator,
}) =>
    '${mailObjectRootPath(prefix)}$separator${mailObjectFolderName(folder)}';

/// The personal NAMESPACE prefix of [accountId] as cached by the last
/// [imapNamespacePrefix]; `''` when none was cached.
Future<String> storedImapNamespacePrefix(
  AppDatabase db,
  String accountId,
) async =>
    await _cachedPrefix(db, accountId) ?? '';

Future<String?> _cachedPrefix(AppDatabase db, String accountId) async {
  final row = await (db.select(db.syncStates)
        ..where(
          (t) =>
              t.accountId.equals(accountId) &
              t.resourceType.equals(namespaceStateKey),
        ))
      .getSingleOrNull();
  return row?.state;
}

/// The personal NAMESPACE prefix of [accountId]: the cached one, else asked
/// over [client] with [ask] when the server advertises `NAMESPACE` (and
/// cached), else `''`. A failed NAMESPACE gives `''` and caches nothing.
Future<String> imapNamespacePrefix(
  AppDatabase db,
  String accountId,
  imap.ImapClient client,
  ImapNamespaceFn ask,
) async {
  final cached = await _cachedPrefix(db, accountId);
  if (cached != null) return cached;
  var prefix = '';
  if (client.serverInfo.supports('NAMESPACE')) {
    try {
      prefix = await ask(client);
    } catch (e) {
      if (isImapConnectionLost(e)) rethrow;
      return '';
    }
  }
  await db.into(db.syncStates).insertOnConflictUpdate(
        SyncStatesCompanion.insert(
          accountId: accountId,
          resourceType: namespaceStateKey,
          state: prefix,
          syncedAt: DateTime.now(),
        ),
      );
  return prefix;
}

/// Creates `SharedInbox` and [folder] under [prefix] where missing; a folder
/// that already exists is fine. Returns both paths (for
/// `registerAppDataFolders`).
Future<List<String>> ensureMailObjectFolder(
  imap.ImapClient client,
  MailObjectFolder folder, {
  required String prefix,
  required String separator,
}) async {
  final paths = [
    mailObjectRootPath(prefix),
    mailObjectFolderPath(folder, prefix: prefix, separator: separator),
  ];
  for (final path in paths) {
    try {
      await client.createMailbox(path);
    } catch (e) {
      if (isImapConnectionLost(e) || !_alreadyExists(e)) rethrow;
    }
  }
  return paths;
}

bool _alreadyExists(Object error) {
  final s = error.toString().toLowerCase();
  return s.contains('alreadyexists') || s.contains('already exist');
}
