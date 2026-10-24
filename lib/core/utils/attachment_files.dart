import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'package:sharedinbox/core/models/draft.dart';

/// The MIME type to send a file named [filename] as.
String guessAttachmentType(String filename) =>
    lookupMimeType(filename) ?? 'application/octet-stream';

/// Describes the file at [path] as an attachment named [filename] (default:
/// its base name). A file that does not exist gets size 0; whoever shows
/// the attachment reports it as missing.
Future<DraftAttachment> describeAttachmentFile(
  String path, {
  String? filename,
}) async {
  final name = filename ?? p.basename(path);
  var size = 0;
  try {
    final stat = await File(path).stat();
    if (stat.type != FileSystemEntityType.notFound) size = stat.size;
  } catch (_) {
    // Unreadable: reported as missing where it is shown.
  }
  return DraftAttachment(
    path: path,
    filename: name,
    contentType: guessAttachmentType(name),
    size: size,
  );
}
