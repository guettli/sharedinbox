import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';

/// The log of the review events: segments `review-seg`, packs `review-pack`.
const reviewLogName = 'review';

/// Events of the flash card review log (ENCRYPTED-OBJECTS.md, section 7).
///
/// In a log segment the device id lives in the segment head, not in each
/// event. [CardEvent.fromLogEvent] copies it (the writer of `h`) into
/// [CardEvent.deviceId] so replay can dedupe and order events from several
/// devices.
sealed class CardEvent {
  const CardEvent({
    required this.deviceId,
    required this.seq,
    required this.h,
  });

  /// Reads the wire event [event]; null for an unknown `op` or a malformed
  /// event, which the log skips.
  static CardEvent? fromLogEvent(LogEvent event) {
    final json = event.json;
    final deviceId = event.deviceId;
    final h = event.hlc.encode();
    switch (json['op']) {
      case 'review':
        final (c, t, r, ms) = (json['c'], json['t'], json['r'], json['ms']);
        if (c is! String || t is! int || r is! int) return null;
        return ReviewEvent(
          deviceId: deviceId,
          seq: event.seq,
          h: h,
          cardId: c,
          t: t,
          rating: r,
          ms: ms is int ? ms : 0,
        );
      case 'undo':
        final ref = json['ref'];
        if (ref is! List || ref.length != 2) return null;
        final [refDevice, refSeq] = ref;
        if (refDevice is! String || refSeq is! int) return null;
        return UndoEvent(
          deviceId: deviceId,
          seq: event.seq,
          h: h,
          refDeviceId: refDevice,
          refSeq: refSeq,
        );
    }
    return null;
  }

  /// The wire event: `{op: "review", c, s, h, t, r, ms}` or
  /// `{op: "undo", s, h, ref}`, without the deviceId (the segment head
  /// holds it).
  Map<String, Object?> toJson();

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
  Map<String, Object?> toJson() => {
        'op': 'review',
        'c': cardId,
        's': seq,
        'h': h,
        't': t,
        'r': rating,
        'ms': ms,
      };

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
  Map<String, Object?> toJson() => {
        'op': 'undo',
        's': seq,
        'h': h,
        'ref': [refDeviceId, refSeq],
      };

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
