import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart';
import 'package:sharedinbox/ui/utils/open_file.dart';

void main() {
  Future<OpenFileProblem?> openWith(ResultType type, [String message = '']) =>
      openFile(
        '/tmp/invoice.pdf',
        opener: (_) async => OpenResult(type: type, message: message),
      );

  test('says nothing when the file was opened', () async {
    expect(await openWith(ResultType.done), isNull);
  });

  test('says so when no app can open the file', () async {
    // OpenFilex reports this in its result, without throwing, so the tap on
    // an attachment used to do nothing at all.
    final problem = await openWith(ResultType.noAppToOpen, 'No APP found');
    expect(problem?.text, 'No app on this device can open this file.');
    expect(problem?.detail, 'noAppToOpen: No APP found');
  });

  test('keeps the plugin message out of the user text', () async {
    final problem = await openWith(
      ResultType.error,
      'there are some errors when open /tmp/sharedinbox/attachments/x.pdf',
    );
    expect(problem?.text, 'Could not open the file.');
    expect(problem?.detail, contains('/tmp/sharedinbox/attachments/x.pdf'));
  });

  test('names a missing file and a refused permission', () async {
    expect(
      (await openWith(ResultType.fileNotFound))?.text,
      'The file to open is missing.',
    );
    expect(
      (await openWith(ResultType.permissionDenied))?.text,
      "This app isn't allowed to open the file.",
    );
  });

  test('turns an exception from the plugin into a problem', () async {
    final problem = await openFile(
      '/tmp/invoice.pdf',
      opener: (_) => throw StateError('channel gone'),
    );
    expect(problem?.text, 'Could not open the file.');
    expect(problem?.detail, contains('channel gone'));
  });
}
