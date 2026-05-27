import 'package:sharedinbox/core/models/user_preferences.dart';

abstract class UserPreferencesRepository {
  Stream<UserPreferences> observePreferences();
  Future<void> updateMenuPosition(MenuPosition position);
}
