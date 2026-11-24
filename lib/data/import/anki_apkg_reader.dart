import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sharedinbox/core/import/anki_html.dart';
import 'package:sharedinbox/core/import/anki_template.dart';
import 'package:sharedinbox/core/import/card_import.dart';
import 'package:sharedinbox/core/import/import_ids.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sqlite3/sqlite3.dart' show OpenMode, sqlite3;

/// The deck of a card whose deck is not in the collection.
const ankiDefaultDeck = 'Default';

/// The cards and images of an `.apkg` (#1383).
class AnkiImport {
  const AnkiImport({
    required this.cards,
    required this.media,
    this.skippedCloze = 0,
    this.skippedEmpty = 0,
    this.droppedSounds = 0,
    this.missingMedia = const [],
  });

  final List<ImportedCard> cards;

  /// The referenced images, by blob itemId ([mediaBlobId]).
  final Map<String, ({Uint8List bytes, String contentType})> media;

  /// Cards of cloze notes (not supported yet).
  final int skippedCloze;

  /// Cards whose front renders empty.
  final int skippedEmpty;
  final int droppedSounds;

  /// Referenced images that are not in the file.
  final List<String> missingMedia;
}

const _imageTypes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'svg': 'image/svg+xml',
  'bmp': 'image/bmp',
  'avif': 'image/avif',
};

/// Reads an Anki `.apkg` (a ZIP): the collection `collection.anki21`, else
/// `collection.anki2` (newer exports hold a dummy `anki2` next to the real
/// one), in the legacy schema 11 (note types and decks as JSON in `col`).
/// Every row of `cards` becomes a card: the front is the note rendered
/// with the question template, the back with the answer template without
/// the front, both converted to Markdown ([ankiHtmlToMarkdown]). Cloze
/// notes are skipped. Only images a card references are read.
///
/// Throws [UnsupportedAnkiFormatException] for an `.apkg` with only
/// `collection.anki21b` (#1384) and [FormatException] for a file that is
/// not an `.apkg`.
Future<AnkiImport> readApkg(Uint8List bytes) async {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (e) {
    throw FormatException('not an .apkg (ZIP) file: $e');
  }
  final collection =
      zip.findFile('collection.anki21') ?? zip.findFile('collection.anki2');
  if (collection == null) {
    if (zip.findFile('collection.anki21b') != null) {
      throw const UnsupportedAnkiFormatException(
        'this .apkg holds only collection.anki21b; export it from Anki with '
        '"Support older Anki versions" checked',
      );
    }
    throw const FormatException('no Anki collection in the .apkg');
  }
  final media = _ApkgMedia(zip);
  final dir = await Directory.systemTemp.createTemp('sharedinbox-anki-');
  try {
    final file = File('${dir.path}/collection.sqlite');
    await file.writeAsBytes(collection.readBytes() ?? Uint8List(0));
    return _readCollection(file.path, media);
  } finally {
    await dir.delete(recursive: true);
  }
}

AnkiImport _readCollection(String path, _ApkgMedia media) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    final col = db.select('SELECT models, decks FROM col LIMIT 1');
    if (col.isEmpty) throw const FormatException('the collection has no col');
    final models = _jsonMap(col.first['models']);
    final decks = _jsonMap(col.first['decks']);
    if (models.isEmpty) {
      throw const UnsupportedAnkiFormatException(
        'the collection keeps its note types outside the legacy schema',
      );
    }
    final notes = {
      for (final r in db.select(
        'SELECT id, guid, mid, flds, tags FROM notes',
      ))
        r['id'] as int: r,
    };
    final cards = <ImportedCard>[];
    var cloze = 0;
    var empty = 0;
    var sounds = 0;
    final missing = <String>{};
    for (final c in db.select(
      'SELECT nid, ord, did FROM cards ORDER BY nid, ord',
    )) {
      final note = notes[c['nid'] as int];
      if (note == null) continue;
      final model = models['${note['mid']}'];
      if (model is! Map) continue;
      if (model['type'] == 1) {
        cloze++;
        continue;
      }
      final ord = c['ord'] as int;
      final template = _template(model, ord);
      if (template == null) continue;
      final fields = _fields(model, note['flds'] as String);
      final frontHtml =
          renderAnkiTemplate('${template['qfmt'] ?? ''}', fields);
      final backHtml = renderAnkiBack('${template['afmt'] ?? ''}', fields);
      final front = ankiHtmlToMarkdown(frontHtml, media.resolve);
      final back = ankiHtmlToMarkdown(backHtml, media.resolve);
      sounds += front.droppedSounds + back.droppedSounds;
      missing
        ..addAll(front.missingImages)
        ..addAll(back.missingImages);
      if (front.text.isEmpty) {
        empty++;
        continue;
      }
      final deck = decks['${c['did']}'];
      cards.add(
        ImportedCard(
          cardId: ankiCardId(note['guid'] as String, ord),
          deckName: deck is Map && deck['name'] is String
              ? deck['name'] as String
              : ankiDefaultDeck,
          content: CardContent(
            front: front.text,
            back: back.text,
            tags: '${note['tags'] ?? ''}'
                .split(RegExp(r'\s+'))
                .where((t) => t.isNotEmpty)
                .toList(),
          ),
        ),
      );
    }
    return AnkiImport(
      cards: cards,
      media: media.used,
      skippedCloze: cloze,
      skippedEmpty: empty,
      droppedSounds: sounds,
      missingMedia: missing.toList(),
    );
  } finally {
    db.close();
  }
}

Map<String, Object?> _jsonMap(Object? json) {
  if (json is! String || json.isEmpty) return const {};
  final decoded = jsonDecode(json);
  return decoded is Map<String, Object?> ? decoded : const {};
}

/// The template of card [ord] of note type [model].
Map<Object?, Object?>? _template(Map<Object?, Object?> model, int ord) {
  final tmpls = model['tmpls'];
  if (tmpls is! List) return null;
  for (final t in tmpls) {
    if (t is Map && t['ord'] == ord) return t;
  }
  if (ord < tmpls.length && tmpls[ord] is Map) {
    return tmpls[ord] as Map<Object?, Object?>;
  }
  return null;
}

/// The fields of a note by name: [flds] split on `\x1f`, named by the
/// `flds` of its note type in `ord` order.
Map<String, String> _fields(Map<Object?, Object?> model, String flds) {
  final values = flds.split('\u001f');
  final defs = [
    for (final f in model['flds'] is List ? model['flds'] as List : const [])
      if (f is Map) f,
  ]..sort(
      (a, b) => ((a['ord'] as int?) ?? 0).compareTo((b['ord'] as int?) ?? 0),
    );
  return {
    for (var i = 0; i < defs.length && i < values.length; i++)
      '${defs[i]['name']}': values[i],
  };
}

/// The media of an `.apkg`: the `media` JSON maps the ZIP entries `"0"`,
/// `"1"`, … to file names.
class _ApkgMedia {
  _ApkgMedia(this._zip) {
    final index = _zip.findFile('media');
    if (index == null) return;
    try {
      final decoded =
          jsonDecode(utf8.decode(index.readBytes() ?? Uint8List(0)));
      if (decoded is! Map) return;
      for (final MapEntry(:key, :value) in decoded.entries) {
        if (value is String) _entryByName[value] = '$key';
      }
    } on FormatException {
      // Not the legacy JSON index: no media.
    }
  }

  final Archive _zip;
  final _entryByName = <String, String>{};
  final _blobIdByName = <String, String?>{};

  /// The images resolved so far, by blob itemId.
  final used = <String, ({Uint8List bytes, String contentType})>{};

  /// The blob itemId of image [fileName], or null when it is not in the
  /// file or not an image.
  String? resolve(String fileName) => _blobIdByName.putIfAbsent(fileName, () {
        final name = _entryByName.containsKey(fileName)
            ? fileName
            : _tryDecode(fileName);
        final entry = name == null ? null : _entryByName[name];
        final type = name == null ? null : _imageTypes[_extension(name)];
        if (entry == null || type == null) return null;
        final bytes = _zip.findFile(entry)?.readBytes();
        if (bytes == null) return null;
        final id = mediaBlobId(bytes);
        used[id] = (bytes: bytes, contentType: type);
        return id;
      });

  static String? _tryDecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return null;
    }
  }

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }
}
