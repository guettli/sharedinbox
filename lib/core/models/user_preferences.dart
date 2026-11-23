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
  });
  final MenuPosition menuPosition;
  final AfterMailViewAction afterMailViewAction;
  final PrefetchMode prefetchMode;
  final int bodyCacheLimitMb;

  /// "Personal data (beta)": the encrypted personal-data UI and its key
  /// sync (#1366). Turning it off never deletes keys.
  final bool personalDataBeta;
}
