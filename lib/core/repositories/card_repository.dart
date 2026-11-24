import 'package:sharedinbox/core/models/card.dart';

/// The flash cards and decks of the encrypted personal data
/// (ENCRYPTED-OBJECTS.md §7, #1379). Reads come from the local projections;
/// writes go through the encrypted-object store, work offline and are
/// uploaded by its sync. Writes throw `NoWriteKeyException` while the
/// account is locked.
abstract class CardRepository {
  /// The decks of [accountId], by name.
  Stream<List<Deck>> observeDecks(String accountId);

  /// The cards of deck [deckId] that are not deleted, by cardId.
  Stream<List<FlashCard>> observeCards(String accountId, String deckId);

  /// The card [cardId], or null when unknown or deleted.
  Future<FlashCard?> card(String accountId, String cardId);

  /// A new deck: its own collection (and collection key) with a `deck` doc
  /// holding [name].
  Future<Deck> createDeck(String accountId, String name);

  Future<void> renameDeck(String accountId, String deckId, String name);

  /// How many cards of deck [deckId] are not deleted.
  Future<int> cardCount(String accountId, String deckId);

  /// Deletes deck [deckId]: a `card` tombstone for each of its cards, then
  /// a `deck` tombstone. The collection-key mail stays (#1381).
  Future<void> deleteDeck(String accountId, String deckId);

  /// Adds [cards] to deck [deckId] as `card-batch` docs (at most 500 cards
  /// and 200 KiB of body each). Returns the cardIds, in order.
  Future<List<String>> importCards(
    String accountId,
    String deckId,
    List<NewCard> cards,
  );

  /// Adds one card as a `card` doc of its own.
  Future<FlashCard> addCard(String accountId, String deckId, NewCard card);

  /// Sets the content of [cardId]. A batch member gets a `card` doc whose
  /// `h` is above the member's, so it overrides it.
  Future<void> editCard(String accountId, String cardId, CardContent content);

  /// Deletes [cardId] with a `card` tombstone.
  Future<void> deleteCard(String accountId, String cardId);

  /// Rewrites the batch [batchItemHmac]: the members of all its heads, with
  /// [changes] (by cardId; an unknown cardId is added) set, each with a new
  /// `h`. Collapses concurrent heads.
  Future<void> rewriteBatch(
    String accountId,
    String batchItemHmac,
    Map<String, CardContent> changes,
  );
}
