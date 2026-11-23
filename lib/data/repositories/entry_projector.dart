import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Writes the `Entries` projection of the `entry` documents (#1373). Runs
/// inside the store's merge transaction ([ObjectProjector]).
class EntryProjector implements ObjectProjector {
  EntryProjector(this.db);

  final AppDatabase db;

  @override
  String get kind => entryKind;

  @override
  Future<void> apply(
    String accountId,
    String itemHmac,
    InnerObject? display, {
    required bool conflict,
  }) async {
    final entry = display == null
        ? null
        : entryFromObject(
            display,
            accountId: accountId,
            itemHmac: itemHmac,
            conflict: conflict,
          );
    if (entry == null) {
      await (db.delete(db.entries)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.itemHmac.equals(itemHmac),
            ))
          .go();
      return;
    }
    await db.into(db.entries).insertOnConflictUpdate(
          EntriesCompanion.insert(
            accountId: accountId,
            itemId: entry.itemId,
            itemHmac: itemHmac,
            title: Value(entry.title),
            body: entry.body,
            tagsJson: Value(jsonEncode(entry.tags)),
            date: Value(entry.date),
            taskJson: Value(
              entry.task == null ? null : jsonEncode(entry.task!.toJson()),
            ),
            linksJson: Value(jsonEncode(entry.links)),
            versionId: entry.versionId,
            updatedAt: entry.updatedAt.millisecondsSinceEpoch,
            hasConflict: Value(entry.hasConflict),
          ),
        );
  }
}
