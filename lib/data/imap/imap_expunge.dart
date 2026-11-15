import 'package:enough_mail/enough_mail.dart' as imap;

/// Flags [uids] of the selected folder `\Deleted` and expunges exactly them.
///
/// `UID EXPUNGE` needs UIDPLUS (RFC 4315). Without it a plain `EXPUNGE`
/// removes every `\Deleted` message in the folder, including ones another
/// client flagged and has not expunged yet (that client may still undelete
/// them). So, as RFC 4315 §1 suggests, those others lose the flag for the
/// `EXPUNGE` and get it back afterwards. A message another client flags
/// between our `SEARCH` and `EXPUNGE` would still go; the window is one
/// round trip.
Future<void> deleteAndExpungeUids(
  imap.ImapClient client,
  List<int> uids,
) async {
  final seq = imap.MessageSequence.fromIds(uids, isUid: true);
  await client.uidMarkDeleted(seq);
  if (client.serverInfo.supportsUidPlus) {
    await client.uidExpunge(seq);
    return;
  }
  final flagged = await client.uidSearchMessages(searchCriteria: 'DELETED');
  final found = flagged.matchingSequence;
  final others = found == null || found.isNil || found.isEmpty
      ? const <int>[]
      : found.toList().where((uid) => !uids.contains(uid)).toList();
  if (others.isEmpty) {
    await client.expunge();
    return;
  }
  final othersSeq = imap.MessageSequence.fromIds(others, isUid: true);
  await client.uidMarkUndeleted(othersSeq);
  try {
    await client.expunge();
  } catch (_) {
    await _restoreDeleted(client, othersSeq);
    rethrow;
  }
  await client.uidMarkDeleted(othersSeq);
}

/// Best effort: the `EXPUNGE` already failed, keep its error.
Future<void> _restoreDeleted(
  imap.ImapClient client,
  imap.MessageSequence seq,
) async {
  try {
    await client.uidMarkDeleted(seq);
  } catch (_) {}
}
