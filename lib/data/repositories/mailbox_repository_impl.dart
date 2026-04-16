import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;

import '../../core/models/mailbox.dart';
import '../../core/repositories/account_repository.dart';
import '../../core/repositories/mailbox_repository.dart';
import '../db/database.dart';
import '../db/database.dart' as db show Mailbox;
import '../../core/utils/logger.dart';
import '../imap/imap_client_factory.dart';

class MailboxRepositoryImpl implements MailboxRepository {
  MailboxRepositoryImpl(this._db, this._accounts);

  final AppDatabase _db;
  final AccountRepository _accounts;

  @override
  Stream<List<Mailbox>> observeMailboxes(String accountId) {
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
    final client = await connectImap(account, password);
    try {
      // listMailboxes() returns List<imap.Mailbox>
      final mailboxes = await client.listMailboxes(recursive: true);
      for (final mb in mailboxes) {
        final path = mb.path;
        final id = '${accountId}:$path';

        // Fetch STATUS (unread + total counts) for each mailbox.
        // Suppress errors — some mailboxes (e.g. \Noselect) can't be selected.
        int unread = 0;
        int total = 0;
        try {
          final status = await client.statusMailbox(
            mb,
            [imap.StatusFlags.messages, imap.StatusFlags.unseen],
          );
          unread = status.messagesUnseen;
          total = status.messagesExists;
        } catch (e) {
          // \Noselect mailboxes can't be STATUSed — skip counts silently.
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

  Mailbox _toModel(db.Mailbox row) => Mailbox(
        id: row.id,
        accountId: row.accountId,
        path: row.path,
        name: row.name,
        unreadCount: row.unreadCount,
        totalCount: row.totalCount,
      );
}
