import 'package:sharedinbox/core/encrypted_objects/conflict_presenter.dart';
import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  test('an entry shows its title, its fields and its body', () {
    final presenter = presenterFor(entryKind);
    expect(presenter, isA<EntryConflictPresenter>());
    expect(presenter.kind, entryKind);
    final object = plannedEntryObject('item-1', hlcAt(1000));
    expect(presenter.title(object), 'Plan');
    expect(
      presenter.diffText(object),
      'Plan\n'
      'tags: work\n'
      'date: 2026-11-23\n'
      'task: {"done":false,"due":"2026-12-01"}\n'
      'links: <m1@example.com>\n'
      '\n'
      'old',
    );
  });

  test('an entry without a title takes the first line; a tombstone', () {
    const presenter = EntryConflictPresenter();
    final untitled = testObject(extra: const {}, body: '\nFirst\nsecond');
    expect(presenter.title(untitled), 'First');
    expect(presenter.title(testObject(extra: const {}, body: '')), '(empty)');
    final deleted = testObject(deleted: true);
    expect(presenter.title(deleted), '(deleted)');
    expect(presenter.diffText(deleted), '');
  });

  test('another kind shows its head JSON and text parts', () {
    final presenter = presenterFor('card');
    expect(presenter, isA<GenericConflictPresenter>());
    expect(presenter.kind, isNull);
    final object = testObject(extra: const {'front': 'Q'}, body: 'A');
    expect(presenter.title(object), 'entry item-1');
    final text = presenter.diffText(object);
    expect(text, contains('"front":"Q"'));
    expect(text, isNot(contains('versionId')));
    expect(text, endsWith('\n\nA'));
  });
}
