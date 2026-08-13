import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/storage/db_open_result.dart';

void main() {
  group('classifyDbOpenFailure', () {
    test(
      'marker present but no SQLCipher in the build → buildMissingCipher',
      () {
        // Doubles as the regression test that the `source: sqlcipher` hook is
        // in effect: if it were not, cipherAvailable would be false in
        // production and this branch would fire on an encrypted DB.
        expect(
          classifyDbOpenFailure(
            markerPresent: true,
            hasKey: true,
            cipherAvailable: false,
            sqliteResultCode: sqliteNotADb,
          ),
          DbUnreadableReason.buildMissingCipher,
        );
      },
    );

    test('marker present, cipher available, no stored key → keyMissing', () {
      expect(
        classifyDbOpenFailure(
          markerPresent: true,
          hasKey: false,
          cipherAvailable: true,
          sqliteResultCode: sqliteNotADb,
        ),
        DbUnreadableReason.keyMissing,
      );
    });

    test('key present, open fails SQLITE_NOTADB → wrongKeyOrFormat', () {
      expect(
        classifyDbOpenFailure(
          markerPresent: true,
          hasKey: true,
          cipherAvailable: true,
          sqliteResultCode: sqliteNotADb,
        ),
        DbUnreadableReason.wrongKeyOrFormat,
      );
    });

    test('any other sqlite error → corrupt', () {
      expect(
        classifyDbOpenFailure(
          markerPresent: false,
          hasKey: false,
          cipherAvailable: true,
          sqliteResultCode: 11, // SQLITE_CORRUPT
        ),
        DbUnreadableReason.corrupt,
      );
    });

    test('plaintext DB with no sqlite code → corrupt', () {
      expect(
        classifyDbOpenFailure(
          markerPresent: false,
          hasKey: false,
          cipherAvailable: true,
          sqliteResultCode: null,
        ),
        DbUnreadableReason.corrupt,
      );
    });
  });

  group('DbProbeResult', () {
    test('ok result offers no destructive action', () {
      const result = DbProbeResult.ok();
      expect(result.ok, isTrue);
      expect(result.allowsDelete, isFalse);
    });

    test('build-bug result forbids deletion — the data is intact', () {
      const result = DbProbeResult.unreadable(
        DbUnreadableReason.buildMissingCipher,
        'boom',
      );
      expect(result.ok, isFalse);
      expect(result.allowsDelete, isFalse);
    });

    test('recoverable failures allow deletion', () {
      for (final reason in [
        DbUnreadableReason.keyMissing,
        DbUnreadableReason.wrongKeyOrFormat,
        DbUnreadableReason.corrupt,
      ]) {
        expect(
          DbProbeResult.unreadable(reason, 'boom').allowsDelete,
          isTrue,
          reason: '$reason should allow deletion',
        );
      }
    });
  });
}
