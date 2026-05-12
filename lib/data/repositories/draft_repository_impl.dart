import 'package:drift/drift.dart';

import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

class DraftRepositoryImpl implements DraftRepository {
  DraftRepositoryImpl(this._db);

  final AppDatabase _db;

  @override
  Future<SavedDraft> saveDraft({
    int? id,
    String? accountId,
    String? replyToEmailId,
    required String toText,
    required String ccText,
    required String subjectText,
    required String bodyText,
  }) async {
    final now = DateTime.now();
    if (id != null) {
      await (_db.update(_db.drafts)..where((t) => t.id.equals(id))).write(
        DraftsCompanion(
          accountId: Value(accountId),
          replyToEmailId: Value(replyToEmailId),
          toText: Value(toText),
          ccText: Value(ccText),
          subjectText: Value(subjectText),
          bodyText: Value(bodyText),
          updatedAt: Value(now),
        ),
      );
      return SavedDraft(
        id: id,
        accountId: accountId,
        replyToEmailId: replyToEmailId,
        toText: toText,
        ccText: ccText,
        subjectText: subjectText,
        bodyText: bodyText,
        updatedAt: now,
      );
    }

    final newId = await _db.into(_db.drafts).insert(
          DraftsCompanion.insert(
            accountId: Value(accountId),
            replyToEmailId: Value(replyToEmailId),
            toText: Value(toText),
            ccText: Value(ccText),
            subjectText: Value(subjectText),
            bodyText: Value(bodyText),
            updatedAt: now,
          ),
        );
    return SavedDraft(
      id: newId,
      accountId: accountId,
      replyToEmailId: replyToEmailId,
      toText: toText,
      ccText: ccText,
      subjectText: subjectText,
      bodyText: bodyText,
      updatedAt: now,
    );
  }

  @override
  Future<SavedDraft?> findDraft({String? replyToEmailId}) async {
    final query = _db.select(_db.drafts);
    if (replyToEmailId == null) {
      query.where((t) => t.replyToEmailId.isNull());
    } else {
      query.where((t) => t.replyToEmailId.equals(replyToEmailId));
    }
    query.orderBy([(t) => OrderingTerm.desc(t.id)]);
    query.limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<SavedDraft?> getDraft(int id) async {
    final row = await (_db.select(
      _db.drafts,
    )..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<void> deleteDraft(int id) async {
    await (_db.delete(_db.drafts)..where((t) => t.id.equals(id))).go();
  }

  SavedDraft _toModel(Draft row) => SavedDraft(
        id: row.id,
        accountId: row.accountId,
        replyToEmailId: row.replyToEmailId,
        toText: row.toText,
        ccText: row.ccText,
        subjectText: row.subjectText,
        bodyText: row.bodyText,
        updatedAt: row.updatedAt,
      );
}
