import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/flashcards/review_params.dart';

/// The flash card reviews of the encrypted personal data
/// (ENCRYPTED-OBJECTS.md §7, #1380). A rating or an undo is one local
/// insert and a recompute of that card's schedule; it never touches the
/// network. The pending events are written as `review` segments and
/// uploaded later (`ReviewUploadScheduler`).
abstract class ReviewRepository {
  /// Rates [cardId]. Returns the event, whose `deviceId` and `seq` [undo]
  /// takes.
  Future<ReviewEvent> rate(
    String accountId,
    String cardId,
    Rating rating, {
    int durationMs = 0,
  });

  /// Cancels the review [seq] of device [deviceId].
  Future<UndoEvent> undo(
    String accountId, {
    required String deviceId,
    required int seq,
  });

  /// Sets the global FSRS params (`fsrs.params`). Throws
  /// `NoWriteKeyException` while the account is locked.
  Future<void> setParams(String accountId, FsrsParams params);

  /// Sets the options of deck [deckId] (`deck.<deckId>.options`). Throws
  /// `NoWriteKeyException` while the account is locked.
  Future<void> setDeckOptions(
    String accountId,
    String deckId,
    DeckOptions options,
  );

  /// The schedule of [cardId]; null before its first counted review.
  Stream<CardSchedule?> observeSchedule(String accountId, String cardId);

  /// The reviewed cards of deck [deckId] due at [nowMs], earliest first.
  /// Cards never reviewed have no schedule and are not in it.
  Stream<List<(String cardId, CardSchedule schedule)>> observeDue(
    String accountId,
    String deckId,
    int nowMs,
  );

  /// A study session of [accountId] ended: its reviews are uploaded soon.
  void endSession(String accountId);
}
