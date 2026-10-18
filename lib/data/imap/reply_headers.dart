import 'package:enough_mail/enough_mail.dart' as imap;

import 'package:sharedinbox/core/models/email.dart' as model;
import 'package:sharedinbox/core/utils/message_id_utils.dart';

/// Stamps `In-Reply-To` / `References` on a reply so the recipient's client
/// threads it under the message it answers. A no-op for a new message.
void addReplyHeaders(imap.MessageBuilder builder, model.EmailDraft draft) {
  final inReplyTo = draft.inReplyTo;
  if (inReplyTo == null) return;
  builder.addHeader('In-Reply-To', bracketMessageIds([inReplyTo]));
  if (draft.references.isEmpty) return;
  builder.addHeader('References', bracketMessageIds(draft.references));
}
