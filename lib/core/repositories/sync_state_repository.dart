import 'package:sharedinbox/core/models/mailbox_sync_state.dart';

/// Read-only view of the local database that classifies every mail in every
/// mailbox by its offline-availability state. Backs the Sync state screen.
abstract class SyncStateRepository {
  /// One entry per mailbox for [accountId], sorted like the folder tree
  /// (Inbox first, then alphabetical by displayPath).
  Future<List<MailboxSyncState>> statesForAccount(String accountId);
}
