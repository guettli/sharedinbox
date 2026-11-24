import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/models/linked_note.dart';

Entry _entry(String itemId, {EntryTask? task}) => Entry(
      accountId: 'acc-1',
      itemId: itemId,
      itemHmac: 'hmac-$itemId',
      title: 'Invoice',
      links: const ['<m@x>'],
      task: task,
      versionId: 'v-$itemId',
      updatedAt: DateTime.utc(2026, 11, 24, 9),
    );

void main() {
  test('mergeLinkedNotes keeps the task of a todo entry', () async {
    final notes = await mergeLinkedNotes(
      '<m@x>',
      ['<m@x>'],
      [_entry('t1', task: const EntryTask(due: '2026-11-27'))],
      const [],
    );
    expect(notes.single.isEntry, isTrue);
    expect(notes.single.task?.due, '2026-11-27');
    expect(notes.single.task?.done, isFalse);
  });

  test('mergeLinkedNotes gives an entry that is no todo no task', () async {
    final notes = await mergeLinkedNotes(
      '<m@x>',
      ['<m@x>'],
      [_entry('n1')],
      const [],
    );
    expect(notes.single.task, isNull);
  });
}
