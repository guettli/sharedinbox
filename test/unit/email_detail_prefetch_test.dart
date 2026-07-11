// Regression test for #232:
// EmailDetailNotifier._prefetchNextEmailBody called `getEmailBody(nextId)` on
// an unawaited future. enough_mail's QuotedPrintable decoder crashes with a
// RangeError on malformed bodies (substring OOB at
// quoted_printable_mail_codec.dart:199); the unhandled asynchronous error
// escaped to runZonedGuarded → FlutterError.onError → CrashScreen, tearing
// down the whole app while the user was still reading the current message.
//
// The fix wraps the body of _prefetchNextEmailBody in try/catch so background
// prefetch failures are logged and swallowed. This test drives the notifier
// through a repo that throws a RangeError for the *next* email and asserts
// that (a) the current email still loads and (b) nothing reaches
// FlutterError.onError.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/di.dart';

import '../widget/helpers.dart';

class _PrefetchThrowingRepo extends FakeEmailRepository {
  _PrefetchThrowingRepo({
    required List<Email> emails,
    required this.throwingId,
  }) : super(emails: emails);

  final String throwingId;

  @override
  Future<EmailBody> getEmailBody(
    String emailId, {
    bool forceRefresh = false,
  }) async {
    if (emailId == throwingId) {
      // Mirrors the exact error shape reported in #232 from
      // QuotedPrintableMailCodec.decodeText → String.substring.
      throw RangeError.range(46550, 0, 46548, 'end');
    }
    return EmailBody(emailId: emailId, attachments: const []);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'prefetch RangeError does not escape emailDetailProvider (#232)',
    () async {
      final current = testEmail(subject: 'Current');
      final next = testEmail(id: 'acc-1:43', subject: 'Next');
      final repo = _PrefetchThrowingRepo(
        emails: [current, next],
        throwingId: 'acc-1:43',
      );

      final capturedErrors = <Object>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        capturedErrors.add(details.exception);
      };
      addTearDown(() {
        FlutterError.onError = previousOnError;
      });

      final container = ProviderContainer(
        overrides: [
          emailRepositoryProvider.overrideWithValue(repo),
          userPreferencesRepositoryProvider.overrideWithValue(
            FakeUserPreferencesRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final result =
          await container.read(emailDetailProvider('acc-1:42').future);
      expect(result.$1?.id, 'acc-1:42');
      expect(result.$2.emailId, 'acc-1:42');

      // Drain microtasks so the unawaited _prefetchNextEmailBody future runs
      // to completion. Without the try/catch inside _prefetchNextEmailBody the
      // RangeError from getEmailBody('acc-1:43') would surface here.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        capturedErrors,
        isEmpty,
        reason:
            'prefetch RangeError must be swallowed by _prefetchNextEmailBody',
      );
    },
  );
}
