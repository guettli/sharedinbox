import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/flashcards/review_params.dart';

/// What deck is left to study (#1381): reviews due, (re)learning cards due
/// within the learn-ahead window (`learnAhead`), and new cards up to what is
/// left of `newPerDay` today.
typedef DeckCounts = ({int due, int learning, int newCards});

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

  /// The cards of deck [deckId] never reviewed (no counted review), not
  /// deleted, in creation order (`h`). Not capped by `newPerDay`.
  Stream<List<String>> observeNew(String accountId, String deckId);

  /// [DeckCounts] per deckId of every deck of [accountId] with a card, at
  /// [nowMs]. Deleted cards are not counted.
  Stream<Map<String, DeckCounts>> observeDeckCounts(
    String accountId,
    int nowMs,
  );

  /// The effective scheduler params of deck [deckId].
  Future<FsrsParams> deckParams(String accountId, String deckId);

  /// How many new cards of deck [deckId] may still be studied today:
  /// `newPerDay` less the cards whose first counted review is in the
  /// current study day (it starts at the deck's `dayStartHour`).
  Future<int> newLeftToday(String accountId, String deckId);

  /// A study session of [accountId] ended: its reviews are uploaded soon.
  void endSession(String accountId);
}
