enum MenuPosition { bottom, top }

class UserPreferences {
  const UserPreferences({this.menuPosition = MenuPosition.bottom});
  final MenuPosition menuPosition;
}
