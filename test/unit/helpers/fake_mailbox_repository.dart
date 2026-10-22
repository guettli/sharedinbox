import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';

/// No-op [MailboxRepository] stand-in shared by the reliability-runner and
/// account-sync-manager suites, so each subclasses it instead of restating
/// the full interface (and tripping the jscpd duplication gate). Mirrors
/// [FakeEmailRepositoryBase] in this folder.
class FakeMailboxRepositoryBase implements MailboxRepository {
  FakeMailboxRepositoryBase([this.mailboxes = const []]);

  /// What [observeMailboxes] reports, for every account.
  final List<Mailbox> mailboxes;

  @override
  Stream<List<Mailbox>> observeMailboxes(String? accountId) =>
      Stream.value(mailboxes);
  @override
  Future<int> syncMailboxes(String accountId) async => 0;
  @override
  Future<Mailbox?> findMailboxByRole(String accountId, String role) async =>
      null;
  @override
  Future<void> clearForResync(String accountId) async {}
  @override
  Future<Mailbox> createMailboxWithRole(
    String accountId,
    String name,
    String role, {
    String? parentDisplayPath,
  }) async =>
      Mailbox(
        id: '$accountId:$name',
        accountId: accountId,
        path: name,
        name: name,
        role: role,
        unreadCount: 0,
        totalCount: 0,
      );
  @override
  Future<Mailbox> createMailbox(
    String accountId,
    String name, {
    String? parentDisplayPath,
  }) async =>
      Mailbox(
        id: '$accountId:$name',
        accountId: accountId,
        path: name,
        name: name,
        unreadCount: 0,
        totalCount: 0,
      );

  @override
  Future<Mailbox> renameMailbox(
    String accountId,
    String mailboxPath,
    String newName,
  ) async =>
      Mailbox(
        id: '$accountId:$mailboxPath',
        accountId: accountId,
        path: mailboxPath,
        name: newName,
        unreadCount: 0,
        totalCount: 0,
      );

  @override
  Future<void> deleteMailbox(String accountId, String mailboxPath) async {}

  @override
  Future<Mailbox> moveMailbox(
    String accountId,
    String mailboxPath, {
    required String? newParentDisplayPath,
  }) async =>
      Mailbox(
        id: '$accountId:$mailboxPath',
        accountId: accountId,
        path: mailboxPath,
        name: mailboxPath,
        unreadCount: 0,
        totalCount: 0,
      );
}
