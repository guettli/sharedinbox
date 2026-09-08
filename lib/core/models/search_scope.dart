/// Which accounts/folders a local search covers. Chosen by the user via the
/// scope chips shown above the search field, and combined with a separate
/// "include trash & junk" toggle.
///
/// The default is [all] with the toggle off: every account, every folder, but
/// junk and trash excluded — searching for a message should not surface the
/// spam and deleted mail the user has already moved out of the way. The
/// remaining values narrow to the account or folder the search was launched
/// from.
enum SearchScope {
  /// Every account and folder.
  all,

  /// Only the account the search was launched from.
  currentAccount,

  /// Only the folder the search was launched from.
  currentFolder;

  /// The `accountId` to pass to the repository, given the account the search
  /// was launched from ([contextAccountId]). `null` means "all accounts".
  String? accountIdFor(String? contextAccountId) =>
      this == SearchScope.all ? null : contextAccountId;

  /// The `mailboxPath` to pass to the repository, given the folder the search
  /// was launched from ([contextMailboxPath]). `null` means "all folders".
  String? mailboxPathFor(String? contextMailboxPath) =>
      this == SearchScope.currentFolder ? contextMailboxPath : null;

  /// A folder-scoped search always includes junk/trash: the user has explicitly
  /// pointed at one folder, so results from it must show even when that folder
  /// *is* Junk or Trash. For the other scopes junk/trash inclusion is governed
  /// solely by the separate toggle.
  bool get alwaysIncludesJunkTrash => this == SearchScope.currentFolder;

  /// Short label for the scope chip.
  String get label => switch (this) {
        SearchScope.all => 'All accounts',
        SearchScope.currentAccount => 'This account',
        SearchScope.currentFolder => 'This folder',
      };
}
