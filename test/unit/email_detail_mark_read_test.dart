// Regression test for #644:
// Opening a message detail auto-marks it as read via
// EmailDetailNotifier.build → repo.setFlag(id, seen: true). It used to fire
// on *every* open, so re-opening an already-read message re-enqueued a
// flag_seen change (re-STORE on the server) and re-logged "Marked … read".
// The fix only marks read on the false→true transition — this test asserts an
// already-read message is not re-flagged while an unread one still is.
//
// #1347: the mark-read lands once the load finishes, so neither a "Mark as
// unread" tapped meanwhile nor leaving the screen may be overridden by it.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/di.dart';

import '../widget/helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer(FakeEmailRepository repo) {
    final container = ProviderContainer(
      overrides: [
        emailRepositoryProvider.overrideWithValue(repo),
        userPreferencesRepositoryProvider.overrideWithValue(
          FakeUserPreferencesRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  // Keeps the detail provider alive, as the open screen does.
  ProviderSubscription<Object?> openScreen(ProviderContainer container) =>
      container.listen(emailDetailProvider('acc-1:42'), (_, __) {});

  test('Mark as unread during the load wins over the mark-read (#1347)',
      () async {
    final repo = _GatedBodyRepository();
    final container = makeContainer(repo);
    openScreen(container);
    await pumpEventQueue();

    await container.read(emailDetailProvider('acc-1:42').notifier).markUnread();
    repo.body.complete(const EmailBody(emailId: 'acc-1:42', attachments: []));
    await container.read(emailDetailProvider('acc-1:42').future);
    await pumpEventQueue();

    expect(repo.setFlagCalls.map((c) => c.seen), [false]);
  });

  test('leaving the screen during the load does not mark read (#1347)',
      () async {
    final repo = _GatedBodyRepository();
    final container = makeContainer(repo);
    final screen = openScreen(container);
    await pumpEventQueue();

    screen.close();
    await pumpEventQueue();
    repo.body.complete(const EmailBody(emailId: 'acc-1:42', attachments: []));
    await pumpEventQueue();

    expect(repo.setFlagCalls, isEmpty);
  });

  test('opening an unread message marks it read exactly once', () async {
    // testEmail defaults to isSeen: false (unread).
    final repo = FakeEmailRepository(emails: [testEmail()]);
    final container = makeContainer(repo);
    openScreen(container);

    await container.read(emailDetailProvider('acc-1:42').future);
    await Future<void>.delayed(Duration.zero);

    expect(repo.setFlagCalls, hasLength(1));
    expect(repo.setFlagCalls.single.emailId, 'acc-1:42');
    expect(repo.setFlagCalls.single.seen, isTrue);
  });

  test('opening an already-read message does not re-mark it (#644)', () async {
    final repo = FakeEmailRepository(emails: [testEmail(isSeen: true)]);
    final container = makeContainer(repo);
    openScreen(container);

    await container.read(emailDetailProvider('acc-1:42').future);
    await Future<void>.delayed(Duration.zero);

    expect(repo.setFlagCalls, isEmpty);
  });
}

/// An unread mail whose body load only completes with [body].
class _GatedBodyRepository extends FakeEmailRepository {
  _GatedBodyRepository() : super(emails: [testEmail()]);

  final body = Completer<EmailBody>();

  @override
  Future<EmailBody> getEmailBody(String emailId, {bool forceRefresh = false}) =>
      body.future;
}
