/// Moves the legacy plaintext notes of an encrypted account into entries
/// (ENCRYPTED-OBJECTS.md §6, #1375). Runs in the foreground sync only: the
/// background isolate never deletes on the server (5.5).
abstract class LegacyNoteMigration {
  /// Before the object sync: the notes that never reached the server become
  /// entries at once; once the user confirmed, so do the synced ones.
  Future<void> beforeObjectSync(String accountId);

  /// After the object sync: once confirmed, the plaintext copy of every
  /// note whose entry is on the server is deleted.
  Future<void> afterObjectSync(String accountId);

  /// The number of synced legacy notes of [accountId] waiting for the
  /// user's confirmation; 0 once confirmed.
  Stream<int> watchAwaitingConfirmation(String accountId);

  /// The user agreed (on this device) that the synced legacy notes of
  /// [accountId] move into entries and their plaintext copies are deleted.
  Future<void> confirm(String accountId);
}
