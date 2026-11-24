/// Images in entry Markdown (#1377): a blob of the same collection is
/// referenced as `![](si-img:<itemId>)` (`ENCRYPTED-OBJECTS.md` §6).
library;

const siImgScheme = 'si-img';

/// The Markdown line that shows blob [itemId].
String siImageMarkdown(String itemId) => '![]($siImgScheme:$itemId)';

/// The blob itemId [uri] refers to, null unless it is a `si-img:` URI with
/// a plain id.
String? siImageId(Uri uri) {
  if (uri.scheme != siImgScheme) return null;
  if (uri.hasQuery || uri.hasFragment) return null;
  final id = uri.path;
  if (id.isEmpty || id.contains(RegExp('[/?#]'))) return null;
  return id;
}

final _imageRef = RegExp(r'!\[[^\]]*\]\(\s*<?([^)\s>]+)>?[^)]*\)');

/// The blob itemIds [body] refers to, in order, each once.
List<String> siImageIds(String body) {
  final ids = <String>{};
  for (final m in _imageRef.allMatches(body)) {
    final uri = Uri.tryParse(m.group(1)!);
    final id = uri == null ? null : siImageId(uri);
    if (id != null) ids.add(id);
  }
  return ids.toList();
}

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
