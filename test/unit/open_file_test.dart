import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart';
import 'package:sharedinbox/ui/utils/open_file.dart';

void main() {
  Future<String?> openWith(ResultType type, [String message = '']) => openFile(
        '/tmp/invoice.pdf',
        opener: (_) async => OpenResult(type: type, message: message),
      );

  test('says nothing when the file was opened', () async {
    expect(await openWith(ResultType.done), isNull);
  });

  test('says so when no app can open the file', () async {
    // OpenFilex reports this in its result, without throwing, so the tap on
    // an attachment used to do nothing at all.
    expect(
      await openWith(ResultType.noAppToOpen),
      'No app on this device can open this file.',
    );
  });

  test('passes the reason on for other errors', () async {
    expect(
      await openWith(ResultType.error, 'xdg-open not found'),
      'Could not open the file: xdg-open not found',
    );
  });
}
