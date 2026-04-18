import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/repositories/draft_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  setUpAll(configureSqliteForTests);

  group('DraftRepositoryImpl', () {
    test('saveDraft creates a new row and returns it with a non-zero id',
        () async {
      final repo = DraftRepositoryImpl(openTestDatabase());
      final draft = await repo.saveDraft(
        toText: 'bob@example.com',
        ccText: '',
        subjectText: 'Hello',
        bodyText: 'Hi',
      );
      expect(draft.id, isNonZero);
      expect(draft.toText, 'bob@example.com');
      expect(draft.subjectText, 'Hello');
    });

    test('saveDraft with id updates existing row', () async {
      final repo = DraftRepositoryImpl(openTestDatabase());
      final created = await repo.saveDraft(
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'First',
        bodyText: '',
      );
      final updated = await repo.saveDraft(
        id: created.id,
        toText: 'b@example.com',
        ccText: '',
        subjectText: 'Updated',
        bodyText: 'body',
      );
      expect(updated.id, created.id);
      expect(updated.subjectText, 'Updated');

      final fetched = await repo.getDraft(created.id);
      expect(fetched?.subjectText, 'Updated');
    });

    test('getDraft returns null for unknown id', () async {
      final repo = DraftRepositoryImpl(openTestDatabase());
      expect(await repo.getDraft(99999), isNull);
    });

    test('findDraft returns null when no draft exists', () async {
      final repo = DraftRepositoryImpl(openTestDatabase());
      expect(await repo.findDraft(), isNull);
    });

    test('findDraft returns most recent draft for matching replyToEmailId',
        () async {
      final repo = DraftRepositoryImpl(openTestDatabase());
      await repo.saveDraft(
        replyToEmailId: 'email-1',
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'Older',
        bodyText: '',
      );
      final newer = await repo.saveDraft(
        replyToEmailId: 'email-1',
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'Newer',
        bodyText: 'body',
      );
      final found = await repo.findDraft(replyToEmailId: 'email-1');
      expect(found?.id, newer.id);
      expect(found?.subjectText, 'Newer');
    });

    test('findDraft with null replyToEmailId finds new-message drafts', () async {
      final repo = DraftRepositoryImpl(openTestDatabase());
      // This draft is a reply and should NOT be returned.
      await repo.saveDraft(
        replyToEmailId: 'email-1',
        toText: 'x@example.com',
        ccText: '',
        subjectText: 'Reply draft',
        bodyText: '',
      );
      final newMsg = await repo.saveDraft(
        toText: 'y@example.com',
        ccText: '',
        subjectText: 'New draft',
        bodyText: '',
      );
      final found = await repo.findDraft();
      expect(found?.id, newMsg.id);
    });

    test('deleteDraft removes the row', () async {
      final repo = DraftRepositoryImpl(openTestDatabase());
      final draft = await repo.saveDraft(
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'To delete',
        bodyText: '',
      );
      await repo.deleteDraft(draft.id);
      expect(await repo.getDraft(draft.id), isNull);
    });
  });
}
