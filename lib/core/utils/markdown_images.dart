/// Images in an entry body (ENCRYPTED-OBJECTS.md §6): `![alt](si-img:<id>)`,
/// where `<id>` is the itemId of a blob of the same collection.
library;

/// The URI scheme of an image stored as an encrypted blob.
const siImgScheme = 'si-img';

/// The Markdown line that shows blob [itemId].
String siImageMarkdown(String itemId) => '![]($siImgScheme:$itemId)';

/// The blob itemId [uri] points at, or null when it is no `si-img:` URI with
/// a plain id.
String? siImageId(Uri uri) {
  if (uri.scheme != siImgScheme) return null;
  if (uri.hasQuery || uri.hasFragment) return null;
  final id = uri.path;
  if (!_id.hasMatch(id)) return null;
  return id;
}

/// The blob itemIds of the `si-img:` images in [body], in order, each once.
List<String> siImageIds(String body) => [
      ...{for (final m in siImagePattern.allMatches(body)) m.group(2)!},
    ];

/// An image whose target is `si-img:<id>`: group 1 is `![alt](`, group 2 the
/// id.
final siImagePattern = RegExp(r'(!\[[^\]]*\]\(\s*<?)si-img:([A-Za-z0-9_-]+)');

final _id = RegExp(r'^[A-Za-z0-9_-]+$');

/// [text] with the image line of [itemId] inserted at [offset] on a line of
/// its own (appended when [offset] is outside [text]), and the offset just
/// after it.
(String, int) insertSiImage(String text, int offset, String itemId) {
  final at = offset < 0 || offset > text.length ? text.length : offset;
  final before = text.substring(0, at);
  final after = text.substring(at);
  final lead = before.isEmpty || before.endsWith('\n') ? '' : '\n';
  final trail = after.startsWith('\n') ? '' : '\n';
  final inserted = '$lead${siImageMarkdown(itemId)}$trail';
  return ('$before$inserted$after', at + inserted.length);
}
