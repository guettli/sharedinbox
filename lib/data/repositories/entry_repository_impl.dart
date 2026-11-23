import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/entry_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';

/// [EntryRepository] over the `Entries` projection (read) and the
/// [MailObjectStore] (write), which keeps the projection up to date in its
/// merge ([EntryProjector]).
class EntryRepositoryImpl implements EntryRepository {
  EntryRepositoryImpl(this._db, this._store);

  final AppDatabase _db;
  final MailObjectStore _store;

  @override
  Stream<List<Entry>> observeEntries(String accountId, {String query = ''}) {
    final q = _db.select(_db.entries)
      ..where((t) => t.accountId.equals(accountId))
      ..orderBy([
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm.desc(t.versionId),
      ]);
    final needle = query.trim();
    if (needle.isNotEmpty) {
      final pattern = '%${_likeEscape(needle)}%';
      q.where(
        (t) =>
            t.title.like(pattern, escapeChar: r'\') |
            t.body.like(pattern, escapeChar: r'\'),
      );
    }
    return q.watch().map((rows) => rows.map(_toModel).toList());
  }

  @override
  Future<Entry?> entry(String accountId, String itemId) async {
    final row = await _row(accountId, itemId);
    return row == null ? null : _toModel(row);
  }

  @override
  Future<Entry> create(
    String accountId, {
    String? title,
    required String body,
  }) async {
    final object = newEntryObject(
      title: title,
      body: body,
      clock: await _store.clockFor(accountId),
    );
    await _store.put(accountId, object);
    return (await entry(accountId, object.head.itemId))!;
  }

  @override
  Future<void> update(
    String accountId,
    String itemId, {
    String? title,
    required String body,
  }) async {
    final hmac = await _hmacOf(accountId, itemId);
    final current = await _store.item(accountId, hmac);
    if (current == null) throw StateError('entry $itemId cannot be opened');
    await _store.put(
      accountId,
      editEntryObject(
        base: current.display,
        merge: current.merge,
        clock: await _store.clockFor(accountId),
        title: title,
        body: body,
      ),
    );
  }

  @override
  Future<void> delete(String accountId, String itemId) async {
    await _store.delete(accountId, await _hmacOf(accountId, itemId));
  }

  Future<String> _hmacOf(String accountId, String itemId) async {
    final row = await _row(accountId, itemId);
    if (row == null) throw StateError('unknown entry $itemId');
    return row.itemHmac;
  }

  Future<EntryRow?> _row(String accountId, String itemId) =>
      (_db.select(_db.entries)
            ..where(
              (t) => t.accountId.equals(accountId) & t.itemId.equals(itemId),
            ))
          .getSingleOrNull();

  /// Escapes the LIKE meta-characters with `\`.
  static String _likeEscape(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  static List<String> _strings(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return [
        for (final s in decoded)
          if (s is String) s,
      ];
    } on FormatException {
      return const [];
    }
  }

  static EntryTask? _task(String? json) {
    if (json == null) return null;
    try {
      return EntryTask.fromJson(jsonDecode(json));
    } on FormatException {
      return null;
    }
  }

  static Entry _toModel(EntryRow r) => Entry(
        accountId: r.accountId,
        itemId: r.itemId,
        itemHmac: r.itemHmac,
        title: r.title,
        body: r.body,
        tags: _strings(r.tagsJson),
        date: r.date,
        task: _task(r.taskJson),
        links: _strings(r.linksJson),
        versionId: r.versionId,
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(r.updatedAt, isUtc: true),
        hasConflict: r.hasConflict,
      );
}
