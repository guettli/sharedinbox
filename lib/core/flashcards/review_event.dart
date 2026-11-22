/// Events of the flash card review log (ENCRYPTED-OBJECTS.md, section 7).
///
/// In a log segment the device id lives in the segment head, not in each
/// event. The parser (#1380) copies it into [CardEvent.deviceId] so replay can
/// dedupe and order events from several devices.
sealed class CardEvent {
  const CardEvent({
    required this.deviceId,
    required this.seq,
    required this.h,
  });

  /// Device that wrote the event (from the segment head).
  final String deviceId;

  /// Per-device sequence number (`s`).
  final int seq;

  /// Hybrid logical clock string; sorts lexicographically (spec 5.3).
  final String h;
}

/// `{op: "review", c, s, h, t, r, ms}`.
class ReviewEvent extends CardEvent {
  const ReviewEvent({
    required super.deviceId,
    required super.seq,
    required super.h,
    required this.cardId,
    required this.t,
    required this.rating,
    this.ms = 0,
  });

  final String cardId;

  /// Wall-clock time of the review in milliseconds since epoch.
  final int t;

  /// Rating 1 (again) … 4 (easy). Kept as the raw number: replay drops
  /// reviews with any other value instead of failing.
  final int rating;

  /// How long the review took, in milliseconds.
  final int ms;

  @override
  bool operator ==(Object other) =>
      other is ReviewEvent &&
      other.deviceId == deviceId &&
      other.seq == seq &&
      other.h == h &&
      other.cardId == cardId &&
      other.t == t &&
      other.rating == rating &&
      other.ms == ms;

  @override
  int get hashCode => Object.hash(deviceId, seq, h, cardId, t, rating, ms);

  @override
  String toString() => 'ReviewEvent(deviceId: $deviceId, seq: $seq, h: $h, '
      'cardId: $cardId, t: $t, rating: $rating, ms: $ms)';
}

/// `{op: "undo", s, h, ref: [deviceId, seq]}`: cancels the review written as
/// sequence number [refSeq] by device [refDeviceId].
class UndoEvent extends CardEvent {
  const UndoEvent({
    required super.deviceId,
    required super.seq,
    required super.h,
    required this.refDeviceId,
    required this.refSeq,
  });

  final String refDeviceId;
  final int refSeq;

  @override
  bool operator ==(Object other) =>
      other is UndoEvent &&
      other.deviceId == deviceId &&
      other.seq == seq &&
      other.h == h &&
      other.refDeviceId == refDeviceId &&
      other.refSeq == refSeq;

  @override
  int get hashCode => Object.hash(deviceId, seq, h, refDeviceId, refSeq);

  @override
  String toString() => 'UndoEvent(deviceId: $deviceId, seq: $seq, h: $h, '
      'refDeviceId: $refDeviceId, refSeq: $refSeq)';
}
