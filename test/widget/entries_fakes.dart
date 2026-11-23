import 'dart:async';

import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/entry_repository.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';

/// In-memory [EntryRepository]: entries newest first, search by substring.
class FakeEntryRepository implements EntryRepository {
  FakeEntryRepository([List<Entry> entries = const []])
      : _entries = List.of(entries);

  final List<Entry> _entries;
  final _changes = StreamController<void>.broadcast();
  int _next = 0;
  final updates = <({String itemId, String? title, String body})>[];

  List<Entry> get entries => List.unmodifiable(_entries);

  @override
  Stream<List<Entry>> observeEntries(
    String accountId, {
    String query = '',
  }) async* {
    yield _visible(query);
    yield* _changes.stream.map((_) => _visible(query));
  }

  List<Entry> _visible(String query) {
    final q = query.trim().toLowerCase();
    return [
      for (final e in _entries)
        if (q.isEmpty ||
            (e.title ?? '').toLowerCase().contains(q) ||
            e.body.toLowerCase().contains(q))
          e,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  Future<Entry?> entry(String accountId, String itemId) async {
    for (final e in _entries) {
      if (e.itemId == itemId) return e;
    }
    return null;
  }

  @override
  Future<Entry> create(
    String accountId, {
    String? title,
    required String body,
  }) async {
    final n = _next++;
    final entry = Entry(
      accountId: accountId,
      itemId: 'new-$n',
      itemHmac: 'hmac-new-$n',
      title: title,
      body: body,
      versionId: 'v-new-$n',
      updatedAt: DateTime.utc(2030).add(Duration(minutes: n)),
    );
    _entries.add(entry);
    _changes.add(null);
    return entry;
  }

  @override
  Future<void> update(
    String accountId,
    String itemId, {
    String? title,
    required String body,
  }) async {
    updates.add((itemId: itemId, title: title, body: body));
    final i = _entries.indexWhere((e) => e.itemId == itemId);
    final old = _entries[i];
    _entries[i] = Entry(
      accountId: old.accountId,
      itemId: old.itemId,
      itemHmac: old.itemHmac,
      title: title,
      body: body,
      tags: old.tags,
      versionId: '${old.versionId}+',
      updatedAt: old.updatedAt,
    );
    _changes.add(null);
  }

  @override
  Future<void> delete(String accountId, String itemId) async {
    _entries.removeWhere((e) => e.itemId == itemId);
    _changes.add(null);
  }
}

/// A key lifecycle that only reports a [fixed] status.
class FixedStatusKeyService implements EncryptedKeyService {
  FixedStatusKeyService(this.fixed);

  final PersonalDataStatus fixed;

  @override
  Stream<PersonalDataStatus> watchStatus(String accountId) =>
      Stream.value(fixed);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Entry testEntry(
  String itemId, {
  String? title,
  String body = '',
  bool conflict = false,
  int minute = 0,
}) =>
    Entry(
      accountId: 'acc-1',
      itemId: itemId,
      itemHmac: 'hmac-$itemId',
      title: title,
      body: body,
      versionId: 'v-$itemId',
      updatedAt: DateTime.utc(2026, 11, 23, 10, minute),
      hasConflict: conflict,
    );
