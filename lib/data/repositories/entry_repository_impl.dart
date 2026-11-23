import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/entry_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/db/like_escape.dart';
import 'package:sharedinbox/data/repositories/projection_json.dart';

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
        (t) => OrderingTerm.desc(_sortDate(t)),
        (t) => OrderingTerm.desc(t.versionId),
      ]);
    final needle = query.trim();
    if (needle.isNotEmpty) {
      final pattern = '%${likeEscape(needle)}%';
      q.where(
        (t) =>
            t.title.like(pattern, escapeChar: r'\') |
            t.body.like(pattern, escapeChar: r'\'),
      );
    }
    return q.watch().map((rows) => rows.map(_toModel).toList());
  }

  /// `createdAt`, else `updatedAt` (#1375).
  static Expression<int> _sortDate($EntriesTable t) =>
      coalesce([t.createdAt, t.updatedAt]);

  @override
  Stream<List<Entry>> observeEntriesForMessages(
    String accountId,
    Iterable<String> messageIds,
  ) {
    final ids = messageIds.toSet();
    if (ids.isEmpty) return Stream.value(const <Entry>[]);
    final e = _db.entries;
    final l = _db.entryLinks;
    final q = _db.select(e).join([
      innerJoin(
        l,
        l.accountId.equalsExp(e.accountId) & l.itemHmac.equalsExp(e.itemHmac),
      ),
    ])
      ..where(e.accountId.equals(accountId) & l.messageId.isIn(ids))
      ..orderBy([
        OrderingTerm.asc(_sortDate(e)),
        OrderingTerm.asc(e.versionId),
      ]);
    return q.watch().map((rows) {
      // An entry linked to several of the mails comes once.
      final seen = <String>{};
      return [
        for (final r in rows)
          if (seen.add(r.readTable(e).itemId)) _toModel(r.readTable(e)),
      ];
    });
  }

  @override
  Stream<List<Entry>> observeTodos({
    required Set<String> accountIds,
    required TodoFilter filter,
    required String today,
  }) {
    final q = _db.select(_db.entries)
      ..where((t) => t.taskJson.isNotNull() & t.accountId.isIn(accountIds));
    return q.watch().map(
          (rows) => [
            for (final e in rows.map(_toModel))
              if (e.task?.matches(filter, today) ?? false) e,
          ]..sort(filter == TodoFilter.done ? _newestFirst : _byDue),
        );
  }

  static int _newestFirst(Entry a, Entry b) =>
      b.sortDate.compareTo(a.sortDate);

  /// By due date (none last), priority (none last), then newest first.
  static int _byDue(Entry a, Entry b) {
    final due = _nullsLast(a.task!.due, b.task!.due);
    if (due != 0) return due;
    final priority = _nullsLast<num>(a.task!.priority, b.task!.priority);
    if (priority != 0) return priority;
    return _newestFirst(a, b);
  }

  static int _nullsLast<T extends Comparable<T>>(T? a, T? b) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return a.compareTo(b);
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
    EntryTask? task,
    List<String> links = const [],
  }) async {
    final object = newEntryObject(
      title: title,
      body: body,
      clock: await _store.clockFor(accountId),
      task: task,
      links: links,
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
  }) =>
      _edit(
        accountId,
        itemId,
        (current, clock) => editEntryObject(
          base: current.display,
          merge: current.merge,
          clock: clock,
          title: title,
          body: body,
        ),
      );

  @override
  Future<void> setTask(String accountId, String itemId, EntryTask? task) =>
      _edit(
        accountId,
        itemId,
        (current, clock) => editEntryTask(
          base: current.display,
          merge: current.merge,
          clock: clock,
          task: task,
        ),
      );

  /// Writes the version [next] makes of the entry's current state.
  Future<void> _edit(
    String accountId,
    String itemId,
    InnerObject Function(MailObjectItem current, HlcClock clock) next,
  ) async {
    final hmac = await _hmacOf(accountId, itemId);
    final current = await _store.item(accountId, hmac);
    if (current == null) throw StateError('entry $itemId cannot be opened');
    await _store.put(
      accountId,
      next(current, await _store.clockFor(accountId)),
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
        tags: stringsFromJson(r.tagsJson),
        date: r.date,
        task: _task(r.taskJson),
        links: stringsFromJson(r.linksJson),
        createdAt: r.createdAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r.createdAt!, isUtc: true),
        versionId: r.versionId,
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(r.updatedAt, isUtc: true),
        hasConflict: r.hasConflict,
      );
}
