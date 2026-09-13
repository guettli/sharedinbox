/// Timing breakdown of a single outbox send attempt, collected while a queued
/// message is transmitted so the application log can explain *why* a send took
/// as long as it did (#801). Without this the user only saw "message queued"
/// then, minutes later, "sent" — with no way to tell whether the time went on
/// waiting in the queue or on a slow server handshake.
///
/// [queuedFor] is how long the message sat in the outbox before this attempt
/// started transmitting (the sync loop only drains the queue once per cycle, so
/// this is usually the dominant cost). [phases] are the individual network legs
/// (SMTP connect/auth, SMTP send, IMAP append to Sent, …) in the order they
/// ran. [total] is the wall-clock time the whole transmission took.
class SendTiming {
  SendTiming({required this.queuedFor});

  final Duration queuedFor;
  final List<SendPhase> phases = [];
  Duration total = Duration.zero;

  /// Records how long one network leg took. Called from the send path as each
  /// phase completes (including phases that timed out — a slow phase is exactly
  /// what the user wants to see).
  void record(String name, Duration elapsed) =>
      phases.add(SendPhase(name, elapsed));

  /// One-line human summary appended to the "sent" log message, e.g.
  /// `queued 4m 12s, sent in 3.1s (SMTP connect/auth 1.1s, SMTP send message
  /// 0.4s, IMAP connect/login 0.9s, IMAP append to Sent folder 0.7s)`.
  String get summary {
    final buffer = StringBuffer()
      ..write('queued ${formatSendDuration(queuedFor)}, ')
      ..write('sent in ${formatSendDuration(total)}');
    if (phases.isNotEmpty) {
      final legs =
          phases.map((p) => '${p.name} ${formatSendDuration(p.elapsed)}');
      buffer.write(' (${legs.join(', ')})');
    }
    return buffer.toString();
  }

  /// Structured fields merged into the log entry's `data` map so the numbers
  /// are machine-readable in the application-log detail view, not just prose.
  Map<String, Object> toLogData() => {
        'queuedForMs': queuedFor.inMilliseconds,
        'transmitMs': total.inMilliseconds,
        'phaseMs': {
          for (final p in phases) p.name: p.elapsed.inMilliseconds,
        },
      };
}

/// A single network leg of a send, with the wall-clock time it took.
class SendPhase {
  const SendPhase(this.name, this.elapsed);
  final String name;
  final Duration elapsed;
}

/// Formats a duration for a send log entry: `4m 12s` for minutes, `3.1s` for
/// seconds, `340ms` for sub-second legs. Kept coarse on purpose — the user is
/// diagnosing "why does this take minutes", not micro-benchmarking.
String formatSendDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms >= 60000) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds - minutes * 60;
    return '${minutes}m ${seconds}s';
  }
  if (ms >= 1000) {
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
  return '${ms}ms';
}
