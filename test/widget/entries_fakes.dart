import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/entry_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

/// In-memory [EntryRepository]: entries newest first, search by substring.
class FakeEntryRepository implements EntryRepository {
  FakeEntryRepository([List<Entry> entries = const []])
      : _entries = List.of(entries);

  final List<Entry> _entries;
  final _changes = StreamController<void>.broadcast();
  int _next = 0;
  final updates = <({String itemId, String? title, String body})>[];
  final taskUpdates = <({String accountId, String itemId, EntryTask? task})>[];

  /// The accounts [create] was called for, in order.
  final createdIn = <String>[];

  /// Thrown by the next [create], if set.
  Object? failCreateWith;

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
  Stream<List<Entry>> observeTodos({
    required Set<String> accountIds,
    required TodoFilter filter,
    required String today,
  }) async* {
    yield _todos(accountIds, filter, today);
    yield* _changes.stream.map((_) => _todos(accountIds, filter, today));
  }

  List<Entry> _todos(Set<String> accountIds, TodoFilter filter, String today) =>
      [
        for (final e in _entries)
          if (accountIds.contains(e.accountId) &&
              (e.task?.matches(filter, today) ?? false))
            e,
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

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
    EntryTask? task,
    List<String> links = const [],
  }) async {
    final fail = failCreateWith;
    failCreateWith = null;
    if (fail != null) throw fail;
    createdIn.add(accountId);
    final n = _next++;
    final entry = Entry(
      accountId: accountId,
      itemId: 'new-$n',
      itemHmac: 'hmac-new-$n',
      title: title,
      body: body,
      task: task,
      links: links,
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
      task: old.task,
      links: old.links,
      versionId: '${old.versionId}+',
      updatedAt: old.updatedAt,
    );
    _changes.add(null);
  }

  @override
  Future<void> setTask(String accountId, String itemId, EntryTask? task) async {
    taskUpdates.add((accountId: accountId, itemId: itemId, task: task));
    final i = _entries.indexWhere((e) => e.itemId == itemId);
    final old = _entries[i];
    _entries[i] = Entry(
      accountId: old.accountId,
      itemId: old.itemId,
      itemHmac: old.itemHmac,
      title: old.title,
      body: old.body,
      tags: old.tags,
      task: task,
      links: old.links,
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

/// A key lifecycle that only reports a [fixed] status (or one per account).
class FixedStatusKeyService implements EncryptedKeyService {
  FixedStatusKeyService(this.fixed, {this.byAccount = const {}});

  final PersonalDataStatus fixed;

  /// Overrides [fixed] per account.
  final Map<String, PersonalDataStatus> byAccount;

  @override
  Stream<PersonalDataStatus> watchStatus(String accountId) =>
      Stream.value(byAccount[accountId] ?? fixed);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Entry testEntry(
  String itemId, {
  String? title,
  String body = '',
  bool conflict = false,
  int minute = 0,
  EntryTask? task,
  String accountId = 'acc-1',
}) =>
    Entry(
      accountId: accountId,
      itemId: itemId,
      itemHmac: 'hmac-$itemId',
      title: title,
      body: body,
      versionId: 'v-$itemId',
      updatedAt: DateTime.utc(2026, 11, 23, 10, minute),
      hasConflict: conflict,
      task: task,
    );

/// A [MailObjectStore] serving the versions of items in conflict (#1374);
/// records [resolve] and [keepAll] and then drops the item.
class FakeConflictStore implements MailObjectStore {
  FakeConflictStore(this.items);

  /// The items by item HMAC.
  final Map<String, MailObjectItem> items;
  final resolved = <({String itemHmac, Hlc keep})>[];
  final keptAll = <({String itemHmac, Hlc keep})>[];

  /// Thrown by the next [resolve] or [keepAll], if set.
  Object? failWith;

  @override
  Future<MailObjectItem?> item(String accountId, String itemHmac) async =>
      items[itemHmac];

  @override
  Future<HlcClock> clockFor(String accountId) async => HlcClock('devA');

  @override
  Stream<List<ConflictItem>> observeConflicts(String accountId) =>
      Stream.value([
        for (final MapEntry(:key, :value) in items.entries)
          ConflictItem(
            accountId: accountId,
            itemHmac: key,
            kind: value.display.head.kind,
            displayVersionId: value.display.head.versionId.encode(),
          ),
      ]);

  @override
  Future<MailObject> resolve(
    String accountId,
    String itemHmac, {
    required Hlc keep,
  }) async {
    _fail();
    resolved.add((itemHmac: itemHmac, keep: keep));
    items.remove(itemHmac);
    return MailObject(
      accountId: accountId,
      folder: MailObjectFolder.data,
      messageId: '<resolved@x>',
    );
  }

  @override
  Future<void> keepAll(
    String accountId,
    String itemHmac, {
    required Hlc keep,
  }) async {
    _fail();
    keptAll.add((itemHmac: itemHmac, keep: keep));
    items.remove(itemHmac);
  }

  void _fail() {
    final e = failWith;
    failWith = null;
    if (e != null) throw e;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A version of entry `item-1` by [device] at minute [minute].
InnerObject entryVersion(
  String device,
  int minute, {
  String body = '',
  String? title,
  bool deleted = false,
}) =>
    InnerObject(
      head: ObjectHead(
        itemId: 'item-1',
        collectionId: personalCollectionId,
        versionId: Hlc(
          DateTime.utc(2026, 11, 23, 10, minute).millisecondsSinceEpoch,
          0,
          device,
        ),
        deleted: deleted,
        kind: entryKind,
        extra: {if (title != null) 'title': title},
      ),
      parts: [
        if (!deleted)
          ObjectPart(
            contentType: 'text/markdown; charset=utf-8',
            bytes: Uint8List.fromList(utf8.encode(body)),
          ),
      ],
    );

/// The item whose heads are [versions], each of different content.
MailObjectItem conflictItemOf(List<InnerObject> versions) {
  final merge = mergeItem(
    known: [
      for (final (i, v) in versions.indexed)
        ObjectVersion(
          versionId: v.head.versionId,
          deleted: v.head.deleted,
          contentDigest: 'digest-$i',
          ref: i,
        ),
    ],
    incoming: const [],
    vv: const {},
  );
  return MailObjectItem(
    merge: merge,
    display: versions[merge.display!.ref! as int],
    versions: [for (final h in merge.distinctHeads) versions[h.ref! as int]],
  );
}

/// Pumps the app on the entries screen with personal data unlocked, backed by
/// [repo] and [store], and waits for it to settle.
Future<void> pumpEntriesApp(
  WidgetTester tester, {
  required EntryRepository repo,
  required MailObjectStore store,
}) async {
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/entries',
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: true),
      overrides: [
        ...baseOverrides(accounts: [kTestAccount]),
        encryptedKeyServiceProvider.overrideWithValue(
          FixedStatusKeyService(PersonalDataStatus.unlocked),
        ),
        entryRepositoryProvider.overrideWithValue(repo),
        mailObjectStoreProvider.overrideWithValue(store),
      ],
    ),
  );
  await tester.pumpAndSettle();
}
