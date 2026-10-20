import 'package:open_filex/open_filex.dart';

typedef FileOpener = Future<OpenResult> Function(String path);

Future<OpenResult> _openFilex(String path) => OpenFilex.open(path);

/// Why a file could not be opened: [text] for the user, [detail] (the
/// plugin's result type and message, or the exception) for the app log.
typedef OpenFileProblem = ({String text, String detail});

/// Hands [path] to another app. Returns null when that worked, otherwise
/// what went wrong.
///
/// OpenFilex does not throw when it cannot open a file; it reports that in
/// its result. Callers that only caught exceptions therefore did nothing at
/// all when, say, no PDF viewer was installed: the tap seemed to be ignored.
/// The plugin's own message names temp paths or raw exceptions, so it only
/// goes into [OpenFileProblem.detail].
Future<OpenFileProblem?> openFile(
  String path, {
  FileOpener opener = _openFilex,
}) async {
  final OpenResult result;
  try {
    result = await opener(path);
  } catch (e) {
    return (text: 'Could not open the file.', detail: e.toString());
  }
  final detail = '${result.type.name}: ${result.message}';
  return switch (result.type) {
    ResultType.done => null,
    ResultType.noAppToOpen => (
        text: 'No app on this device can open this file.',
        detail: detail,
      ),
    ResultType.fileNotFound => (
        text: 'The file to open is missing.',
        detail: detail,
      ),
    ResultType.permissionDenied => (
        text: "This app isn't allowed to open the file.",
        detail: detail,
      ),
    ResultType.error => (text: 'Could not open the file.', detail: detail),
  };
}
