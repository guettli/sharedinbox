import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';
import 'package:sharedinbox/data/repositories/review_compaction_filter.dart';

/// Compacts the `review` log (ENCRYPTED-OBJECTS.md §7, #1382), run right
/// after each flush of the pending reviews (`ReviewUploadScheduler`):
///
/// - more than [maxSegments] (30) uncovered own segments in the open month
///   compact it;
/// - a month before the open one with uncovered segments (own, or of a
///   device the [MailObjectLog.authority] lets this device adopt) gets its
///   final pack, or an extra pack for late segments;
/// - segments of an adoptable device (removed, or not seen for 90 days)
///   are adopted: their month is compacted with them.
///
/// The packs drop the events of cards with a synced tombstone
/// ([ReviewCompactionFilter]). One run per account at a time; without a
/// write key (locked) a run does nothing.
class ReviewCompactor {
  ReviewCompactor(
    this.log, {
    ReviewCompactionFilter? filter,
    this.maxSegments = 30,
  }) : filter = filter ?? ReviewCompactionFilter(log.db);

  final MailObjectLog log;
  final ReviewCompactionFilter filter;
  final int maxSegments;

  final Map<String, Future<void>> _tails = {};

  /// Compacts what is due in [accountId]. Returns the packs written.
  Future<List<MailObject>> maybeCompact(String accountId) {
    final run = (_tails[accountId] ?? Future<void>.value())
        .then((_) => _compact(accountId));
    _tails[accountId] = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<List<MailObject>> _compact(String accountId) async {
    final own = (await log.store.clockFor(accountId)).deviceId;
    final open = periodOfTime(log.now());
    // Of each month: the devices with uncovered segments and how many own.
    final devicesByPeriod = <String, Set<String>>{};
    final ownCount = <String, int>{};
    for (final row
        in await log.store.rowsOfKind(accountId, segKind(reviewLogName))) {
      final Hlc version;
      try {
        version = Hlc.parse(row.versionId!);
      } on FormatException {
        continue;
      }
      final period = periodOf(version);
      (devicesByPeriod[period] ??= {}).add(version.deviceId);
      if (version.deviceId == own) {
        ownCount[period] = (ownCount[period] ?? 0) + 1;
      }
    }
    final adoptable = <String>{};
    for (final d in {for (final ds in devicesByPeriod.values) ...ds}) {
      if (d != own && await log.authority.mayCompact(accountId, d)) {
        adoptable.add(d);
      }
    }
    final devices = {own, ...adoptable};
    final due = [
      for (final MapEntry(key: period, value: present)
          in devicesByPeriod.entries)
        if (present.any(devices.contains) &&
            (period.compareTo(open) < 0 ||
                (ownCount[period] ?? 0) > maxSegments ||
                present.any(adoptable.contains)))
          period,
    ]..sort();
    final packs = <MailObject>[];
    try {
      for (final period in due) {
        packs.addAll(
          await log.compact(
            accountId,
            reviewLogName,
            period,
            deviceIds: devices,
            keep: await filter.load(accountId),
          ),
        );
      }
    } on NoWriteKeyException {
      return packs;
    }
    return packs;
  }
}
