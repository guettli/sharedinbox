import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/card.dart';

/// Flash cards and decks (ENCRYPTED-OBJECTS.md §7, #1379).
///
/// - `card`: one card; `tags` in the head, front and back as `text/markdown`
///   parts with Content-ID `front` / `back`. Its itemId is the cardId; the
///   HLC `h` of a version is its `versionId`.
/// - `card-batch`: up to [maxCardsPerBatch] cards of an import; `count` in
///   the head, the members as one gzip JSONL part, one line
///   `{c: cardId, h, f: front, b: back, tags}` each. Every member carries
///   its own `h`. Batch merge = per cardId the member with the highest `h`:
///   concurrent rewrites merge, they are never a conflict.
/// - `deck`: the name of a deck (`name` in the head); itemId = the deck's
///   `collectionId`, so it lives encrypted in the deck's own collection.
///
/// A card shows the source with the highest `h` of all batch members and
/// `card` docs of its cardId; a `card` tombstone deletes it.

const cardKind = 'card';
const cardBatchKind = 'card-batch';
const deckKind = 'deck';

/// At most this many cards in one batch.
const maxCardsPerBatch = 500;

/// At most this many bytes of gzip body in one batch: well below the
/// eager-fetch limit of 256 KiB (5.5), so batches always come with the
/// normal sync.
const maxBatchBodyBytes = 200 * 1024;

/// Content type of the batch body: the gzip JSONL of the log segments.
const cardBatchContentType = logBodyContentType;

const _markdownType = 'text/markdown; charset=utf-8';
const _frontId = 'front';
const _backId = 'back';

/// A new deck id: `deck-` and a random itemId.
String newDeckId() => 'deck-${newItemId()}';

// ── card ────────────────────────────────────────────────────────────────────

ObjectPart _markdownPart(String id, String text) => ObjectPart(
      contentType: _markdownType,
      contentId: id,
      bytes: Uint8List.fromList(utf8.encode(text)),
    );

bool _isMarkdown(ObjectPart p) =>
    p.contentType.split(';').first.trim().toLowerCase() == 'text/markdown';

bool _isSide(ObjectPart p) =>
    _isMarkdown(p) && (p.contentId == _frontId || p.contentId == _backId);

String _partText(InnerObject object, String id) {
  final part = object.parts
      .where((p) => _isMarkdown(p) && p.contentId == id)
      .firstOrNull;
  return part == null ? '' : utf8.decode(part.bytes, allowMalformed: true);
}

/// A new `card` doc in deck [deckId]; [cardId] null takes a new one.
InnerObject newCardObject({
  required String deckId,
  String? cardId,
  required CardContent content,
  required HlcClock clock,
}) =>
    InnerObject(
      head: ObjectHead(
        itemId: cardId ?? newItemId(),
        collectionId: deckId,
        versionId: clock.send(),
        kind: cardKind,
        extra: {'tags': content.tags},
      ),
      parts: [
        _markdownPart(_frontId, content.front),
        _markdownPart(_backId, content.back),
      ],
    );

/// What the `card` doc [object] shows; null for a tombstone or another
/// kind. Missing parts read as empty.
CardContent? cardContentOf(InnerObject object) {
  final head = object.head;
  if (head.deleted || head.kind != cardKind) return null;
  return CardContent(
    front: _partText(object, _frontId),
    back: _partText(object, _backId),
    tags: _strings(head.extra['tags']),
  );
}

/// An edit of card [cardId] of deck [deckId] to [content]. With [base] (a
/// head of [merge]) the doc gets a new version with `parents = all heads`,
/// unknown fields and parts kept; without, it is the first `card` doc of a
/// batch member (`parents: []`). The new `h` is above [above], the `h` of
/// the version shown, so the edit always wins over it.
InnerObject editCardObject({
  required String deckId,
  required String cardId,
  required CardContent content,
  required HlcClock clock,
  InnerObject? base,
  MergeResult? merge,
  Hlc? above,
}) {
  _passAbove(clock, above);
  if (base == null || merge == null) {
    return newCardObject(
      deckId: deckId,
      cardId: cardId,
      content: content,
      clock: clock,
    );
  }
  return edit(
    base: base,
    merge: merge,
    clock: clock,
    fields: {'tags': content.tags},
    parts: [
      _markdownPart(_frontId, content.front),
      _markdownPart(_backId, content.back),
      for (final p in base.parts)
        if (!_isSide(p)) p,
    ],
  );
}

/// A delete of card [cardId] of deck [deckId]: with [base] (a head of
/// [merge]) a tombstone over all heads of its doc; without, a first `card`
/// doc that is a tombstone (`parents: []`), for a batch member. Its `h` is
/// above [above], the `h` of the version shown.
InnerObject deleteCardObject({
  required String deckId,
  required String cardId,
  required HlcClock clock,
  InnerObject? base,
  MergeResult? merge,
  Hlc? above,
}) {
  _passAbove(clock, above);
  if (base != null && merge != null) {
    return tombstone(base: base, merge: merge, clock: clock);
  }
  return InnerObject(
    head: ObjectHead(
      itemId: cardId,
      collectionId: deckId,
      versionId: clock.send(),
      deleted: true,
      kind: cardKind,
    ),
  );
}

/// The next [HlcClock.send] is above [above]. Without the skew guard of
/// [HlcClock.receive]: the user edits what they see, so the edit must win
/// over it even when its writer's clock ran ahead.
void _passAbove(HlcClock clock, Hlc? above) {
  if (above != null) clock.advancePast([above]);
}

// ── card-batch ──────────────────────────────────────────────────────────────

/// One card of a batch. Unknown fields ([extra]) are kept on rewrite.
class CardBatchMember {
  CardBatchMember({
    required this.cardId,
    required this.h,
    required this.content,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra);

  /// Reads a member line; throws [FormatException] without `c` and `h`.
  factory CardBatchMember.fromJson(Map<String, Object?> json) {
    final front = json['f'];
    final back = json['b'];
    return CardBatchMember(
      cardId: readStringField(json, 'c'),
      h: Hlc.parse(readStringField(json, 'h')),
      content: CardContent(
        front: front is String ? front : '',
        back: back is String ? back : '',
        tags: _strings(json['tags']),
      ),
      extra: unknownFields(json, _known),
    );
  }

  static const _known = {'c', 'h', 'f', 'b', 'tags'};

  final String cardId;
  final Hlc h;
  final CardContent content;
  final Map<String, Object?> extra;

  CardBatchMember copyWith({Hlc? h, CardContent? content}) => CardBatchMember(
        cardId: cardId,
        h: h ?? this.h,
        content: content ?? this.content,
        extra: extra,
      );

  Map<String, Object?> toJson() => {
        ...extra,
        'c': cardId,
        'h': h.encode(),
        'f': content.front,
        'b': content.back,
        'tags': content.tags,
      };
}

/// The members of the batch [object]; empty for a tombstone, another kind
/// or an unreadable body. A malformed line is skipped.
List<CardBatchMember> readBatchMembers(InnerObject object) {
  if (object.head.deleted || object.head.kind != cardBatchKind) {
    return const [];
  }
  final body = object.parts
      .where((p) => p.contentType == cardBatchContentType)
      .firstOrNull;
  if (body == null) return const [];
  final List<Map<String, Object?>> lines;
  try {
    lines = decodeJsonLinesBody(body.bytes);
  } on FormatException {
    return const [];
  }
  final members = <CardBatchMember>[];
  for (final line in lines) {
    try {
      members.add(CardBatchMember.fromJson(line));
    } on FormatException {
      continue;
    }
  }
  return members;
}

/// The objects of an import of [cards] into deck [deckId]: batches packed
/// greedily, each up to [maxCardsPerBatch] cards and [maxBatchBodyBytes] of
/// gzip body. Every card gets its own `h`. A card whose line alone is over
/// the body limit becomes a `card` doc instead.
List<InnerObject> cardBatchObjects({
  required String deckId,
  required List<NewCard> cards,
  required HlcClock clock,
}) =>
    _pack(
      deckId,
      [
        for (final c in cards)
          CardBatchMember(
            cardId: c.cardId ?? newItemId(),
            h: clock.send(),
            content: c.content,
          ),
      ],
      clock,
    );

/// Per cardId the member with the highest `h` over the batch [heads]
/// (tombstones skipped); ties go to the greater canonical JSON. Sorted by
/// cardId, so the result does not depend on the order of [heads].
List<CardBatchMember> mergeBatchMembers(List<InnerObject> heads) {
  final best = <String, CardBatchMember>{};
  for (final head in heads) {
    for (final m in readBatchMembers(head)) {
      final known = best[m.cardId];
      if (known == null || _beats(m, known)) best[m.cardId] = m;
    }
  }
  return best.values.toList()..sort((a, b) => a.cardId.compareTo(b.cardId));
}

bool _beats(CardBatchMember a, CardBatchMember b) {
  final byH = a.h.compareTo(b.h);
  if (byH != 0) return byH > 0;
  return canonicalJson(a.toJson()).compareTo(canonicalJson(b.toJson())) > 0;
}

/// A rewrite of the batch [base] (a head of [merge]) holding [members]
/// (usually [mergeBatchMembers] of all heads plus the changes, each changed
/// member with a new `h`). `parents = all heads`, so concurrent heads
/// collapse. The first object returned is the new version of the batch.
///
/// The only case where a rewrite drops members: when they no longer fit in
/// [maxCardsPerBatch] cards and [maxBatchBodyBytes], the members that do not
/// fit move to new batches (returned after it), each with a new `h` — the
/// highest `h` per cardId wins across items, so an older head still holding
/// one cannot shadow it.
List<InnerObject> rewriteBatchObject({
  required InnerObject base,
  required MergeResult merge,
  required List<CardBatchMember> members,
  required HlcClock clock,
}) {
  final lines = [for (final m in members) encodeJsonLine(m.toJson())];
  final kept = _fit(lines, 0);
  final rewritten = edit(
    base: base,
    merge: merge,
    clock: clock,
    fields: {'count': kept},
    parts: [
      ObjectPart(
        contentType: cardBatchContentType,
        bytes: gzipJsonLines(lines.take(kept)),
      ),
      for (final p in base.parts)
        if (p.contentType != cardBatchContentType) p,
    ],
  );
  final moved = [
    for (final m in members.skip(kept)) m.copyWith(h: clock.send()),
  ];
  return [rewritten, ..._pack(base.head.collectionId, moved, clock)];
}

/// [members] as batches of deck [deckId], in order; one too large for a
/// batch alone becomes a `card` doc written as its `h`.
List<InnerObject> _pack(
  String deckId,
  List<CardBatchMember> members,
  HlcClock clock,
) {
  final lines = [for (final m in members) encodeJsonLine(m.toJson())];
  final out = <InnerObject>[];
  var i = 0;
  while (i < members.length) {
    final n = _fit(lines, i);
    if (n == 0) {
      out.add(_soloCard(deckId, members[i]));
      i++;
      continue;
    }
    out.add(
      InnerObject(
        head: ObjectHead(
          itemId: newItemId(),
          collectionId: deckId,
          versionId: clock.send(),
          kind: cardBatchKind,
          extra: {'count': n},
        ),
        parts: [
          ObjectPart(
            contentType: cardBatchContentType,
            bytes: gzipJsonLines(lines.sublist(i, i + n)),
          ),
        ],
      ),
    );
    i += n;
  }
  return out;
}

InnerObject _soloCard(String deckId, CardBatchMember m) => InnerObject(
      head: ObjectHead(
        itemId: m.cardId,
        collectionId: deckId,
        versionId: m.h,
        kind: cardKind,
        extra: {'tags': m.content.tags},
      ),
      parts: [
        _markdownPart(_frontId, m.content.front),
        _markdownPart(_backId, m.content.back),
      ],
    );

/// How many of [lines] from [start] fit one batch: at most
/// [maxCardsPerBatch] and [maxBatchBodyBytes] of gzip, stopping before a
/// line too large alone (0 when the first one is).
int _fit(List<Uint8List> lines, int start) {
  var end = start;
  while (end < lines.length &&
      end - start < maxCardsPerBatch &&
      !_tooLargeAlone(lines[end])) {
    end++;
  }
  bool fits(int n) =>
      gzipJsonLines(lines.sublist(start, start + n)).length <=
      maxBatchBodyBytes;
  var hi = end - start;
  if (hi == 0 || fits(hi)) return hi;
  // The gzip size grows with the prefix: the largest prefix that fits.
  var lo = 1;
  hi--;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (fits(mid)) {
      lo = mid;
      continue;
    }
    hi = mid - 1;
  }
  return lo;
}

// gzip adds at most a few bytes per 16 KiB stored block plus its header, so a
// line 1 KiB below the limit always fits.
bool _tooLargeAlone(Uint8List line) =>
    line.length > maxBatchBodyBytes - 1024 &&
    gzipJsonLines([line]).length > maxBatchBodyBytes;

// ── deck ────────────────────────────────────────────────────────────────────

/// The `deck` doc of a new deck [deckId] (its collection) named [name].
InnerObject newDeckObject({
  required String deckId,
  required String name,
  required HlcClock clock,
}) =>
    InnerObject(
      head: ObjectHead(
        itemId: deckId,
        collectionId: deckId,
        versionId: clock.send(),
        kind: deckKind,
        extra: {'name': name},
      ),
    );

/// A rename of the deck doc [base] (a head of [merge]); unknown fields kept.
InnerObject editDeckObject({
  required InnerObject base,
  required MergeResult merge,
  required HlcClock clock,
  required String name,
}) =>
    edit(base: base, merge: merge, clock: clock, fields: {'name': name});

/// The name of the deck doc [object]; null for a tombstone or another kind.
String? deckNameOf(InnerObject object) {
  final head = object.head;
  if (head.deleted || head.kind != deckKind) return null;
  final name = head.extra['name'];
  return name is String ? name : '';
}

List<String> _strings(Object? json) => [
      if (json is List)
        for (final s in json)
          if (s is String) s,
    ];
