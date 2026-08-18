import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/ui/screens/sync_log_screen.dart';

SyncLogEntry _entry({String? protocolLog}) => SyncLogEntry(
      id: 1,
      result: 'error',
      errorMessage: 'BAD Could not parse command',
      protocol: 'imap',
      emailsFetched: 0,
      emailsSkipped: 0,
      mailboxesSynced: 0,
      pendingFlushed: 0,
      bytesTransferred: 0,
      startedAt: DateTime(2026, 8, 18, 14, 16, 45),
      finishedAt: DateTime(2026, 8, 18, 14, 17, 6),
      protocolLog: protocolLog,
    );

void main() {
  // Issue #608: the copied sync entry must include the protocol trace so the
  // failing command travels with the bug report, not just the on-screen view.
  test('markdown includes the protocol log section when present', () {
    final md = buildSyncEntryMarkdown(
      _entry(protocolLog: 'C: 99 SOMEBROKENCOMMAND\nS: 99 BAD Could not parse'),
    );

    expect(md, contains('**Protocol log:**'));
    expect(md, contains('SOMEBROKENCOMMAND'));
  });

  test('markdown omits the protocol log section when absent', () {
    final md = buildSyncEntryMarkdown(_entry());

    expect(md, isNot(contains('Protocol log')));
  });
}
