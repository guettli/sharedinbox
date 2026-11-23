import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Hybrid logical clock and deviceId (`ENCRYPTED-OBJECTS.md` 5.3, 5.6).

/// A new random deviceId: base64url (no padding) of 16 random bytes.
String newDeviceId({RandomBytes random = secureRandomBytes}) =>
    b64url(random(idLength));

/// `(wallMs, counter, deviceId)`, encoded as the sortable string
/// `wallMs (13 digits) - counter (4 lowercase hex) - deviceId`.
class Hlc implements Comparable<Hlc> {
  Hlc(this.wallMs, this.counter, this.deviceId) {
    if (wallMs < 0 || wallMs > maxWallMs) {
      throw ArgumentError.value(wallMs, 'wallMs', 'must fit 13 digits');
    }
    if (counter < 0 || counter > maxCounter) {
      throw ArgumentError.value(counter, 'counter', 'must fit 4 hex digits');
    }
    if (deviceId.isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must not be empty');
    }
  }

  /// Parses the encoded form. The fields sit at fixed positions because a
  /// base64url deviceId may itself contain `-`.
  ///
  /// Throws [FormatException].
  factory Hlc.parse(String s) {
    final m = _pattern.firstMatch(s);
    if (m == null) throw FormatException('not an HLC', s);
    return Hlc(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!, radix: 16),
      m.group(3)!,
    );
  }

  static final _pattern = RegExp(r'^(\d{13})-([0-9a-f]{4})-(.+)$');

  static const maxWallMs = 9999999999999;
  static const maxCounter = 0xffff;

  final int wallMs;
  final int counter;
  final String deviceId;

  String encode() => '${wallMs.toString().padLeft(13, '0')}-'
      '${counter.toRadixString(16).padLeft(4, '0')}-$deviceId';

  @override
  int compareTo(Hlc other) => encode().compareTo(other.encode());

  bool operator >(Hlc other) => compareTo(other) > 0;

  bool operator <=(Hlc other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) => other is Hlc && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;

  @override
  String toString() => encode();
}

int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

/// The HLC of one device, plus its event `seq` counter (5.3, 5.4 item 2).
class HlcClock {
  HlcClock(
    this.deviceId, {
    int Function() nowMs = _systemNowMs,
    Hlc? high,
    int seqHigh = 0,
  })  : _nowMs = nowMs,
        _wallMs = high?.wallMs ?? 0,
        _counter = high?.counter ?? 0,
        _seq = seqHigh,
        _started = high != null;

  /// A remote timestamp further ahead of the local wall clock is not used
  /// to advance the clock.
  static const maxSkewMs = 5 * 60 * 1000;

  final String deviceId;
  final int Function() _nowMs;
  int _wallMs;
  int _counter;
  int _seq;
  bool _started;

  /// The highest timestamp issued or observed, or null before the first.
  Hlc? get high => _started ? Hlc(_wallMs, _counter, deviceId) : null;

  /// The highest `seq` issued or observed (0 = none).
  int get seqHigh => _seq;

  /// A timestamp for a local write, greater than every earlier one.
  Hlc send() {
    final now = _nowMs();
    _set(now > _wallMs ? now : _wallMs, now > _wallMs ? 0 : _counter + 1);
    return Hlc(_wallMs, _counter, deviceId);
  }

  /// Observes a remote timestamp so the next [send] is greater. Ignored if it
  /// is more than [maxSkewMs] ahead of the local wall clock.
  void receive(Hlc remote) {
    if (remote.wallMs > _nowMs() + maxSkewMs) return;
    _observe(remote);
  }

  /// Advances past every timestamp in [seen] without the skew guard — for
  /// this device's own versions seen locally or on the server before the
  /// first write (5.3).
  void advancePast(Iterable<Hlc> seen) {
    for (final t in seen) {
      _observe(t);
    }
  }

  /// The next event `seq`.
  int nextSeq() => ++_seq;

  /// Advances `seq` past [seq] (an own event seen before the first write).
  void advanceSeqPast(int seq) {
    if (seq > _seq) _seq = seq;
  }

  void _observe(Hlc t) {
    if (t.wallMs < _wallMs) return;
    if (t.wallMs == _wallMs && t.counter <= _counter) return;
    _set(t.wallMs, t.counter);
  }

  void _set(int wallMs, int counter) {
    _started = true;
    if (counter > Hlc.maxCounter) {
      _wallMs = wallMs + 1;
      _counter = 0;
      return;
    }
    _wallMs = wallMs;
    _counter = counter;
  }
}
