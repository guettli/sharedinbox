import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:sharedinbox/core/models/draft.dart';

/// Resolves the directory an [AttachmentStore] keeps its files in.
typedef GetStoreDirFn = Future<Directory> Function();

/// App-owned copies of attachment files, one folder per owner (a draft or an
/// outbox row): `<root>/<ownerId>/<n>/<filename>`. The numbered subfolder
/// keeps every file under its own name, so the name the recipient sees is
/// always the file's base name.
///
/// The owner's database row is always written before its folder is created;
/// [deleteOrphans] relies on that.
class AttachmentStore {
  AttachmentStore(this._root);

  /// A store in the app support directory, next to the database.
  factory AttachmentStore.appSupport(String name) => AttachmentStore(
        () async => Directory(
          p.join((await getApplicationSupportDirectory()).path, name),
        ),
      );

  final GetStoreDirFn _root;

  Future<Directory> _dir(int ownerId) async =>
      Directory(p.join((await _root()).path, '$ownerId'));

  /// Makes [ownerId]'s folder hold exactly [wanted] and returns [wanted]
  /// with each path pointing at the owned copy. Files already in the folder
  /// are kept; others are copied in; folder files no entry refers to any more
  /// are deleted. A source file that does not exist is returned unchanged, so
  /// the caller can still report it as missing.
  Future<List<DraftAttachment>> keep(
    int ownerId,
    List<DraftAttachment> wanted,
  ) async {
    final dir = await _dir(ownerId);
    final result = <DraftAttachment>[];
    final used = <String>{};
    for (final a in wanted) {
      final owned = _slotOf(dir, a.path);
      if (owned != null && await File(a.path).exists()) {
        used.add(owned);
        result.add(a);
        continue;
      }
      final source = File(a.path);
      if (!await source.exists()) {
        result.add(a);
        continue;
      }
      final slot = await _freeSlot(dir, used);
      used.add(slot);
      final name = safeAttachmentName(a.filename.isEmpty ? a.path : a.filename);
      final target = p.join(dir.path, slot, name);
      await Directory(p.dirname(target)).create(recursive: true);
      await source.copy(target);
      result.add(
        DraftAttachment(
          path: target,
          filename: name,
          contentType: a.contentType,
          size: await File(target).length(),
        ),
      );
    }
    await _deleteSlotsExcept(dir, used);
    return result;
  }

  /// Writes [bytes] as a new file named [filename] into [ownerId]'s folder
  /// and returns its path.
  Future<String> add(int ownerId, String filename, List<int> bytes) async {
    final dir = await _dir(ownerId);
    final used = <String>{};
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        used.add(p.basename(e.path));
      }
    }
    final slot = await _freeSlot(dir, used);
    final target = p.join(dir.path, slot, safeAttachmentName(filename));
    await Directory(p.dirname(target)).create(recursive: true);
    await File(target).writeAsBytes(bytes, flush: true);
    return target;
  }

  /// Whether [path] is a file in [ownerId]'s folder.
  Future<bool> owns(int ownerId, String path) async =>
      _slotOf(await _dir(ownerId), path) != null;

  /// Deletes [ownerId]'s folder. Never throws.
  Future<void> delete(int ownerId) async {
    try {
      final dir = await _dir(ownerId);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // A leftover folder is removed by the next [deleteOrphans].
    }
  }

  /// Deletes the folders of owners that no longer exist. [liveOwnerIds] is
  /// called only after the folders were listed: an owner's row is written
  /// before its folder, so a folder created meanwhile always belongs to a
  /// row the query sees. (A row still inside a transaction counts: the
  /// owners write their rows on the one database connection of the main
  /// isolate, so the query waits for that transaction.)
  Future<void> deleteOrphans(Future<Set<int>> Function() liveOwnerIds) async {
    final root = await _root();
    if (!await root.exists()) return;
    final folders = await root.list().toList();
    if (folders.isEmpty) return;
    final live = await liveOwnerIds();
    for (final folder in folders) {
      final id = int.tryParse(p.basename(folder.path));
      if (id != null && live.contains(id)) continue;
      try {
        await folder.delete(recursive: true);
      } catch (_) {
        // Retried at the next start.
      }
    }
  }

  /// The numbered subfolder of [dir] that holds [path], or null when [path]
  /// is not a file there.
  String? _slotOf(Directory dir, String path) {
    if (!p.isWithin(dir.path, path)) return null;
    final parts = p.split(p.relative(path, from: dir.path));
    return parts.length == 2 ? parts.first : null;
  }

  Future<String> _freeSlot(Directory dir, Set<String> used) async {
    for (var n = 0;; n++) {
      final slot = '$n';
      if (used.contains(slot)) continue;
      if (await Directory(p.join(dir.path, slot)).exists()) continue;
      return slot;
    }
  }

  Future<void> _deleteSlotsExcept(Directory dir, Set<String> used) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (used.contains(p.basename(e.path))) continue;
      await e.delete(recursive: true);
    }
    if (used.isEmpty) await dir.delete(recursive: true);
  }
}

/// Longest file name [safeAttachmentName] returns, in UTF-8 bytes. File
/// systems allow 255; the margin leaves room for what others append.
const _maxNameBytes = 200;

/// [name] reduced to a file name every platform can store: no directories,
/// no control characters or characters Windows refuses, no trailing dots or
/// spaces, at most [_maxNameBytes] UTF-8 bytes (the extension is kept), and
/// never empty.
String safeAttachmentName(String name) {
  var base = name.replaceAll(r'\', '/').split('/').last;
  base = base.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '_');
  base = base.replaceFirst(RegExp(r'[. ]+$'), '').trim();
  if (base.isEmpty || base == '.' || base == '..') return 'attachment';
  if (utf8.encode(base).length <= _maxNameBytes) return base;
  final ext = p.extension(base);
  final keepExt = utf8.encode(ext).length <= 20 ? ext : '';
  final stem = base.substring(0, base.length - keepExt.length);
  final budget = _maxNameBytes - utf8.encode(keepExt).length;
  final out = StringBuffer();
  var used = 0;
  for (final rune in stem.runes) {
    final char = String.fromCharCode(rune);
    final bytes = utf8.encode(char).length;
    if (used + bytes > budget) break;
    out.write(char);
    used += bytes;
  }
  final truncated = out.toString().replaceFirst(RegExp(r'[. ]+$'), '');
  return '${truncated.isEmpty ? 'attachment' : truncated}$keepExt';
}
