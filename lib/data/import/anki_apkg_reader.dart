import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/import/anki_html.dart';
import 'package:sharedinbox/core/import/anki_revlog.dart';
import 'package:sharedinbox/core/import/anki_template.dart';
import 'package:sharedinbox/core/import/card_import.dart';
import 'package:sharedinbox/core/import/import_ids.dart';
import 'package:sharedinbox/core/import/protobuf_wire.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sqlite3/sqlite3.dart' show Database, OpenMode, sqlite3;

/// The deck of a card whose deck is not in the collection.
const ankiDefaultDeck = 'Default';

/// The cards, images and review history of an `.apkg` (#1383, #1385).
class AnkiImport {
  const AnkiImport({
    required this.cards,
    required this.media,
    required this.reviewDeviceId,
    this.reviews = const [],
    this.skippedReviews = 0,
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

  /// The deviceId of the review history ([ankiImportDeviceId]).
  final String reviewDeviceId;

  /// The review history of [cards] ([ankiReviewEvents]), in `seq` order.
  final List<ReviewEvent> reviews;

  /// Rows of the `revlog` that are not [reviews].
  final int skippedReviews;
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

/// The `meta` version of an `.apkg` whose collection is
/// `collection.anki21b` and whose media are zstd-compressed with a protobuf
/// `media` map (Anki's `PackageMetadata.Version.LATEST`).
const _latestVersion = 3;

/// The largest collection or media file a zstd entry may unpack to.
const _maxUnpackedSize = 1 << 30;

/// Reads an Anki `.apkg` (a ZIP). The collection is `collection.anki21b`
/// when the `meta` version is LATEST (3) or the entry is there (newer
/// exports hold a dummy `anki2` next to it): a zstd-compressed SQLite file
/// in schema 18 (note types, fields, templates and decks in their own
/// tables, their configs as protobuf, deck names split by `\x1f`), whose
/// `media` map is a zstd-compressed protobuf `MediaEntries` and whose media
/// files are zstd-compressed (#1384). Else it is `collection.anki21`, then
/// `collection.anki2`, in the legacy schema 11 (note types and decks as
/// JSON in `col`) with a JSON `media` map. Every row of `cards` becomes a
/// card: the front is the note rendered with the question template, the
/// back with the answer template without the front, both converted to
/// Markdown ([ankiHtmlToMarkdown]). Cloze notes are skipped. Only images a
/// card references are read. The `revlog` rows of the imported cards
/// become [AnkiImport.reviews].
///
/// Throws [UnsupportedAnkiFormatException] for a `meta` version above
/// LATEST or a collection in neither schema, and [FormatException] for a
/// file that is not an `.apkg` or holds invalid zstd or protobuf data.
Future<AnkiImport> readApkg(Uint8List bytes) async {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (e) {
    throw FormatException('not an .apkg (ZIP) file: $e');
  }
  final version = _packageVersion(zip);
  if (version > _latestVersion) {
    throw UnsupportedAnkiFormatException(
      'this .apkg is of a newer Anki version (package version $version)',
    );
  }
  final latest = version == _latestVersion;
  final anki21b = zip.findFile('collection.anki21b');
  final Uint8List collection;
  if (latest || anki21b != null) {
    if (anki21b == null) {
      throw const FormatException('no collection.anki21b in the .apkg');
    }
    collection = _unzstd(anki21b.readBytes() ?? Uint8List(0), anki21b.name);
  } else {
    final legacy =
        zip.findFile('collection.anki21') ?? zip.findFile('collection.anki2');
    if (legacy == null) {
      throw const FormatException('no Anki collection in the .apkg');
    }
    collection = legacy.readBytes() ?? Uint8List(0);
  }
  final media = latest ? _ApkgMedia.latest(zip) : _ApkgMedia.legacy(zip);
  final dir = await Directory.systemTemp.createTemp('sharedinbox-anki-');
  try {
    final file = File('${dir.path}/collection.sqlite');
    await file.writeAsBytes(collection);
    return _readCollection(file.path, media);
  } finally {
    await dir.delete(recursive: true);
  }
}

/// The `PackageMetadata.version` of the `meta` entry; 0 without one
/// (a legacy package).
int _packageVersion(Archive zip) {
  final meta = zip.findFile('meta');
  if (meta == null) return 0;
  return ProtoReader(meta.readBytes() ?? Uint8List(0)).varint(1) ?? 0;
}

/// [data] (the ZIP entry [name]) decompressed with zstd.
Uint8List _unzstd(Uint8List data, String name) {
  try {
    return ZstdDecoder().decodeBytes(
      data,
      verify: true,
      throwOnError: true,
      maxOutputSize: _maxUnpackedSize,
    );
  } catch (e) {
    throw FormatException('$name is not valid zstd data: $e');
  }
}

AnkiImport _readCollection(String path, _ApkgMedia media) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    // Schema 18 sorts names with Anki's own collation.
    db.createCollation(
      name: 'unicase',
      function: (a, b) =>
          (a ?? '').toLowerCase().compareTo((b ?? '').toLowerCase()),
    );
    final col = db.select('SELECT crt, models, decks FROM col LIMIT 1');
    if (col.isEmpty) throw const FormatException('the collection has no col');
    var models = _jsonMap(col.first['models']);
    var decks = _jsonMap(col.first['decks']);
    if (models.isEmpty && _hasTable(db, 'notetypes')) {
      models = _tableModels(db);
      decks = _tableDecks(db);
    }
    if (models.isEmpty) {
      throw const UnsupportedAnkiFormatException(
        'the collection keeps its note types in an unknown schema',
      );
    }
    final notes = {
      for (final r in db.select(
        'SELECT id, guid, mid, flds, tags FROM notes',
      ))
        r['id'] as int: r,
    };
    final cards = <ImportedCard>[];
    final cardIdByCid = <int, String>{};
    var cloze = 0;
    var empty = 0;
    var sounds = 0;
    final missing = <String>{};
    for (final c in db.select(
      'SELECT id, nid, ord, did FROM cards ORDER BY nid, ord',
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
      final frontHtml = renderAnkiTemplate('${template['qfmt'] ?? ''}', fields);
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
      final cardId = ankiCardId(note['guid'] as String, ord);
      cardIdByCid[c['id'] as int] = cardId;
      cards.add(
        ImportedCard(
          cardId: cardId,
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
    final deviceId = ankiImportDeviceId(col.first['crt'] as int? ?? 0);
    final reviews = ankiReviewEvents(deviceId, [
      for (final r in db.select(
        'SELECT id, cid, ease, time, type, ivl FROM revlog ORDER BY id',
      ))
        AnkiRevlogRow(
          id: r['id'] as int,
          cardId: cardIdByCid[r['cid'] as int],
          ease: r['ease'] as int,
          time: r['time'] as int,
          type: r['type'] as int,
          ivl: r['ivl'] as int,
        ),
    ]);
    return AnkiImport(
      cards: cards,
      media: media.used,
      reviewDeviceId: deviceId,
      reviews: reviews.events,
      skippedReviews: reviews.skipped,
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

bool _hasTable(Database db, String name) => db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [name],
    ).isNotEmpty;

/// The note types of a schema 18 collection, in the shape of the legacy
/// `col.models` JSON: `{type, flds: [{name, ord}], tmpls: [{ord, qfmt,
/// afmt}]}` by id. `type` is `NotetypeConfig.kind` (field 1, 1 = cloze),
/// `qfmt`/`afmt` are `CardTemplate.Config.q_format`/`a_format` (fields 1
/// and 2).
Map<String, Object?> _tableModels(Database db) {
  final flds = <String, List<Object?>>{};
  final tmpls = <String, List<Object?>>{};
  for (final r in db.select('SELECT ntid, ord, name FROM fields')) {
    flds.putIfAbsent('${r['ntid']}', () => []).add({
      'name': r['name'],
      'ord': r['ord'],
    });
  }
  for (final r in db.select('SELECT ntid, ord, config FROM templates')) {
    final config = ProtoReader(_blob(r['config']));
    tmpls.putIfAbsent('${r['ntid']}', () => []).add({
      'ord': r['ord'],
      'qfmt': config.string(1) ?? '',
      'afmt': config.string(2) ?? '',
    });
  }
  return {
    for (final r in db.select('SELECT id, config FROM notetypes'))
      '${r['id']}': {
        'type': ProtoReader(_blob(r['config'])).varint(1) ?? 0,
        'flds': flds['${r['id']}'] ?? const [],
        'tmpls': tmpls['${r['id']}'] ?? const [],
      },
  };
}

/// The decks of a schema 18 collection, in the shape of the legacy
/// `col.decks` JSON: `{name}` by id, the `\x1f`-separated name parts
/// joined with `::`.
Map<String, Object?> _tableDecks(Database db) => {
      for (final r in db.select('SELECT id, name FROM decks'))
        '${r['id']}': {'name': '${r['name']}'.replaceAll('\u001f', '::')},
    };

Uint8List _blob(Object? value) => value is Uint8List ? value : Uint8List(0);

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

/// The media of an `.apkg`: the `media` map names the ZIP entries `"0"`,
/// `"1"`, … by file name.
class _ApkgMedia {
  /// The legacy `media` JSON `{"0": "cat.png", …}`.
  _ApkgMedia.legacy(this._zip) : _zstd = false {
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

  /// The zstd-compressed protobuf `MediaEntries { repeated MediaEntry
  /// entries = 1; }` with `MediaEntry { string name = 1; …; optional uint32
  /// legacy_zip_filename = 255; }`: entry i is in the ZIP entry
  /// `legacy_zip_filename ?? i`, zstd-compressed.
  _ApkgMedia.latest(this._zip) : _zstd = true {
    final index = _zip.findFile('media');
    if (index == null) return;
    final entries = ProtoReader(
      _unzstd(index.readBytes() ?? Uint8List(0), index.name),
    ).repeated(1);
    for (var i = 0; i < entries.length; i++) {
      final entry = ProtoReader(entries[i]);
      final name = entry.string(1);
      if (name == null || name.isEmpty) continue;
      _entryByName[name] = '${entry.varint(255) ?? i}';
    }
  }

  final Archive _zip;
  final bool _zstd;
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
        final file = _zip.findFile(entry);
        final stored = file?.readBytes();
        if (file == null || stored == null) return null;
        final bytes = _zstd ? _unzstd(stored, file.name) : stored;
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
