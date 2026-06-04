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
    this.mailViewButtonPosition = MenuPosition.bottom,
    this.afterMailViewAction = AfterMailViewAction.nextMessage,
    this.prefetchMode = PrefetchMode.wifiOnly,
    this.bodyCacheLimitMb = 100,
  });
  final MenuPosition menuPosition;
  final MenuPosition mailViewButtonPosition;
  final AfterMailViewAction afterMailViewAction;
  final PrefetchMode prefetchMode;
  final int bodyCacheLimitMb;
}
