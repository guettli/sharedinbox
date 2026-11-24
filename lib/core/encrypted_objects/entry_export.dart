/// The plaintext export of the entries of one account
/// (ENCRYPTED-OBJECTS.md §6.1, #1356): a ZIP of Markdown files with a front
/// matter, plus the images as files. The layout is deterministic: only
/// `manifest.exportedAt` and the ZIP name vary between two runs.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/utils/markdown_images.dart';
import 'package:yaml/yaml.dart';

/// One file under `entries/`: the displayed head of an item
/// ([displayed]), or another distinct head of an item in [conflict]. A
/// tombstone head ([deleted]) has no [entry].
typedef ExportEntryFile = ({
  Entry? entry,
  String itemId,
  String versionId,
  DateTime updatedAt,
  bool conflict,
  bool deleted,
  bool displayed,
});

/// The file of the displayed head of [entry].
ExportEntryFile displayedExportFile(Entry entry) => (
      entry: entry,
      itemId: entry.itemId,
      versionId: entry.versionId,
      updatedAt: entry.updatedAt,
      conflict: entry.hasConflict,
      deleted: false,
      displayed: true,
    );

/// An image of the export.
typedef ExportImage = ({String contentType, Uint8List bytes});

/// A finished export: the ZIP, its suggested name and what it holds.
typedef EntryExportResult = ({
  Uint8List zip,
  String fileName,
  int entries,
  int conflictVersions,
  int images,
  List<String> missingImages,
});

/// Builds the plaintext export of an unlocked account.
abstract class EntryExportService {
  /// Every entry of [account], every other head of those in conflict, and
  /// their images; an image that cannot be loaded is listed in
  /// `missingImages`.
  Future<EntryExportResult> export(Account account);
}

/// `format` in `manifest.json`.
const exportFormat = 'sharedinbox-export';

/// `version` in `manifest.json`.
const exportFormatVersion = 1;

/// [versionId] (or any text) as a file name part: every character outside
/// `[A-Za-z0-9_-]` becomes `_`.
String exportSafeName(String versionId) =>
    versionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

/// `entries/<itemId>.md`, or `entries/<itemId>.conflict-<versionId>.md` for
/// a head that is not the displayed one.
String exportEntryPath(ExportEntryFile f) {
  final item = exportSafeName(f.itemId);
  if (f.displayed) return 'entries/$item.md';
  return 'entries/$item.conflict-${exportSafeName(f.versionId)}.md';
}

/// The extension of an image file of [contentType].
String exportImageExtension(String contentType) =>
    switch (contentType.split(';').first.trim().toLowerCase()) {
      'image/png' => 'png',
      'image/jpeg' || 'image/jpg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'bin',
    };

/// The name of the export of [account] made at [exportedAt] (its local
/// fields).
String exportFileName(Account account, DateTime exportedAt) {
  String two(int n) => n.toString().padLeft(2, '0');
  final t = exportedAt;
  final stamp = '${t.year.toString().padLeft(4, '0')}${two(t.month)}'
      '${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  return 'sharedinbox-export-${account.email}-$stamp.zip';
}

/// [f] as Markdown with a YAML front matter. An image whose blob is in
/// [imageFiles] (blob id -> file name under `images/`) links to that file;
/// any other keeps its `si-img:` link.
String entryToMarkdown(ExportEntryFile f, Map<String, String> imageFiles) {
  final out = StringBuffer('---\n');
  void field(String key, Object? value) =>
      out.write('$key: ${_yamlValue(value)}\n');
  field('itemId', f.itemId);
  field('versionId', f.versionId);
  final e = f.entry;
  if (f.deleted || e == null) {
    field('updatedAt', _iso(f.updatedAt));
    if (f.conflict) field('conflict', true);
    field('deleted', true);
    out.write('---\n');
    return out.toString();
  }
  if (e.title != null) field('title', e.title);
  field('tags', e.tags);
  if (e.date != null) field('date', e.date);
  if (e.task != null) field('task', e.task!.toJson());
  field('links', e.links);
  if (e.createdAt != null) field('createdAt', _iso(e.createdAt!));
  field('updatedAt', _iso(f.updatedAt));
  if (f.conflict) field('conflict', true);
  out.write('---\n');
  out.write(_linkImages(e.body, imageFiles));
  return out.toString();
}

String _iso(DateTime t) => t.toUtc().toIso8601String();

/// [value] as a YAML flow value: strings, numbers and booleans as JSON
/// (a JSON string is a valid double-quoted YAML scalar), lists and maps
/// as flow collections of those.
String _yamlValue(Object? value) {
  if (value is List) return '[${value.map(_yamlValue).join(', ')}]';
  if (value is Map) {
    final pairs = [
      for (final MapEntry(:key, :value) in value.entries)
        '${jsonEncode('$key')}: ${_yamlValue(value)}',
    ];
    return '{${pairs.join(', ')}}';
  }
  return jsonEncode(value);
}

String _linkImages(String body, Map<String, String> imageFiles) =>
    body.replaceAllMapped(siImagePattern, (m) {
      final file = imageFiles[m.group(2)!];
      if (file == null) return m.group(0)!;
      return '${m.group(1)}../images/$file';
    });

final _exportedImage =
    RegExp(r'(!\[[^\]]*\]\(\s*<?)\.\./images/([A-Za-z0-9_-]+)\.[A-Za-z0-9]+');

/// One file under `entries/` read back ([parseExportedEntry]).
class ParsedExportEntry {
  const ParsedExportEntry({
    required this.itemId,
    required this.versionId,
    this.title,
    this.tags = const [],
    this.date,
    this.task,
    this.links = const [],
    this.createdAt,
    this.updatedAt,
    this.conflict = false,
    this.deleted = false,
    this.body = '',
  });

  final String itemId;
  final String versionId;
  final String? title;
  final List<String> tags;
  final String? date;
  final EntryTask? task;
  final List<String> links;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool conflict;
  final bool deleted;

  /// With its images linking to `si-img:` again.
  final String body;
}

/// Reads a file written by [entryToMarkdown]. Throws [FormatException]
/// when it has no front matter or no `itemId`/`versionId`.
ParsedExportEntry parseExportedEntry(String md) {
  if (!md.startsWith('---\n')) {
    throw const FormatException('no front matter');
  }
  final end = md.indexOf('\n---\n', 3);
  if (end < 0) throw const FormatException('front matter not closed');
  final yaml = loadYaml(md.substring(4, end + 1));
  if (yaml is! Map) throw const FormatException('front matter is no map');
  final itemId = yaml['itemId'];
  final versionId = yaml['versionId'];
  if (itemId is! String || versionId is! String) {
    throw const FormatException('itemId or versionId missing');
  }
  final title = yaml['title'];
  final date = yaml['date'];
  final createdAt = yaml['createdAt'];
  final updatedAt = yaml['updatedAt'];
  final body = md.substring(end + 5);
  return ParsedExportEntry(
    itemId: itemId,
    versionId: versionId,
    title: title is String ? title : null,
    tags: _strings(yaml['tags']),
    date: date is String ? date : null,
    task: EntryTask.fromJson(yaml['task']),
    links: _strings(yaml['links']),
    createdAt: createdAt is String ? DateTime.tryParse(createdAt) : null,
    updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
    conflict: yaml['conflict'] == true,
    deleted: yaml['deleted'] == true,
    body: body.replaceAllMapped(
      _exportedImage,
      (m) => '${m.group(1)}$siImgScheme:${m.group(2)}',
    ),
  );
}

List<String> _strings(Object? yaml) => [
      if (yaml is List)
        for (final s in yaml)
          if (s is String) s,
    ];

const _readme = '''
SharedInbox export of personal data

This export is NOT encrypted. Anyone who gets this file can read every
note, todo and journal entry in it. Store it safely.

Layout (ENCRYPTED-OBJECTS.md, section 6.1 "Plaintext export"):

  manifest.json                             format, version and counts
  entries/<itemId>.md                       one entry: YAML front matter,
                                            then the Markdown body
  entries/<itemId>.conflict-<versionId>.md  another version of an entry in
                                            conflict
  images/<blobItemId>.<ext>                 the images the entries show
''';

/// The ZIP of [files] and [images] (blob id -> image) of [account].
/// [missingImages] are the blob ids that could not be loaded; their links
/// stay `si-img:`. Every ZIP entry gets the mtime [exportedAt].
Uint8List buildEntriesExport({
  required Account account,
  required List<ExportEntryFile> files,
  required Map<String, ExportImage> images,
  required List<String> missingImages,
  required DateTime exportedAt,
}) {
  final imageFiles = {
    for (final MapEntry(:key, :value) in images.entries)
      key: '${exportSafeName(key)}.${exportImageExtension(value.contentType)}',
  };
  final manifest = {
    'format': exportFormat,
    'version': exportFormatVersion,
    'exportedAt': _iso(exportedAt),
    'accountId': account.id,
    'accountEmail': account.email,
    'entries': files.where((f) => f.displayed).length,
    'conflictVersions': files.where((f) => !f.displayed).length,
    'images': images.length,
    'missingImages': [...missingImages]..sort(),
  };
  final contents = <String, List<int>>{
    'README.txt': utf8.encode(_readme),
    'manifest.json': utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    ),
    for (final f in files)
      exportEntryPath(f): utf8.encode(entryToMarkdown(f, imageFiles)),
    for (final MapEntry(:key, :value) in images.entries)
      'images/${imageFiles[key]}': value.bytes,
  };
  final archive = Archive();
  for (final path in contents.keys.toList()..sort()) {
    final bytes = contents[path]!;
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }
  return ZipEncoder().encodeBytes(archive, modified: exportedAt);
}
