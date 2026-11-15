/// Work of one account that exists only on this device. Removing the account
/// discards all of it, so the confirm dialog lists it (#1237).
class UnsyncedWork {
  const UnsyncedWork({
    this.queuedChanges = 0,
    this.unsentEmails = 0,
    this.unsyncedNotes = 0,
    this.localFilters = 0,
    this.notificationRules = 0,
  });

  /// Read/star/move/delete/snooze changes waiting in the pending queue.
  final int queuedChanges;

  /// Messages in the outbox, still waiting or failed.
  final int unsentEmails;

  /// Notes added locally but not yet uploaded.
  final int unsyncedNotes;

  /// Local filter scripts; they never go to the server.
  final int localFilters;

  /// Notification rules; they never go to the server.
  final int notificationRules;

  bool get isEmpty =>
      queuedChanges == 0 &&
      unsentEmails == 0 &&
      unsyncedNotes == 0 &&
      localFilters == 0 &&
      notificationRules == 0;

  /// One human-readable line per non-zero kind, e.g. "2 unsent emails".
  List<String> describe() => [
        if (unsentEmails > 0) _count(unsentEmails, 'unsent email'),
        if (queuedChanges > 0)
          '${_count(queuedChanges, 'queued change')} '
              '(read, star, move, delete, snooze)',
        if (unsyncedNotes > 0) _count(unsyncedNotes, 'new note'),
        if (localFilters > 0) _count(localFilters, 'local filter'),
        if (notificationRules > 0)
          _count(notificationRules, 'notification rule'),
      ];

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}

abstract class UnsyncedWorkRepository {
  Future<UnsyncedWork> countForAccount(String accountId);
}
