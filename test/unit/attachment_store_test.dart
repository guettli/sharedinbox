import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/data/storage/attachment_store.dart';

void main() {
  group('safeAttachmentName', () {
    test('drops directories, so a name cannot leave its folder', () {
      expect(safeAttachmentName('../../etc/passwd'), 'passwd');
      expect(safeAttachmentName(r'C:\Users\x\report.pdf'), 'report.pdf');
      expect(safeAttachmentName('..'), 'attachment');
      expect(safeAttachmentName(''), 'attachment');
      expect(safeAttachmentName('   '), 'attachment');
    });

    test('replaces control and Windows-invalid characters', () {
      expect(safeAttachmentName('a\x00b\nc\x7f.txt'), 'a_b_c_.txt');
      expect(
        safeAttachmentName('what?<now>:"x"|*.pdf'),
        'what__now___x___.pdf',
      );
    });

    test('strips trailing dots and spaces', () {
      expect(safeAttachmentName('report.pdf. . '), 'report.pdf');
      expect(safeAttachmentName('...'), 'attachment');
    });

    test('truncates to 200 UTF-8 bytes, keeping the extension', () {
      final long = '${'ü' * 300}.pdf';
      final safe = safeAttachmentName(long);
      expect(utf8.encode(safe).length, lessThanOrEqualTo(200));
      expect(safe, endsWith('.pdf'));
      expect(safe, startsWith('üü'));
      // No half characters.
      expect(utf8.decode(utf8.encode(safe)), safe);

      final longExt = 'a.${'x' * 300}';
      expect(utf8.encode(safeAttachmentName(longExt)).length, 200);
    });
  });

  test('a hostile name is stored inside the owner folder', () async {
    final tmp = await Directory.systemTemp.createTemp('attachment_store');
    addTearDown(() => tmp.delete(recursive: true));
    final root = Directory(p.join(tmp.path, 'store'));
    final store = AttachmentStore(() async => root);
    final source = File(p.join(tmp.path, 'src.bin'))..writeAsStringSync('x');

    final [kept] = await store.keep(1, [
      DraftAttachment(
        path: source.path,
        filename: '../../${'n' * 400}\n.pdf',
        contentType: 'application/pdf',
        size: 1,
      ),
    ]);
    final added = await store.add(1, '../../escape.txt', [1, 2]);

    for (final path in [kept.path, added]) {
      expect(p.isWithin(p.join(root.path, '1'), path), isTrue, reason: path);
      expect(await File(path).exists(), isTrue);
    }
    expect(utf8.encode(p.basename(kept.path)).length, lessThanOrEqualTo(200));
    expect(kept.filename, p.basename(kept.path));
  });
}
