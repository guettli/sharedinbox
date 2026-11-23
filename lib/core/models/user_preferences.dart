enum MenuPosition { bottom, top }

enum AfterMailViewAction { nextMessage, showMailbox }

enum PrefetchMode {
  disabled,
  wifiOnly,
  always;

  static PrefetchMode fromString(String? value) {
    return PrefetchMode.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PrefetchMode.wifiOnly,
    );
  }
}

class UserPreferences {
  const UserPreferences({
    this.menuPosition = MenuPosition.bottom,
    this.afterMailViewAction = AfterMailViewAction.nextMessage,
    this.prefetchMode = PrefetchMode.wifiOnly,
    this.bodyCacheLimitMb = 100,
    this.personalDataBeta = false,
    this.defaultItemsAccountId,
  });
  final MenuPosition menuPosition;
  final AfterMailViewAction afterMailViewAction;
  final PrefetchMode prefetchMode;
  final int bodyCacheLimitMb;

  /// "Personal data (beta)": the encrypted personal-data UI and its key
  /// sync (#1366). Turning it off never deletes keys.
  final bool personalDataBeta;

  /// The account new todos and entries go to (#1357); null: see
  /// [resolveNewItemAccount].
  final String? defaultItemsAccountId;
}

/// The account a new item goes to: the preferred one, else [currentAccountId],
/// else the first of [unlocked]; each only while unlocked. Null when no
/// account is unlocked.
String? resolveNewItemAccount(
  UserPreferences prefs,
  List<String> unlocked, {
  String? currentAccountId,
}) {
  for (final id in [prefs.defaultItemsAccountId, currentAccountId]) {
    if (id != null && unlocked.contains(id)) return id;
  }
  return unlocked.firstOrNull;
}
