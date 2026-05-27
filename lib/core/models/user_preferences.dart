enum MenuPosition { bottom, top }

enum AfterMailViewAction { nextMessage, showMailbox }

class UserPreferences {
  const UserPreferences({
    this.menuPosition = MenuPosition.bottom,
    this.mailViewButtonPosition = MenuPosition.bottom,
    this.afterMailViewAction = AfterMailViewAction.nextMessage,
  });
  final MenuPosition menuPosition;
  final MenuPosition mailViewButtonPosition;
  final AfterMailViewAction afterMailViewAction;
}
