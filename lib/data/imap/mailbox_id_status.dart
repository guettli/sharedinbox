// ignore_for_file: implementation_imports
import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail/src/private/imap/command.dart';
import 'package:enough_mail/src/private/imap/imap_response.dart';
import 'package:enough_mail/src/private/imap/response_parser.dart';

/// What a `STATUS` of one folder answered, with its RFC 8474 `MAILBOXID`.
typedef ImapFolderStatus = ({
  int messages,
  int unseen,
  int? uidValidity,
  String? mailboxId,
});

/// Asks `STATUS` of [box] for [flags] plus `MAILBOXID` (RFC 8474), the
/// server's id of the folder that a rename keeps (#1315). Only for a
/// server that advertises it ([supportsMailboxIds]).
typedef StatusWithMailboxIdFn = Future<ImapFolderStatus> Function(
  ImapClient client,
  Mailbox box,
  List<StatusFlags> flags,
);

/// Whether the server of [serverInfo] gives folder ids (RFC 8474
/// `OBJECTID`: `STATUS … (MAILBOXID)`).
bool supportsMailboxIds(ImapServerInfo serverInfo) =>
    serverInfo.supports('OBJECTID');

/// Default [StatusWithMailboxIdFn]. `enough_mail` neither asks for nor
/// parses `MAILBOXID` (its STATUS parser throws on the parenthesised
/// value), so this sends the raw command over the live connection and
/// reads the untagged `STATUS` answer itself ([parseStatusLine]). A tagged
/// `NO` throws an [ImapException] like `statusMailbox` does.
Future<ImapFolderStatus> statusWithMailboxIdFromServer(
  ImapClient client,
  Mailbox box,
  List<StatusFlags> flags,
) {
  final items = [for (final flag in flags) _statusItem(flag), 'MAILBOXID'];
  return client.sendCommand<ImapFolderStatus>(
    Command(
      'STATUS "${box.encodedPath}" (${items.join(' ')})',
      writeTimeout: client.defaultWriteTimeout,
      responseTimeout: client.defaultResponseTimeout,
    ),
    _StatusParser(),
  );
}

String _statusItem(StatusFlags flag) => switch (flag) {
      StatusFlags.messages => 'MESSAGES',
      StatusFlags.recent => 'RECENT',
      StatusFlags.uidNext => 'UIDNEXT',
      StatusFlags.uidValidity => 'UIDVALIDITY',
      StatusFlags.unseen => 'UNSEEN',
      StatusFlags.highestModSequence => 'HIGHESTMODSEQ',
    };

final RegExp _numberItem = RegExp(r'\b(MESSAGES|UNSEEN|UIDVALIDITY)\s+(\d+)');
final RegExp _mailboxIdItem = RegExp(r'\bMAILBOXID\s+\(([^()\s]+)\)');

/// The status an untagged `STATUS` response [text] (without the leading
/// `* `, e.g. `STATUS "Work" (MESSAGES 2 MAILBOXID (F12))`) gives, or null
/// when it is no `STATUS` response. Only its last parenthesised list is
/// read, so a folder name that looks like an item does not count.
ImapFolderStatus? parseStatusLine(String text) {
  if (!text.startsWith('STATUS ')) return null;
  final trimmed = text.trimRight();
  if (!trimmed.endsWith(')')) return null;
  var depth = 0;
  var start = -1;
  for (var i = trimmed.length - 1; i >= 0; i--) {
    final c = trimmed[i];
    if (c == ')') depth++;
    if (c == '(') depth--;
    if (depth == 0) {
      start = i;
      break;
    }
  }
  if (start < 0) return null;
  final items = trimmed.substring(start);
  final numbers = {
    for (final m in _numberItem.allMatches(items))
      m.group(1)!: int.parse(m.group(2)!),
  };
  return (
    messages: numbers['MESSAGES'] ?? 0,
    unseen: numbers['UNSEEN'] ?? 0,
    uidValidity: numbers['UIDVALIDITY'],
    mailboxId: _mailboxIdItem.firstMatch(items)?.group(1),
  );
}

class _StatusParser extends ResponseParser<ImapFolderStatus> {
  ImapFolderStatus? _status;

  @override
  ImapFolderStatus? parse(
    ImapResponse imapResponse,
    Response<ImapFolderStatus> response,
  ) =>
      response.isOkStatus
          ? _status ??
              (messages: 0, unseen: 0, uidValidity: null, mailboxId: null)
          : null;

  @override
  bool parseUntagged(
    ImapResponse imapResponse,
    Response<ImapFolderStatus>? response,
  ) {
    final status = parseStatusLine(imapResponse.parseText);
    if (status != null && _status == null) {
      _status = status;
      return true;
    }
    return super.parseUntagged(imapResponse, response);
  }
}
