import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/ui/widgets/email_thread_list.dart';

EmailThread _t(String id, {String accountId = 'acc-1'}) => EmailThread(
      threadId: id,
      subject: id,
      participants: const [],
      latestDate: DateTime(2024, 6),
      messageCount: 1,
      hasUnread: false,
      isFlagged: false,
      latestEmailId: id,
      emailIds: [id],
      accountId: accountId,
      mailboxPath: 'INBOX',
    );

void main() {
  group('EmailThreadListController', () {
    test('toggle adds then removes a thread id and fires notifications', () {
      final ctrl = EmailThreadListController()
        ..updateThreads([_t('a'), _t('b')]);
      var notifications = 0;
      ctrl.addListener(() => notifications++);

      expect(ctrl.isSelecting, isFalse);

      ctrl.toggle(_t('a'));
      expect(ctrl.isSelecting, isTrue);
      expect(ctrl.selectionCount, 1);
      expect(ctrl.isSelected(_t('a')), isTrue);
      expect(notifications, 1);

      ctrl.toggle(_t('a'));
      expect(ctrl.isSelecting, isFalse);
      expect(ctrl.selectionCount, 0);
      expect(notifications, 2);
    });

    test('selectAll selects every visible thread', () {
      final ctrl = EmailThreadListController()
        ..updateThreads([_t('a'), _t('b'), _t('c')]);
      ctrl.selectAll();
      expect(ctrl.selectionCount, 3);
      expect(ctrl.selectedIds, {'a', 'b', 'c'});
    });

    test('clear empties the selection and notifies once', () {
      final ctrl = EmailThreadListController()
        ..updateThreads([_t('a'), _t('b')])
        ..toggle(_t('a'))
        ..toggle(_t('b'));
      var notifications = 0;
      ctrl.addListener(() => notifications++);

      ctrl.clear();
      expect(ctrl.isSelecting, isFalse);
      expect(notifications, 1);

      // Clearing an already-empty selection does not notify again.
      ctrl.clear();
      expect(notifications, 1);
    });

    test('updateThreads drops selections that are no longer visible', () {
      final ctrl = EmailThreadListController()
        ..updateThreads([_t('a'), _t('b'), _t('c')])
        ..toggle(_t('a'))
        ..toggle(_t('c'));
      expect(ctrl.selectionCount, 2);

      ctrl.updateThreads([_t('a'), _t('b')]);
      // 'c' is no longer visible, so it gets dropped.
      expect(ctrl.selectionCount, 1);
      expect(ctrl.selectedIds, {'a'});
    });

    test('selectedThreads preserves the visible-list order', () {
      final a = _t('a');
      final b = _t('b');
      final c = _t('c');
      final ctrl = EmailThreadListController()
        ..updateThreads([a, b, c])
        ..toggle(c)
        ..toggle(a);
      // Selection order is insertion (c, a), but selectedThreads must follow
      // the visible-list order (a, c).
      expect(ctrl.selectedThreads.map((t) => t.threadId), ['a', 'c']);
    });

    test('multi-account threads are kept independent in the selection', () {
      final ctrl = EmailThreadListController()
        ..updateThreads([
          _t('a', accountId: 'acc-1'),
          _t('b', accountId: 'acc-2'),
        ]);
      ctrl.selectAll();
      final byAccount = <String, int>{};
      for (final t in ctrl.selectedThreads) {
        byAccount[t.accountId] = (byAccount[t.accountId] ?? 0) + 1;
      }
      expect(byAccount, {'acc-1': 1, 'acc-2': 1});
    });
  });
}
