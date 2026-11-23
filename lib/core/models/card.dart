/// What a flash card shows (ENCRYPTED-OBJECTS.md §7): Markdown front and
/// back, and tags.
class CardContent {
  const CardContent({
    required this.front,
    required this.back,
    this.tags = const [],
  });

  final String front;
  final String back;
  final List<String> tags;

  @override
  bool operator ==(Object other) =>
      other is CardContent &&
      other.front == front &&
      other.back == back &&
      _listEquals(other.tags, tags);

  @override
  int get hashCode => Object.hash(front, back, Object.hashAll(tags));

  @override
  String toString() => 'CardContent($front / $back, $tags)';
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A card to add; [cardId] null takes a new random one (an import may pass
/// stable ids instead).
class NewCard {
  const NewCard(this.content, {this.cardId});

  final String? cardId;
  final CardContent content;
}

/// Where the version of a card shown comes from.
enum CardSourceKind {
  /// A member of a `card-batch` document.
  batch,

  /// A `card` document of its own.
  doc,
}

/// One flash card, as its projection shows it: the source with the highest
/// HLC `h` of all batch members and `card` docs of its cardId.
class FlashCard {
  const FlashCard({
    required this.accountId,
    required this.cardId,
    required this.deckId,
    required this.content,
    required this.h,
    required this.sourceItemHmac,
    required this.sourceKind,
    this.hasConflict = false,
  });

  final String accountId;
  final String cardId;

  /// The `collectionId` of its deck.
  final String deckId;
  final CardContent content;

  /// The encoded HLC of the version shown.
  final String h;

  /// The item HMAC (base64url) of the batch or `card` doc it comes from.
  final String sourceItemHmac;
  final CardSourceKind sourceKind;

  /// Its `card` doc has several heads with different content.
  final bool hasConflict;

  String get front => content.front;
  String get back => content.back;
  List<String> get tags => content.tags;
}

/// A deck: a collection with its own key (ENCRYPTED-OBJECTS.md 4.1) whose
/// name sits in a `deck` document inside it.
class Deck {
  const Deck({
    required this.accountId,
    required this.deckId,
    required this.itemHmac,
    required this.name,
    required this.versionId,
    required this.updatedAt,
    this.hasConflict = false,
  });

  final String accountId;

  /// The `collectionId` of the deck.
  final String deckId;

  /// The item HMAC (base64url) of its `deck` document.
  final String itemHmac;
  final String name;

  /// The encoded HLC of the version shown.
  final String versionId;

  /// The wall clock of [versionId].
  final DateTime updatedAt;

  /// Several heads with different content.
  final bool hasConflict;
}
