// The `keywords` and `location` overlays of SYNC-REDESIGN.md §2–§4, as pure
// functions: which queued changes (ops) fold into which `local_*` column,
// the folds themselves, and whether a server read agrees with an acked op.
// No database access here, so the schema migrations and the email state
// writer share it and it is unit-tested on its own.

/// `local_snoozed_until` of a row whose latest snooze intent is "not
/// snoozed" (an unsnooze, a move out of a snooze, a stale snooze cleared).
/// NULL means "no intent" in a `local_*` column, so the cleared state needs
/// a value of its own: the epoch, which no real snooze uses. The effective
/// `snoozed_until` is `NULLIF(COALESCE(local, srv), 0)`.
final snoozeCleared = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// Whether [value] (a `local_snoozed_until`) is [snoozeCleared].
bool isSnoozeCleared(DateTime? value) =>
    value != null && value.millisecondsSinceEpoch == 0;

/// The keyword columns of `emails` with a `srv_` / `local_` pair.
enum KeywordColumn { seen, flagged, snoozedUntil }

/// `pending_changes.state` values whose op folds into `local_*`: queued,
/// being sent, stuck (still retried), acked and not yet confirmed by a
/// later read (SYNC-REDESIGN.md §4.5), parked (the mail has no server copy
/// yet, §6) or a counterpart's shadow (§6). A `failed` op does not fold:
/// the row shows the server's value again (§5).
const foldableOpStates = [
  'pending',
  'inflight',
  'stuck',
  'acked',
  'parked',
  'shadow',
];

/// One queued change of a row, as far as the fold needs it.
class FoldOp {
  const FoldOp({
    required this.seq,
    required this.type,
    required this.payload,
    required this.state,
  });

  /// `pending_changes.id`: the fold applies ops in this order.
  final int seq;

  /// `pending_changes.change_type`.
  final String type;

  /// The decoded JSON payload; null when it is not a JSON object.
  final Map<String, dynamic>? payload;

  /// `pending_changes.state`.
  final String state;
}

/// The `local_*` keyword columns of a row. Null means no pending intent;
/// [snoozedUntil] is [snoozeCleared] for "not snoozed".
class KeywordLocal {
  const KeywordLocal({this.seen, this.flagged, this.snoozedUntil});

  static const none = KeywordLocal();

  final bool? seen;
  final bool? flagged;
  final DateTime? snoozedUntil;

  bool get isEmpty => seen == null && flagged == null && snoozedUntil == null;

  @override
  bool operator ==(Object other) =>
      other is KeywordLocal &&
      other.seen == seen &&
      other.flagged == flagged &&
      other.snoozedUntil?.millisecondsSinceEpoch ==
          snoozedUntil?.millisecondsSinceEpoch;

  @override
  int get hashCode =>
      Object.hash(seen, flagged, snoozedUntil?.millisecondsSinceEpoch);

  @override
  String toString() =>
      'KeywordLocal(seen: $seen, flagged: $flagged, snoozedUntil: '
      '${isSnoozeCleared(snoozedUntil) ? 'cleared' : snoozedUntil})';
}

/// What a server read says about a row's `keywords` group.
class ServerKeywords {
  const ServerKeywords({
    required this.seen,
    required this.flagged,
    required this.snoozedUntil,
  });

  /// The keywords of an IMAP FLAGS list or the keys of a JMAP `keywords`
  /// object.
  factory ServerKeywords.fromKeywords(
    Iterable<String> keywords, {
    required String seenKeyword,
    required String flaggedKeyword,
  }) {
    final list = keywords.toList();
    return ServerKeywords(
      seen: list.contains(seenKeyword),
      flagged: list.contains(flaggedKeyword),
      snoozedUntil: snoozedUntilFromKeywords(list),
    );
  }

  /// From an IMAP FLAGS list (null: none).
  factory ServerKeywords.imap(List<String>? flags) =>
      ServerKeywords.fromKeywords(
        flags ?? const [],
        seenKeyword: r'\Seen',
        flaggedKeyword: r'\Flagged',
      );

  /// From a JMAP `keywords` object (null: none).
  factory ServerKeywords.jmap(Map<String, dynamic>? keywords) =>
      ServerKeywords.fromKeywords(
        keywords?.keys ?? const [],
        seenKeyword: r'$seen',
        flaggedKeyword: r'$flagged',
      );

  final bool seen;
  final bool flagged;
  final DateTime? snoozedUntil;

  @override
  String toString() =>
      'ServerKeywords(seen: $seen, flagged: $flagged, snoozedUntil: '
      '$snoozedUntil)';
}

/// The wake-up time of the first `snz:YYYYMMDDTHHMMSSZ` keyword in
/// [keywords] (the format the snooze flush writes), or null.
DateTime? snoozedUntilFromKeywords(Iterable<String> keywords) {
  for (final keyword in keywords) {
    if (!keyword.startsWith('snz:')) continue;
    final ts = keyword.substring(4);
    if (ts.length < 15) return null;
    final formatted = '${ts.substring(0, 4)}-${ts.substring(4, 6)}-'
        '${ts.substring(6, 8)}T${ts.substring(9, 11)}:'
        '${ts.substring(11, 13)}:${ts.substring(13, 15)}Z';
    return DateTime.tryParse(formatted);
  }
  return null;
}

/// The keyword columns an op of [type] with [payload] writes
/// (SYNC-REDESIGN.md §3). A move, snooze or unsnooze counts here for its
/// `snoozed_until`; its folder is in [locationColumnsOf].
Set<KeywordColumn> keywordColumnsOf(
  String type,
  Map<String, dynamic>? payload,
) {
  switch (type) {
    case 'flag_seen':
      return payload?['seen'] is bool ? const {KeywordColumn.seen} : const {};
    case 'flag_flagged':
      return payload?['flagged'] is bool
          ? const {KeywordColumn.flagged}
          : const {};
    case 'snooze':
      return _snoozeUntil(payload) == null
          ? const {}
          : const {KeywordColumn.snoozedUntil};
    case 'unsnooze':
    case 'clear_snooze':
      return const {KeywordColumn.snoozedUntil};
    case 'move':
      return payload?['clearSnooze'] == true
          ? const {KeywordColumn.snoozedUntil}
          : const {};
  }
  return const {};
}

DateTime? _snoozeUntil(Map<String, dynamic>? payload) {
  final until = payload?['until'];
  return until is String ? DateTime.tryParse(until) : null;
}

/// Folds a row's [ops] into its `local_*` keyword columns: starts from
/// all-NULL and applies every foldable op ([foldableOpStates]) in `seq`
/// order, the later op winning per column.
KeywordLocal foldKeywords(Iterable<FoldOp> ops) {
  bool? seen;
  bool? flagged;
  DateTime? snoozedUntil;
  final sorted = [
    for (final op in ops)
      if (foldableOpStates.contains(op.state)) op,
  ]..sort((a, b) => a.seq.compareTo(b.seq));
  for (final op in sorted) {
    final payload = op.payload;
    switch (op.type) {
      case 'flag_seen':
        if (payload?['seen'] case final bool value) seen = value;
      case 'flag_flagged':
        if (payload?['flagged'] case final bool value) flagged = value;
      case 'snooze':
        if (_snoozeUntil(payload) case final until?) snoozedUntil = until;
      case 'unsnooze':
      case 'clear_snooze':
        snoozedUntil = snoozeCleared;
      case 'move':
        if (payload?['clearSnooze'] == true) snoozedUntil = snoozeCleared;
    }
  }
  return KeywordLocal(seen: seen, flagged: flagged, snoozedUntil: snoozedUntil);
}

/// Whether the server's [read] of a row agrees with the keyword part of
/// [op], an acked op (SYNC-REDESIGN.md §4.5). A snooze agrees when the
/// server has some snooze: the `snz:` keyword stores the time at second
/// precision and in UTC digits, so the exact instant need not round-trip;
/// once the op is dropped the row shows the server's time, as before the
/// overlay.
bool readAgreesWith(FoldOp op, ServerKeywords read) {
  final payload = op.payload;
  switch (op.type) {
    case 'flag_seen':
      return payload?['seen'] == read.seen;
    case 'flag_flagged':
      return payload?['flagged'] == read.flagged;
    case 'snooze':
      return read.snoozedUntil != null;
    case 'unsnooze':
    case 'clear_snooze':
    case 'move':
      return read.snoozedUntil == null;
  }
  return true;
}

// ── The `location` overlay (SYNC-REDESIGN.md §2, phase 4a) ─────────────────

/// The location columns of `emails` an op can write: `local_mailbox_path`
/// (a move, snooze or unsnooze) and `local_hidden` (a delete for good).
enum LocationColumn { mailboxPath, hidden }

/// The location columns an op of [type] with [payload] writes
/// (SYNC-REDESIGN.md §3).
Set<LocationColumn> locationColumnsOf(
  String type,
  Map<String, dynamic>? payload,
) {
  switch (type) {
    case 'move':
    case 'snooze':
    case 'unsnooze':
      return payload?['dest'] is String
          ? const {LocationColumn.mailboxPath}
          : const {};
    case 'delete':
      return const {LocationColumn.hidden};
  }
  return const {};
}

/// Every overlay column (keyword or location) an op writes: an op shadows
/// another only when it writes all of these.
Set<Object> overlayColumnsOf(String type, Map<String, dynamic>? payload) => {
      ...keywordColumnsOf(type, payload),
      ...locationColumnsOf(type, payload),
    };

/// The `local_*` location columns of a row: [mailboxPath] null means no
/// pending move; [hidden] a pending delete for good.
class LocationLocal {
  const LocationLocal({this.mailboxPath, this.hidden = false});

  static const none = LocationLocal();

  final String? mailboxPath;
  final bool hidden;

  bool get isEmpty => mailboxPath == null && !hidden;

  @override
  bool operator ==(Object other) =>
      other is LocationLocal &&
      other.mailboxPath == mailboxPath &&
      other.hidden == hidden;

  @override
  int get hashCode => Object.hash(mailboxPath, hidden);

  @override
  String toString() =>
      'LocationLocal(mailboxPath: $mailboxPath, hidden: $hidden)';
}

/// Folds a row's [ops] into its `local_*` location columns, like
/// [foldKeywords]: the destination of the latest foldable move, snooze or
/// unsnooze, and whether a delete for good is queued (a hidden row takes no
/// further user action, so nothing un-hides it).
LocationLocal foldLocation(Iterable<FoldOp> ops) {
  String? mailboxPath;
  var hidden = false;
  final sorted = [
    for (final op in ops)
      if (foldableOpStates.contains(op.state)) op,
  ]..sort((a, b) => a.seq.compareTo(b.seq));
  for (final op in sorted) {
    switch (op.type) {
      case 'move':
      case 'snooze':
      case 'unsnooze':
        if (op.payload?['dest'] case final String dest) mailboxPath = dest;
      case 'delete':
        hidden = true;
    }
  }
  return LocationLocal(mailboxPath: mailboxPath, hidden: hidden);
}

/// The effective `mailbox_path` of a row (SYNC-REDESIGN.md §2): empty when
/// hidden (a pending delete, or gone on the server with no pending move),
/// else the pending move's destination, else the server's folder.
String effectiveMailboxPath({
  required String? localMailboxPath,
  required bool localHidden,
  required String srvMailboxPath,
  required bool srvGone,
}) {
  if (localHidden) return '';
  if (srvGone && localMailboxPath == null) return '';
  return localMailboxPath ?? srvMailboxPath;
}

/// Payload key of a counterpart's shadow `delete` that only hides the twin
/// row until its account sees the mail leave this folder: the primary
/// moved the mail into a folder the counterpart does not know yet
/// (SYNC-REDESIGN.md §6).
const awayFromKey = 'awayFrom';

/// Whether what sync last recorded about a row's location agrees with the
/// location part of [op], an acked op: a move, snooze or unsnooze when the
/// server has the mail in its destination, a delete when the server no
/// longer has it (a hiding shadow delete, [awayFromKey]: no longer in that
/// folder).
bool locationAgreesWith(
  FoldOp op, {
  required String? srvMailboxPath,
  required bool srvGone,
}) {
  switch (op.type) {
    case 'move':
    case 'snooze':
    case 'unsnooze':
      return !srvGone && srvMailboxPath == op.payload?['dest'];
    case 'delete':
      final awayFrom = op.payload?[awayFromKey];
      if (awayFrom is String) return srvGone || srvMailboxPath != awayFrom;
      return srvGone;
  }
  return true;
}
