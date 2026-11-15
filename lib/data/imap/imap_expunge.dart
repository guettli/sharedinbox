import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/data/imap/imap_errors.dart';

/// Flags [uids] of the selected folder `\Deleted` and expunges exactly them.
///
/// `UID EXPUNGE` needs UIDPLUS (RFC 4315). Without it a plain `EXPUNGE`
/// removes every `\Deleted` message in the folder, including ones another
/// client flagged and has not expunged yet (that client may still undelete
/// them). So, as RFC 4315 §1 suggests, those others lose the flag for the
/// `EXPUNGE` and get it back afterwards. A message another client flags
/// between our `SEARCH` and `EXPUNGE` would still go; the window is one
/// round trip. If the connection drops between un-flagging and re-flagging,
/// the others stay un-flagged: they come back as normal mail, which loses
/// nothing but is not repaired later.
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
  } catch (e) {
    // On a dead connection the restore would only wait for its timeout.
    if (!isImapConnectionLost(e)) await _restoreDeleted(client, othersSeq);
    rethrow;
  }
  await _restoreDeleted(client, othersSeq);
}

/// Gives [seq] its `\Deleted` flag back. Best effort: our messages are
/// already expunged (or the `EXPUNGE` failed with an error worth keeping),
/// so only a lost connection is reported.
Future<void> _restoreDeleted(
  imap.ImapClient client,
  imap.MessageSequence seq,
) async {
  try {
    await client.uidMarkDeleted(seq);
  } catch (e) {
    if (isImapConnectionLost(e)) rethrow;
  }
}
