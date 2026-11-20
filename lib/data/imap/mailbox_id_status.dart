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
/// reads the untagged `STATUS` answer of [box] itself ([parseStatusLine]).
/// A tagged `NO` or `BAD`, and an `OK` without a `STATUS` answer for the
/// folder, throw an [ImapException]: the caller then asks a plain
/// `STATUS`, and never takes a missing answer for an empty folder.
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
    _StatusParser(box.encodedPath),
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

// Status items are case-insensitive (RFC 3501 §9: "case-insensitive").
final RegExp _numberItem = RegExp(
  r'\b(MESSAGES|UNSEEN|UIDVALIDITY)\s+(\d+)',
  caseSensitive: false,
);
final RegExp _mailboxIdItem = RegExp(
  r'\bMAILBOXID\s+\(([^()\s]+)\)',
  caseSensitive: false,
);
final RegExp _statusWord = RegExp(r'^STATUS\s', caseSensitive: false);

/// One untagged `STATUS` answer: the folder it names ([mailbox]; null when
/// it came as a literal, which this does not read) and what it says.
typedef StatusLine = ({String? mailbox, ImapFolderStatus status});

/// The answer an untagged `STATUS` response [text] (without the leading
/// `* `, e.g. `STATUS "Work" (MESSAGES 2 MAILBOXID (F12))`) gives, or null
/// when it is no `STATUS` response. Only its last parenthesised list is
/// read, so a folder name that looks like an item does not count. Items
/// are matched whatever their case.
StatusLine? parseStatusLine(String text) {
  if (!_statusWord.hasMatch(text)) return null;
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
      m.group(1)!.toUpperCase(): int.parse(m.group(2)!),
  };
  return (
    mailbox: _mailboxName(trimmed.substring(7, start).trim()),
    status: (
      messages: numbers['MESSAGES'] ?? 0,
      unseen: numbers['UNSEEN'] ?? 0,
      uidValidity: numbers['UIDVALIDITY'],
      mailboxId: _mailboxIdItem.firstMatch(items)?.group(1),
    ),
  );
}

/// The folder name of a `STATUS` answer: an atom or a quoted string;
/// null for a literal (`{n}`), which is not read here.
String? _mailboxName(String raw) {
  if (raw.isEmpty || raw.startsWith('{')) return null;
  if (!raw.startsWith('"') || !raw.endsWith('"') || raw.length < 2) {
    return raw;
  }
  final out = StringBuffer();
  final inner = raw.substring(1, raw.length - 1);
  for (var i = 0; i < inner.length; i++) {
    final c = inner[i];
    if (c == r'\' && i + 1 < inner.length) {
      out.write(inner[++i]);
    } else {
      out.write(c);
    }
  }
  return out.toString();
}

/// Whether a `STATUS` answer naming [named] (null: unknown) is the one
/// asked for [path]. INBOX is case-insensitive (RFC 3501 §5.1).
bool _isFor(String? named, String path) =>
    named == null ||
    named == path ||
    (path.toUpperCase() == 'INBOX' && named.toUpperCase() == 'INBOX');

/// The text of an untagged response without its `* `, with a literal (a
/// folder name sent as `{n}`) put back as a quoted string: enough_mail's
/// `parseText` drops the space before it and its quotes.
String _textOf(ImapResponse response) {
  final out = StringBuffer();
  var literal = false;
  for (final line in response.lines) {
    final text = line.line ?? '';
    if (literal) {
      out
        ..write(' "')
        ..write(text.replaceAll(r'\', r'\\').replaceAll('"', r'\"'))
        ..write('"');
    } else {
      out.write(text);
    }
    literal = line.isWithLiteral;
  }
  final text = out.toString();
  return text.startsWith('* ') ? text.substring(2) : text;
}

class _StatusParser extends ResponseParser<ImapFolderStatus> {
  _StatusParser(this._path);

  final String _path;
  ImapFolderStatus? _status;

  @override
  ImapFolderStatus? parse(
    ImapResponse imapResponse,
    Response<ImapFolderStatus> response,
  ) {
    if (!response.isOkStatus) return null;
    final status = _status;
    if (status == null) {
      // OK without an answer: unknown, not an empty folder.
      response
        ..status = ResponseStatus.no
        ..details = 'STATUS answered OK without a STATUS response for '
            '"$_path"';
    }
    return status;
  }

  @override
  bool parseUntagged(
    ImapResponse imapResponse,
    Response<ImapFolderStatus>? response,
  ) {
    final line = parseStatusLine(_textOf(imapResponse));
    if (line != null) {
      // Another folder's STATUS (unsolicited) is not this answer.
      if (_status == null && _isFor(line.mailbox, _path)) {
        _status = line.status;
      }
      return true;
    }
    return super.parseUntagged(imapResponse, response);
  }
}
