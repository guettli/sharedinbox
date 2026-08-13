import 'package:sharedinbox/core/models/folder_tree.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:test/test.dart';

Mailbox _mb(
  String displayPath, {
  String? path,
  String? role,
}) {
  final name = displayPath.split('/').last;
  return Mailbox(
    id: 'acc-1:${path ?? displayPath}',
    accountId: 'acc-1',
    path: path ?? displayPath,
    name: name,
    displayPath: displayPath,
    role: role,
    unreadCount: 0,
    totalCount: 0,
  );
}

void main() {
  group('buildFolderTree', () {
    test('nested paths produce nested nodes', () {
      final roots = buildFolderTree([
        _mb('Archive'),
        _mb('Archive/2026'),
      ]);

      expect(roots, hasLength(1));
      final archive = roots.single;
      expect(archive.label, 'Archive');
      expect(archive.displayPath, 'Archive');
      expect(archive.children, hasLength(1));

      final year = archive.children.single;
      expect(year.label, '2026');
      expect(year.displayPath, 'Archive/2026');
      expect(year.children, isEmpty);
    });

    test('infers a phantom parent for a missing intermediate segment', () {
      // Only the leaf exists as a real mailbox; "Archive" is inferred.
      final roots = buildFolderTree([_mb('Archive/2026')]);

      expect(roots, hasLength(1));
      final archive = roots.single;
      expect(archive.label, 'Archive');
      expect(archive.displayPath, isNull, reason: 'phantom parent');
      expect(archive.children, hasLength(1));
      expect(archive.children.single.displayPath, 'Archive/2026');
    });

    test('sorts each level by role priority then alphabetically', () {
      final roots = buildFolderTree([
        _mb('Zebra'),
        _mb('Archive', role: 'archive'),
        _mb('Inbox', role: 'inbox'),
        _mb('Sent', role: 'sent'),
        _mb('Apple'),
      ]);

      // Roled folders float to the top in role order, then the rest sort
      // alphabetically.
      expect(
        roots.map((n) => n.label).toList(),
        ['Inbox', 'Sent', 'Archive', 'Apple', 'Zebra'],
      );
    });

    test('sorts descendants within their parent', () {
      final roots = buildFolderTree([
        _mb('Work'),
        _mb('Work/Zeta'),
        _mb('Work/Alpha'),
      ]);

      final work = roots.single;
      expect(
        work.children.map((n) => n.label).toList(),
        ['Alpha', 'Zeta'],
      );
    });

    test('uses displayPath, not the opaque JMAP path, for hierarchy', () {
      // JMAP: path is an opaque id, displayPath is the human-readable tree.
      final roots = buildFolderTree([
        _mb('Parent', path: 'a'),
        _mb('Parent/Child', path: 'b'),
      ]);

      final parent = roots.single;
      expect(parent.label, 'Parent');
      expect(parent.displayPath, 'Parent');
      expect(parent.children.single.label, 'Child');
      expect(parent.children.single.displayPath, 'Parent/Child');
    });
  });
}
