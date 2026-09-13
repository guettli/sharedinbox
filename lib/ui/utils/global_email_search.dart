import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';

/// Runs the standard account-wide (or single-account) simple search and merges
/// its two result sources into one newest-first list.
///
/// `searchEmailsGlobal` matches subject, preview and From via FTS;
/// `getEmailsByAddress` catches recipients (To/Cc) that FTS does not index.
/// Both queries run in parallel, then results are deduplicated by id and
/// sorted newest-first so a single message list surfaces every match.
///
/// Shared by the global search screen and by broadening a folder search to all
/// folders, so both paths behave identically.
Future<List<Email>> searchEmailsGlobalMerged(
  EmailRepository repo,
  String? accountId,
  String query,
) async {
  final (globalHits, addressHits) = await (
    repo.searchEmailsGlobal(accountId, query),
    repo.getEmailsByAddress(accountId, query),
  ).wait;

  final seen = <String>{};
  final merged = <Email>[];
  for (final e in [...globalHits, ...addressHits]) {
    if (seen.add(e.id)) merged.add(e);
  }
  merged.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
  return merged;
}
