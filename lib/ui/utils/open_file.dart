import 'package:open_filex/open_filex.dart';

typedef FileOpener = Future<OpenResult> Function(String path);

Future<OpenResult> _openFilex(String path) => OpenFilex.open(path);

/// Hands [path] to another app. Returns null when that worked, otherwise a
/// sentence for the user saying why not.
///
/// OpenFilex does not throw when it cannot open a file; it reports that in
/// its result. Callers that only caught exceptions therefore did nothing at
/// all when, say, no PDF viewer was installed: the tap seemed to be ignored.
Future<String?> openFile(String path, {FileOpener opener = _openFilex}) async {
  final result = await opener(path);
  return switch (result.type) {
    ResultType.done => null,
    ResultType.noAppToOpen => 'No app on this device can open this file.',
    ResultType.fileNotFound => 'The file to open is missing.',
    ResultType.permissionDenied => 'Not allowed to open the file.',
    ResultType.error => 'Could not open the file: ${result.message}',
  };
}
