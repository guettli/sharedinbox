import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/conversation_tree.dart';

Email _email({
  required String id,
  required String messageId,
  String? inReplyTo,
  String? references,
  String mailboxPath = 'INBOX',
  DateTime? sentAt,
}) =>
    Email(
      id: id,
      accountId: 'acc-1',
      mailboxPath: mailboxPath,
      uid: int.parse(id),
      receivedAt: sentAt ?? DateTime(2024, 1, int.parse(id)),
      sentAt: sentAt ?? DateTime(2024, 1, int.parse(id)),
      from: const [],
      to: const [],
      cc: const [],
      isSeen: false,
      isFlagged: false,
      hasAttachment: false,
      messageId: messageId,
      inReplyTo: inReplyTo,
      references: references,
    );

/// Flattens the tree (pre-order) into `id@depth` strings for easy assertions.
List<String> _flat(List<ConversationNode> nodes) {
  final out = <String>[];
  void visit(List<ConversationNode> level) {
    for (final n in level) {
      out.add('${n.email.id}@${n.depth}');
      visit(n.children);
    }
  }

  visit(nodes);
  return out;
}

void main() {
  group('buildConversationTree', () {
    test('linear chain across folders nests by In-Reply-To', () {
      final tree = buildConversationTree([
        _email(id: '1', messageId: 'a'),
        _email(id: '2', messageId: 'b', inReplyTo: 'a', mailboxPath: 'Sent'),
        _email(id: '3', messageId: 'c', inReplyTo: 'b', mailboxPath: 'Archive'),
      ]);

      expect(_flat(tree), ['1@0', '2@1', '3@2']);
    });

    test('resolves parent from References when In-Reply-To is absent', () {
      final tree = buildConversationTree([
        _email(id: '1', messageId: 'a'),
        // References lists root first, immediate parent (b) last.
        _email(id: '2', messageId: 'b', inReplyTo: 'a'),
        _email(id: '3', messageId: 'c', references: 'a b'),
      ]);

      // 3 attaches to its nearest present ancestor (b = id 2), not the root.
      expect(_flat(tree), ['1@0', '2@1', '3@2']);
    });

    test('missing root: reply whose parent is absent becomes a root', () {
      final tree = buildConversationTree([
        _email(id: '2', messageId: 'b', inReplyTo: 'missing'),
        _email(id: '3', messageId: 'c', inReplyTo: 'b'),
      ]);

      expect(_flat(tree), ['2@0', '3@1']);
    });

    test('sibling replies are ordered oldest first', () {
      final tree = buildConversationTree([
        _email(id: '1', messageId: 'a', sentAt: DateTime(2024)),
        _email(
          id: '3',
          messageId: 'c',
          inReplyTo: 'a',
          sentAt: DateTime(2024, 1, 3),
        ),
        _email(
          id: '2',
          messageId: 'b',
          inReplyTo: 'a',
          sentAt: DateTime(2024, 1, 2),
        ),
      ]);

      expect(_flat(tree), ['1@0', '2@1', '3@1']);
    });

    test('an In-Reply-To cycle terminates and keeps every message', () {
      // A <-> B reference each other; neither is a natural root.
      final tree = buildConversationTree([
        _email(id: '1', messageId: 'a', inReplyTo: 'b'),
        _email(id: '2', messageId: 'b', inReplyTo: 'a'),
      ]);

      final flat = _flat(tree);
      expect(flat, hasLength(2));
      expect(
        flat.map((s) => s.split('@').first).toSet(),
        {'1', '2'},
      );
    });

    test('handles bracketed message ids from IMAP', () {
      final tree = buildConversationTree([
        _email(id: '1', messageId: '<a@host>'),
        _email(id: '2', messageId: '<b@host>', inReplyTo: '<a@host>'),
      ]);

      expect(_flat(tree), ['1@0', '2@1']);
    });

    test('empty input yields an empty forest', () {
      expect(buildConversationTree(const []), isEmpty);
    });
  });
}
