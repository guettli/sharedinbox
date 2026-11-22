import 'package:sharedinbox/core/flashcards/fsrs.dart';

/// A time zone with a constant UTC offset.
class FixedOffsetTimeZone extends LocalTimeZone {
  const FixedOffsetTimeZone(this.offset);

  final Duration offset;

  @override
  DateTime toLocal(int wallMs) => DateTime.fromMillisecondsSinceEpoch(
        wallMs + offset.inMilliseconds,
        isUtc: true,
      );

  @override
  int fromLocal(int year, int month, int day, int hour) =>
      DateTime.utc(year, month, day, hour).millisecondsSinceEpoch -
      offset.inMilliseconds;
}

/// A time zone that moves from [before] to [after] at instant [switchMs]
/// (like a DST change).
class SwitchingTimeZone extends LocalTimeZone {
  const SwitchingTimeZone({
    required this.switchMs,
    required this.before,
    required this.after,
  });

  final int switchMs;
  final Duration before;
  final Duration after;

  Duration _offsetAt(int ms) => ms < switchMs ? before : after;

  @override
  DateTime toLocal(int wallMs) => DateTime.fromMillisecondsSinceEpoch(
        wallMs + _offsetAt(wallMs).inMilliseconds,
        isUtc: true,
      );

  @override
  int fromLocal(int year, int month, int day, int hour) {
    final wall = DateTime.utc(year, month, day, hour).millisecondsSinceEpoch;
    final withAfter = wall - after.inMilliseconds;
    if (withAfter >= switchMs) return withAfter;
    return wall - before.inMilliseconds;
  }
}
