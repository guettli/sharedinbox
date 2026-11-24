/// Images in an entry body (ENCRYPTED-OBJECTS.md §6): `![alt](si-img:<id>)`,
/// where `<id>` is the itemId of a blob of the same collection.
library;

/// The URI scheme of an image stored as an encrypted blob.
const siImgScheme = 'si-img';

/// The blob itemId [uri] points at, or null when it is no `si-img:` URI.
String? siImageId(Uri uri) {
  if (uri.scheme != siImgScheme) return null;
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
