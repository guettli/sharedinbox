// Regression test for #644:
// Opening a message detail auto-marks it as read via
// EmailDetailNotifier.build → repo.setFlag(id, seen: true). It used to fire
// on *every* open, so re-opening an already-read message re-enqueued a
// flag_seen change (re-STORE on the server) and re-logged "Marked … read".
// The fix only marks read on the false→true transition — this test asserts an
// already-read message is not re-flagged while an unread one still is.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('opening an unread message marks it read exactly once', () async {
    // testEmail defaults to isSeen: false (unread).
    final repo = FakeEmailRepository(emails: [testEmail()]);
    final container = makeContainer(repo);

    await container.read(emailDetailProvider('acc-1:42').future);
    await Future<void>.delayed(Duration.zero);

    expect(repo.setFlagCalls, hasLength(1));
    expect(repo.setFlagCalls.single.emailId, 'acc-1:42');
    expect(repo.setFlagCalls.single.seen, isTrue);
  });

  test('opening an already-read message does not re-mark it (#644)', () async {
    final repo = FakeEmailRepository(emails: [testEmail(isSeen: true)]);
    final container = makeContainer(repo);

    await container.read(emailDetailProvider('acc-1:42').future);
    await Future<void>.delayed(Duration.zero);

    expect(repo.setFlagCalls, isEmpty);
  });
}
