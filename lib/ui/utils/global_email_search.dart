import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';

/// Runs the standard account-wide (or single-account) simple search and merges
/// its two result sources into one list, flagged first then newest first.
///
/// `searchEmailsGlobal` matches subject, preview and From via FTS;
/// `getEmailsByAddress` catches recipients (To/Cc) that FTS does not index.
/// Both queries run in parallel, then results are deduplicated by id, sorted
/// by [compareFlaggedThenNewest] and capped at [limit].
///
/// Each source returns its own first [limit] rows in that same order, so the
/// first [limit] of the merge are exactly the first [limit] of the full union:
/// re-running with a larger [limit] ("Load more") only appends, never
/// reorders or skips. A result of exactly [limit] entries means more matches
/// may exist.
///
/// Shared by the global search screen and by broadening a folder search to all
/// folders, so both paths behave identically.
Future<List<Email>> searchEmailsGlobalMerged(
  EmailRepository repo,
  String? accountId,
  String query, {
  int limit = searchPageSize,
}) async {
  final (globalHits, addressHits) = await (
    repo.searchEmailsGlobal(accountId, query, limit: limit),
    repo.getEmailsByAddress(accountId, query, limit: limit),
  ).wait;

  final seen = <String>{};
  final merged = <Email>[];
  for (final e in [...globalHits, ...addressHits]) {
    if (seen.add(e.id)) merged.add(e);
  }
  merged.sort(compareFlaggedThenNewest);
  return merged.length > limit ? merged.sublist(0, limit) : merged;
}
