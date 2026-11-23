import 'package:sharedinbox/core/models/user_preferences.dart';

abstract class UserPreferencesRepository {
  Stream<UserPreferences> observePreferences();
  Future<void> updateMenuPosition(MenuPosition position);
  Future<void> updateAfterMailViewAction(AfterMailViewAction action);
  Future<void> updatePrefetchMode(PrefetchMode mode);
  Future<void> updateBodyCacheLimitMb(int mb);
  Future<void> updatePersonalDataBeta({required bool enabled});

  /// Null: no preference.
  Future<void> updateDefaultItemsAccountId(String? accountId);

  Stream<List<String>> observeTrustedImageSenders();
  Future<void> addTrustedImageSender(String senderEmail);
  Future<void> removeTrustedImageSender(String senderEmail);
}
