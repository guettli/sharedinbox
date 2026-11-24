import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/services/image_shrink_service.dart';
import 'package:sharedinbox/data/repositories/mail_object_blobs.dart';
import 'package:sharedinbox/di.dart';

import 'entries_fakes.dart';

Future<FakeEntryRepository> _pump(
  WidgetTester tester, {
  String body = 'old body',
  String? date,
  FakeConflictStore? store,
  List<Override> overrides = const [],
}) async {
  final repo = FakeEntryRepository([
    testEntry('e1', title: 'Old title', body: body, conflict: true, date: date),
  ]);
  await pumpEntriesApp(
    tester,
    repo: repo,
    store: store ?? FakeConflictStore({}),
    overrides: overrides,
  );
  await tester.tap(find.text('Old title'));
  await tester.pumpAndSettle();
  return repo;
}

/// Blobs in memory; [putBlob] throws [error] if set.
class _FakeBlobStore implements MailObjectBlobStore {
  _FakeBlobStore({this.error});

  final Object? error;
  final puts = <({String collectionId, Uint8List bytes, String type})>[];

  @override
  Future<String> putBlob(
    String accountId,
    String collectionId,
    Uint8List bytes,
    String contentType, {
    String? itemId,
  }) async {
    final e = error;
    if (e != null) throw e;
    puts.add((collectionId: collectionId, bytes: bytes, type: contentType));
    return 'img${puts.length}';
  }

  @override
  Future<({String contentType, Uint8List bytes})?> blob(
    String accountId,
    String collectionId,
    String itemId,
  ) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Offers no shrinking, so a picked image is inserted as it is.
class _NoShrink extends ImageShrinkService {
  const _NoShrink();

  @override
  bool isShrinkable(String contentType) => false;
}

final _pixels = Uint8List.fromList([1, 2, 3]);

List<Override> _imageOverrides(_FakeBlobStore blobs, String name) => [
      mailObjectBlobStoreProvider.overrideWithValue(blobs),
      imageShrinkServiceProvider.overrideWithValue(const _NoShrink()),
      pickImageFileProvider.overrideWithValue(
        () async => (path: '/tmp/$name', name: name, bytes: _pixels),
      ),
    ];

void main() {
  testWidgets('"Resolve…" opens the conflict view, then reloads',
      (tester) async {
    final store = FakeConflictStore({
      'hmac-e1': conflictItemOf([
        entryVersion('devA', 1, body: 'mine'),
        entryVersion('devB', 2, body: 'theirs'),
      ]),
    });
    await _pump(tester, store: store);
    await tester.tap(find.byKey(const Key('entryEditResolve')));
    await tester.pumpAndSettle();
    expect(find.text('Resolve conflict'), findsOneWidget);

    await tester.tap(find.byKey(const Key('conflictKeep_0')));
    await tester.pumpAndSettle();
    expect(store.resolved.single.itemHmac, 'hmac-e1');
    expect(find.text('Entry'), findsOneWidget);
    expect(find.byKey(const Key('entryEditConflict')), findsOneWidget);
  });

  testWidgets('edit saves title and body and goes back', (tester) async {
    final repo = await _pump(tester);
    expect(find.byKey(const Key('entryEditConflict')), findsOneWidget);
    expect(find.textContaining('old body', findRichText: true), findsWidgets);

    await tester.tap(find.byKey(const Key('entryEditPreviewToggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('entryEditTitle')), 'New');
    await tester.enterText(
      find.byKey(const Key('entryEditBody')),
      'line 1\nline 2',
    );
    await tester.tap(find.byKey(const Key('entryEditSave')));
    await tester.pumpAndSettle();

    expect(
      repo.updates.single,
      (itemId: 'e1', title: 'New', body: 'line 1\nline 2', date: null),
    );
    // Back on the list, which shows the saved entry.
    expect(find.byKey(const Key('entriesQuickAdd')), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
  });

  testWidgets('delete from the edit screen asks, then goes back',
      (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const Key('entryEditDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('entryDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(repo.entries, isEmpty);
    expect(find.text('No entries yet.'), findsOneWidget);
  });

  testWidgets('a non-empty body opens in the preview, toggles to the editor',
      (tester) async {
    await _pump(tester, body: '**bold**');
    expect(find.byKey(const Key('entryPreview')), findsOneWidget);
    expect(find.byKey(const Key('entryEditBody')), findsNothing);

    await tester.tap(find.byKey(const Key('entryEditPreviewToggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('entryPreview')), findsNothing);
    await tester.enterText(find.byKey(const Key('entryEditBody')), '# Typed');

    await tester.tap(find.byKey(const Key('entryEditPreviewToggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('entryEditBody')), findsNothing);
    final preview = find.byKey(const Key('entryPreview'));
    expect(
      find.descendant(
        of: preview,
        matching: find.textContaining('Typed', findRichText: true),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: preview,
        matching: find.textContaining('# Typed', findRichText: true),
      ),
      findsNothing,
    );
  });

  testWidgets('an empty body opens in the editor', (tester) async {
    await _pump(tester, body: '');
    expect(find.byKey(const Key('entryEditBody')), findsOneWidget);
    expect(find.byKey(const Key('entryPreview')), findsNothing);
  });

  testWidgets('ticking a checkbox saves a new version and stays',
      (tester) async {
    final repo = await _pump(tester, body: '- [ ] a\n- [x] b');
    final before = repo.entries.single.versionId;

    await tester.tap(find.byKey(const Key('entryTask_0')));
    await tester.pumpAndSettle();

    expect(repo.updates.single.body, '- [x] a\n- [x] b');
    expect(repo.updates.single.title, 'Old title');
    expect(repo.entries.single.versionId, isNot(before));
    expect(find.byKey(const Key('entryPreview')), findsOneWidget);
    expect(
      tester.widget<Checkbox>(find.byKey(const Key('entryTask_0'))).value,
      isTrue,
    );
  });

  testWidgets('a checkbox toggle includes pending edits', (tester) async {
    final repo = await _pump(tester, body: '- [ ] a');
    await tester.enterText(find.byKey(const Key('entryEditTitle')), 'Edited');
    await tester.tap(find.byKey(const Key('entryTask_0')));
    await tester.pumpAndSettle();
    expect(
      repo.updates.single,
      (itemId: 'e1', title: 'Edited', body: '- [x] a', date: null),
    );
  });

  testWidgets('the Todo switch adds a task, saved at once; off removes it',
      (tester) async {
    final repo = await _pump(tester);
    expect(find.byKey(const Key('entryDone')), findsNothing);

    await tester.tap(find.byKey(const Key('entryTodoSwitch')));
    await tester.pumpAndSettle();
    expect(repo.taskUpdates.single.task!.done, isFalse);
    expect(repo.entries.single.task, isNotNull);
    expect(find.byKey(const Key('entryDone')), findsOneWidget);
    expect(find.text('No due date'), findsOneWidget);

    await tester.tap(find.byKey(const Key('entryDone')));
    await tester.pumpAndSettle();
    expect(repo.taskUpdates.last.task!.done, isTrue);

    await tester.tap(find.byKey(const Key('entryTodoSwitch')));
    await tester.pumpAndSettle();
    expect(repo.taskUpdates.last.task, isNull);
    expect(find.byKey(const Key('entryDone')), findsNothing);
    // Title and body are not saved by it.
    expect(repo.updates, isEmpty);
  });

  testWidgets('the due date is picked and cleared', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const Key('entryTodoSwitch')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('entryDueDate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    final due = repo.taskUpdates.last.task!.due;
    expect(due, isoDate(DateTime.now()));
    expect(find.text('Due $due'), findsOneWidget);

    await tester.tap(find.byKey(const Key('entryDueDateClear')));
    await tester.pumpAndSettle();
    expect(repo.taskUpdates.last.task!.due, isNull);
    expect(find.text('No due date'), findsOneWidget);
  });

  group('journal date (#1358)', () {
    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('entryEditSave')));
      await tester.pumpAndSettle();
    }

    testWidgets('the chip shows the date; removing it saves no date',
        (tester) async {
      final repo = await _pump(tester, date: '2026-11-20');
      expect(
        find.descendant(
          of: find.byKey(const Key('entryEditDate')),
          matching: find.text('Fri, Nov 20, 2026'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('entryEditRemoveDate')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('entryEditDate')), findsNothing);
      expect(find.byKey(const Key('entryEditAddDate')), findsOneWidget);

      await save(tester);
      expect(repo.updates.single.date, isNull);
    });

    testWidgets('tapping the chip picks another day', (tester) async {
      final repo = await _pump(tester, date: '2026-11-20');
      await tester.tap(find.byKey(const Key('entryEditDate')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('23'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await save(tester);
      expect(repo.updates.single.date, '2026-11-23');
    });

    testWidgets('"Add to journal" then save passes the picked date',
        (tester) async {
      final repo = await _pump(tester);
      await tester.tap(find.byKey(const Key('entryEditAddDate')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('entryEditDate')), findsOneWidget);
      await save(tester);
      expect(repo.updates.single.date, isoDate(DateTime.now()));
    });
  });

  group('insert image (#1377)', () {
    Future<void> insert(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('entryEditInsertImage')));
      await tester.pumpAndSettle();
    }

    String body(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('entryEditBody')))
        .controller!
        .text;

    testWidgets('uploads the image as a blob and adds its line at the cursor',
        (tester) async {
      final blobs = _FakeBlobStore();
      final repo = await _pump(
        tester,
        body: 'ab',
        overrides: _imageOverrides(blobs, 'p.png'),
      );
      await tester.tap(find.byKey(const Key('entryEditPreviewToggle')));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('entryEditBody'));
      tester.widget<TextField>(field).controller!.selection =
          const TextSelection.collapsed(offset: 1);

      await insert(tester);
      expect(blobs.puts.single.collectionId, 'personal');
      expect(blobs.puts.single.bytes, _pixels);
      expect(blobs.puts.single.type, 'image/png');
      expect(body(tester), 'a\n![](si-img:img1)\nb');

      await tester.tap(find.byKey(const Key('entryEditSave')));
      await tester.pumpAndSettle();
      expect(repo.updates.single.body, 'a\n![](si-img:img1)\nb');
    });

    testWidgets('in the preview the image is appended and the editor opens',
        (tester) async {
      final blobs = _FakeBlobStore();
      await _pump(tester, overrides: _imageOverrides(blobs, 'p.png'));
      expect(find.byKey(const Key('entryPreview')), findsOneWidget);

      await insert(tester);
      expect(body(tester), 'old body\n![](si-img:img1)\n');
    });

    testWidgets('an image over the size limit shows the limit, body unchanged',
        (tester) async {
      final blobs = _FakeBlobStore(
        error: const ObjectTooLargeException(9 * 1024 * 1024, 8 << 20),
      );
      await _pump(tester, overrides: _imageOverrides(blobs, 'p.png'));
      await insert(tester);
      expect(
        find.text(
          'Image is 9.0 MiB after shrinking; the limit is 8.0 MiB. '
          'Shrink it more and try again.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('entryEditPreviewToggle')));
      await tester.pumpAndSettle();
      expect(body(tester), 'old body');
    });

    testWidgets('a picture that is not a photo is refused', (tester) async {
      final blobs = _FakeBlobStore();
      await _pump(tester, overrides: _imageOverrides(blobs, 'logo.svg'));
      await insert(tester);
      expect(
        find.text('Only photos and pictures can be inserted.'),
        findsOneWidget,
      );
      expect(blobs.puts, isEmpty);
    });
  });
}
