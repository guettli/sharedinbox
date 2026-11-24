import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/entry_export.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/utils/markdown_images.dart';

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

final _exportedAt = DateTime.utc(2026, 11, 23, 10, 30, 5);
final _png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);

Entry _entry(
  String itemId, {
  String? title,
  String body = '',
  String versionId = '0001795000000000-0000-devA',
  bool conflict = false,
  EntryTask? task,
  List<String> tags = const [],
  List<String> links = const [],
  String? date,
  DateTime? createdAt,
}) =>
    Entry(
      accountId: _account.id,
      itemId: itemId,
      itemHmac: 'hmac-$itemId',
      title: title,
      body: body,
      tags: tags,
      date: date,
      task: task,
      links: links,
      createdAt: createdAt,
      versionId: versionId,
      updatedAt: DateTime.utc(2026, 11, 23, 9),
      hasConflict: conflict,
    );

ExportEntryFile _other(Entry? entry, String itemId, String versionId) => (
      entry: entry,
      itemId: itemId,
      versionId: versionId,
      updatedAt: DateTime.utc(2026, 11, 23, 8),
      conflict: true,
      deleted: entry == null,
      displayed: false,
    );

Map<String, Uint8List> _unzip(Uint8List zip) => {
      for (final f in ZipDecoder().decodeBytes(zip).files)
        f.name: f.readBytes()!,
    };

void main() {
  const v2 = '0001795000000001-0000-devB';
  const v3 = '0001795000000002-0000-devC';
  const img = 'imgBlob_1-x';

  List<ExportEntryFile> layoutFiles() {
    final b = _entry('itemB', body: 'B ![p](si-img:$img)', conflict: true);
    return [
      displayedExportFile(_entry('itemA', title: 'A')),
      displayedExportFile(b),
      _other(
        _entry('itemB', body: 'B2', versionId: v2, conflict: true),
        'itemB',
        v2,
      ),
      _other(null, 'itemB', v3),
    ];
  }

  Uint8List build({
    List<ExportEntryFile>? files,
    Map<String, ExportImage>? images,
    List<String> missing = const [],
  }) =>
      buildEntriesExport(
        account: _account,
        files: files ?? layoutFiles(),
        images: images ?? {img: (contentType: 'image/png', bytes: _png)},
        missingImages: missing,
        exportedAt: _exportedAt,
      );

  test('the file layout', () {
    final zip = build();
    final names = [for (final f in ZipDecoder().decodeBytes(zip).files) f.name];
    expect(names, [
      'README.txt',
      'entries/itemA.md',
      'entries/itemB.conflict-$v2.md',
      'entries/itemB.conflict-$v3.md',
      'entries/itemB.md',
      'images/$img.png',
      'manifest.json',
    ]);
    expect(names, [...names]..sort());

    final files = _unzip(zip);
    String text(String name) => utf8.decode(files[name]!);
    expect(text('README.txt'), contains('NOT encrypted'));
    final a = parseExportedEntry(text('entries/itemA.md'));
    expect(a.conflict, isFalse);
    for (final name in [
      'entries/itemB.md',
      'entries/itemB.conflict-$v2.md',
      'entries/itemB.conflict-$v3.md',
    ]) {
      expect(parseExportedEntry(text(name)).conflict, isTrue, reason: name);
    }
    final tomb = parseExportedEntry(text('entries/itemB.conflict-$v3.md'));
    expect(tomb.deleted, isTrue);
    expect(tomb.versionId, v3);
    expect(tomb.body, isEmpty);
    expect(text('entries/itemB.conflict-$v3.md'), isNot(contains('tags')));
    expect(parseExportedEntry(text('entries/itemB.md')).deleted, isFalse);
    expect(text('entries/itemB.md'), contains('](../images/$img.png)'));
    expect(files['images/$img.png'], _png);

    final manifest = jsonDecode(text('manifest.json')) as Map<String, Object?>;
    expect(manifest, {
      'format': 'sharedinbox-export',
      'version': 1,
      'exportedAt': '2026-11-23T10:30:05.000Z',
      'accountId': 'acc-1',
      'accountEmail': 'alice@example.com',
      'entries': 2,
      'conflictVersions': 2,
      'images': 1,
      'missingImages': <Object?>[],
    });
  });

  test('two builds of the same input are byte-identical', () {
    expect(build(), build());
  });

  test('a version id is made safe for a file name', () {
    expect(exportSafeName('a.b:c/d-e_f'), 'a_b_c_d-e_f');
    expect(
      exportEntryPath(_other(null, 'item', '1:2')),
      'entries/item.conflict-1_2.md',
    );
  });

  test('image extensions follow the content type', () {
    expect(exportImageExtension('image/png'), 'png');
    expect(exportImageExtension('IMAGE/JPEG; q=1'), 'jpg');
    expect(exportImageExtension('image/gif'), 'gif');
    expect(exportImageExtension('image/webp'), 'webp');
    expect(exportImageExtension('application/octet-stream'), 'bin');
  });

  test('the ZIP name holds the account and the time', () {
    expect(
      exportFileName(_account, DateTime(2026, 1, 2, 3, 4, 5)),
      'sharedinbox-export-alice@example.com-20260102-030405.zip',
    );
  });

  test('a tricky title survives; absent fields are left out', () {
    const title = 'a: "b"\nc # d';
    final md = entryToMarkdown(
      displayedExportFile(_entry('item', title: title, body: 'x')),
      const {},
    );
    final parsed = parseExportedEntry(md);
    expect(parsed.title, title);
    expect(parsed.body, 'x');
    expect(md, isNot(contains('date:')));
    expect(md, isNot(contains('task:')));
    expect(md, isNot(contains('createdAt:')));
    expect(md, isNot(contains('conflict:')));
    expect(md, isNot(contains('deleted:')));
    final bare = parseExportedEntry(
      entryToMarkdown(displayedExportFile(_entry('item')), const {}),
    );
    expect(bare.title, isNull);
    expect(bare.task, isNull);
    expect(bare.date, isNull);
    expect(bare.createdAt, isNull);
  });

  test('round trip of an entry with an image and a task', () {
    const body = 'Intro\n\n- [ ] milk\n- [x] eggs\n\n![pic](si-img:$img)\n';
    const task = EntryTask(due: '2026-12-01', priority: 2, done: true);
    final entry = _entry(
      'item1',
      title: 'Shopping',
      body: body,
      task: task,
      tags: ['home', 'food'],
      links: ['<m1@example.com>'],
      date: '2026-11-23',
      createdAt: DateTime.utc(2026, 11, 20, 7, 15),
    );
    final zip = build(files: [displayedExportFile(entry)]);
    final files = _unzip(zip);
    final parsed = parseExportedEntry(utf8.decode(files['entries/item1.md']!));

    expect(parsed.itemId, entry.itemId);
    expect(parsed.versionId, entry.versionId);
    expect(parsed.title, entry.title);
    expect(parsed.tags, entry.tags);
    expect(parsed.date, entry.date);
    expect(parsed.task!.toJson(), task.toJson());
    expect(parsed.links, entry.links);
    expect(parsed.createdAt, entry.createdAt);
    expect(parsed.updatedAt, entry.updatedAt);
    expect(parsed.conflict, isFalse);
    expect(parsed.body, body);
    final ids = siImageIds(parsed.body);
    expect(ids, [img]);
    expect(files['images/${ids.single}.png'], _png);
  });

  test('a missing image keeps its si-img link and is listed', () {
    final entry = _entry('item1', body: '![a](si-img:gone)');
    final zip = build(
      files: [displayedExportFile(entry)],
      images: const {},
      missing: ['gone'],
    );
    final files = _unzip(zip);
    expect(files.keys.where((n) => n.startsWith('images/')), isEmpty);
    final md = utf8.decode(files['entries/item1.md']!);
    expect(md, contains('![a](si-img:gone)'));
    final manifest = jsonDecode(utf8.decode(files['manifest.json']!))
        as Map<String, Object?>;
    expect(manifest['missingImages'], ['gone']);
    expect(manifest['images'], 0);
  });

  test('a file without front matter does not parse', () {
    expect(() => parseExportedEntry('hello'), throwsFormatException);
    expect(
      () => parseExportedEntry('---\nitemId: "a"\n'),
      throwsFormatException,
    );
    expect(
      () => parseExportedEntry('---\ntitle: "a"\n---\n'),
      throwsFormatException,
    );
    expect(() => parseExportedEntry('---\n- a\n---\n'), throwsFormatException);
  });

  test('si-img helpers', () {
    expect(siImageId(Uri.parse('si-img:abc_-1')), 'abc_-1');
    expect(siImageId(Uri.parse('https://x/abc')), isNull);
    expect(siImageId(Uri.parse('si-img:a/b')), isNull);
    expect(
      siImageIds('![](si-img:a) text ![x](si-img:b) ![](si-img:a)'),
      ['a', 'b'],
    );
  });
}
