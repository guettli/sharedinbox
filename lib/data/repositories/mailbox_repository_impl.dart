import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;

import '../../core/models/account.dart' as account_model;
import '../../core/models/mailbox.dart' as model;
import '../../core/repositories/account_repository.dart';
import '../../core/repositories/mailbox_repository.dart';
import '../../core/utils/logger.dart';
import '../db/database.dart';
import '../imap/imap_client_factory.dart';
import 'email_repository_impl.dart' show ImapConnectFn;

class MailboxRepositoryImpl implements MailboxRepository {
  MailboxRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
  }) : _imapConnect = imapConnect;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;

  String _effectiveUsername(account_model.Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

  @override
  Stream<List<model.Mailbox>> observeMailboxes(String accountId) {
    return (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.path)]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  @override
  Future<void> syncMailboxes(String accountId) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final client = await _imapConnect(account, _effectiveUsername(account), password);
    try {
      final mailboxes = await client.listMailboxes(recursive: true);
      for (final mb in mailboxes) {
        final path = mb.path;
        final id = '$accountId:$path';

        // Fetch STATUS (unread + total counts). Some mailboxes (\Noselect)
        // can't be selected — skip counts for those silently.
        var unread = 0;
        var total = 0;
        try {
          final status = await client.statusMailbox(
            mb,
            [imap.StatusFlags.messages, imap.StatusFlags.unseen],
          );
          unread = status.messagesUnseen;
          total = status.messagesExists;
        } catch (e) {
          log('STATUS skipped for $path: $e');
        }

        await _db.into(_db.mailboxes).insertOnConflictUpdate(
              MailboxesCompanion.insert(
                id: id,
                accountId: accountId,
                path: path,
                name: mb.name,
                unreadCount: Value(unread),
                totalCount: Value(total),
              ),
            );
      }
    } finally {
      await client.logout();
    }
  }

  model.Mailbox _toModel(MailboxRow row) => model.Mailbox(
        id: row.id,
        accountId: row.accountId,
        path: row.path,
        name: row.name,
        unreadCount: row.unreadCount,
        totalCount: row.totalCount,
      );
}
