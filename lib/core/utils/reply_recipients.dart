import 'package:sharedinbox/core/models/email.dart';

/// A default reply recipient and whether it belongs in the Cc field.
typedef ReplyRecipient = ({EmailAddress address, bool isCc});

/// Computes the default reply recipients for an email with [from]/[to]/[cc],
/// excluding the account's own [ownEmail] and de-duplicating by address
/// (case-insensitively). Senders/To land in the To field; original Cc stays Cc.
///
/// A non-empty [replyTo] (RFC 5322 Reply-To) replaces [from] as the reply
/// target (#919). [from] is used instead when Reply-To is absent or only names
/// the account's own address.
///
/// When every address was the account's own — a note-to-self — this falls back
/// to the original sender, so a reply is never left with no recipient (an empty
/// To field).
List<ReplyRecipient> replyRecipients({
  required String ownEmail,
  required List<EmailAddress> from,
  required List<EmailAddress> to,
  required List<EmailAddress> cc,
  List<EmailAddress> replyTo = const [],
}) {
  final own = ownEmail.toLowerCase();
  final seen = <String>{};
  final out = <ReplyRecipient>[];

  void add(EmailAddress addr, {required bool isCc}) {
    final key = addr.email.toLowerCase();
    if (key == own || !seen.add(key)) return;
    out.add((address: addr, isCc: isCc));
  }

  for (final a in replyTo) {
    add(a, isCc: false);
  }
  if (out.isEmpty) {
    for (final a in from) {
      add(a, isCc: false);
    }
  }
  for (final a in to) {
    add(a, isCc: false);
  }
  for (final a in cc) {
    add(a, isCc: true);
  }

  if (out.isEmpty && from.isNotEmpty) {
    out.add((address: from.first, isCc: false));
  }
  return out;
}
