import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/ui/widgets/thread_tile.dart';

EmailThread _thread({bool hasAttachment = false, DateTime? latestDate}) =>
    EmailThread(
      threadId: 't1',
      subject: 'Contract',
      participants: const [EmailAddress(name: 'Alice', email: 'a@x.test')],
      latestDate: latestDate ?? DateTime(2024, 6, 1, 9, 30),
      messageCount: 1,
      hasUnread: false,
      isFlagged: false,
      hasAttachment: hasAttachment,
      latestEmailId: 'e1',
      emailIds: const ['e1'],
      accountId: 'acc-1',
      mailboxPath: 'INBOX',
    );

Future<void> _pump(WidgetTester tester, EmailThread thread) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ThreadTile(thread: thread, onTap: () {})),
      ),
    );

void main() {
  group('formatThreadDate', () {
    final now = DateTime(2026, 10, 18, 15);

    test('shows the time for a message from today', () {
      expect(formatThreadDate(DateTime(2026, 10, 18, 9, 5), now: now), '09:05');
    });

    test('shows month and day for an earlier day this year', () {
      expect(formatThreadDate(DateTime(2026, 10, 17, 23), now: now), 'Oct 17');
      expect(formatThreadDate(DateTime(2026, 1, 2), now: now), 'Jan 2');
    });

    test('adds the year for a message from a previous year', () {
      expect(
        formatThreadDate(DateTime(2025, 10, 18), now: now),
        'Oct 18, 2025',
      );
    });

    test('a cached day is re-formatted once "today" moves on', () {
      expect(formatThreadDate(DateTime(2026, 10, 18, 9, 5), now: now), '09:05');
      final tomorrow = DateTime(2026, 10, 19, 8);
      expect(
        formatThreadDate(DateTime(2026, 10, 18, 9, 5), now: tomorrow),
        'Oct 18',
      );
    });
  });

  group('ThreadTile', () {
    testWidgets('shows a paperclip when the thread has an attachment', (
      tester,
    ) async {
      await _pump(tester, _thread(hasAttachment: true));
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
    });

    testWidgets('shows no paperclip without attachments', (tester) async {
      await _pump(tester, _thread());
      expect(find.byIcon(Icons.attach_file), findsNothing);
    });
  });
}
