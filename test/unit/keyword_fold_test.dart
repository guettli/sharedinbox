// The pure part of the `keywords` overlay (SYNC-REDESIGN.md §2–§4): which
// op writes which `local_*` column, the fold, and when a read agrees with an
// acked op.

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/keyword_fold.dart';

FoldOp _op(
  int seq,
  String type, [
  Map<String, dynamic>? payload,
  String state = 'pending',
]) =>
    FoldOp(seq: seq, type: type, payload: payload ?? const {}, state: state);

final _until = DateTime.utc(2026, 12, 1, 8);

void main() {
  group('foldKeywords', () {
    test('no ops: no intent', () {
      expect(foldKeywords(const []), KeywordLocal.none);
      expect(foldKeywords(const []).isEmpty, isTrue);
    });

    test('each op type writes its own column', () {
      expect(
        foldKeywords([
          _op(1, 'flag_seen', {'seen': true}),
        ]),
        const KeywordLocal(seen: true),
      );
      expect(
        foldKeywords([
          _op(1, 'flag_flagged', {'flagged': false}),
        ]),
        const KeywordLocal(flagged: false),
      );
      expect(
        foldKeywords([
          _op(1, 'snooze', {'until': _until.toIso8601String()}),
        ]).snoozedUntil,
        _until,
      );
      for (final type in ['unsnooze', 'clear_snooze']) {
        expect(
          isSnoozeCleared(foldKeywords([_op(1, type)]).snoozedUntil),
          isTrue,
          reason: type,
        );
      }
      expect(
        isSnoozeCleared(
          foldKeywords([
            _op(1, 'move', {'dest': 'Archive', 'clearSnooze': true}),
          ]).snoozedUntil,
        ),
        isTrue,
      );
    });

    test('ops without a keyword column write nothing', () {
      expect(
        foldKeywords([
          _op(1, 'move', {'dest': 'Archive'}),
          _op(2, 'delete'),
          _op(3, 'add_keywords', {
            'keywords': ['x'],
          }),
        ]),
        KeywordLocal.none,
      );
    });

    test('ops apply in seq order, the later winning per column', () {
      final local = foldKeywords([
        // Out of order on purpose.
        _op(3, 'flag_seen', {'seen': false}),
        _op(1, 'flag_seen', {'seen': true}),
        _op(2, 'flag_flagged', {'flagged': true}),
        _op(5, 'unsnooze'),
        _op(4, 'snooze', {'until': _until.toIso8601String()}),
      ]);
      expect(local.seen, isFalse);
      expect(local.flagged, isTrue);
      expect(isSnoozeCleared(local.snoozedUntil), isTrue);
    });

    test('pending, inflight, stuck and acked ops fold; failed ones do not', () {
      for (final state in ['pending', 'inflight', 'stuck', 'acked']) {
        expect(
          foldKeywords([
            _op(1, 'flag_seen', {'seen': true}, state),
          ]).seen,
          isTrue,
          reason: state,
        );
      }
      expect(
        foldKeywords([
          _op(1, 'flag_seen', {'seen': true}, 'failed'),
        ]),
        KeywordLocal.none,
      );
      // A failed later op leaves the earlier one's value.
      expect(
        foldKeywords([
          _op(1, 'flag_seen', {'seen': true}),
          _op(2, 'flag_seen', {'seen': false}, 'failed'),
        ]).seen,
        isTrue,
      );
    });

    test('an unreadable payload writes nothing', () {
      expect(
        foldKeywords([
          const FoldOp(
            seq: 1,
            type: 'flag_seen',
            payload: null,
            state: 'pending',
          ),
          _op(2, 'snooze', {'until': 'not a date'}),
        ]),
        KeywordLocal.none,
      );
    });
  });

  group('keywordColumnsOf', () {
    test('names the columns an op writes', () {
      expect(keywordColumnsOf('flag_seen', {'seen': true}), {
        KeywordColumn.seen,
      });
      expect(keywordColumnsOf('flag_flagged', {'flagged': true}), {
        KeywordColumn.flagged,
      });
      expect(
        keywordColumnsOf('snooze', {'until': _until.toIso8601String()}),
        {KeywordColumn.snoozedUntil},
      );
      expect(keywordColumnsOf('unsnooze', {}), {KeywordColumn.snoozedUntil});
      expect(keywordColumnsOf('clear_snooze', {}), {
        KeywordColumn.snoozedUntil,
      });
      expect(keywordColumnsOf('move', {'clearSnooze': true}), {
        KeywordColumn.snoozedUntil,
      });
      expect(keywordColumnsOf('move', {'dest': 'Archive'}), isEmpty);
      expect(keywordColumnsOf('delete', {}), isEmpty);
      expect(keywordColumnsOf('add_keywords', {}), isEmpty);
    });
  });

  group('readAgreesWith', () {
    const unread =
        ServerKeywords(seen: false, flagged: false, snoozedUntil: null);
    final snoozed =
        ServerKeywords(seen: false, flagged: false, snoozedUntil: _until);

    test('a flag op agrees when the server has its value', () {
      expect(
        readAgreesWith(_op(1, 'flag_seen', {'seen': false}), unread),
        isTrue,
      );
      expect(
        readAgreesWith(_op(1, 'flag_seen', {'seen': true}), unread),
        isFalse,
      );
      expect(
        readAgreesWith(_op(1, 'flag_flagged', {'flagged': true}), unread),
        isFalse,
      );
    });

    test('a snooze agrees with any snooze, an unsnooze with none', () {
      final snooze = _op(1, 'snooze', {
        'until': _until.add(const Duration(hours: 1)).toIso8601String(),
      });
      expect(readAgreesWith(snooze, snoozed), isTrue);
      expect(readAgreesWith(snooze, unread), isFalse);
      expect(readAgreesWith(_op(1, 'unsnooze'), unread), isTrue);
      expect(readAgreesWith(_op(1, 'unsnooze'), snoozed), isFalse);
      expect(
        readAgreesWith(_op(1, 'move', {'clearSnooze': true}), snoozed),
        isFalse,
      );
    });
  });

  group('ServerKeywords', () {
    test('reads IMAP flags and the snz: keyword', () {
      final k = ServerKeywords.imap([r'\Seen', 'snz:20261201T080000Z']);
      expect(k.seen, isTrue);
      expect(k.flagged, isFalse);
      expect(k.snoozedUntil, _until);
      expect(ServerKeywords.imap(null).seen, isFalse);
    });

    test('reads JMAP keywords', () {
      final k = ServerKeywords.jmap({r'$flagged': true});
      expect(k.seen, isFalse);
      expect(k.flagged, isTrue);
      expect(k.snoozedUntil, isNull);
    });
  });
}
