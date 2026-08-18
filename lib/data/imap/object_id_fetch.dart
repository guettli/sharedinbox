// ignore_for_file: implementation_imports
import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail/src/private/imap/command.dart';
import 'package:enough_mail/src/private/imap/imap_response.dart';
import 'package:enough_mail/src/private/imap/response_parser.dart';

import 'package:sharedinbox/data/imap/object_id.dart';

/// Fetches the move-stable server identifier ([ObjectIdKind]) for every UID in
/// [sequence], returning a `{uid: serverEmailId}` map. `enough_mail` has no
/// high-level support for the `EMAILID`/`X-GM-MSGID` FETCH items, so this
/// issues the raw `UID FETCH … (UID <item>)` command over the live connection
/// and parses the untagged responses with [_ObjectIdFetchParser].
typedef FetchObjectIdsFn = Future<Map<int, String>> Function(
  ImapClient client,
  MessageSequence sequence,
  ObjectIdKind kind,
);

/// Default [FetchObjectIdsFn] implementation used in production. Callers gate
/// this behind [resolveObjectIdKind] and treat any failure as "no ids"
/// (fail-closed), so a server that mishandles the request degrades to the
/// existing UID-based behaviour rather than breaking sync.
Future<Map<int, String>> fetchObjectIdsFromServer(
  ImapClient client,
  MessageSequence sequence,
  ObjectIdKind kind,
) {
  final buffer = StringBuffer('UID FETCH ');
  sequence.render(buffer);
  buffer
    ..write(' (UID ')
    ..write(kind.fetchItem)
    ..write(')');
  return client.sendCommand<Map<int, String>>(
    Command(buffer.toString()),
    _ObjectIdFetchParser(kind),
  );
}

class _ObjectIdFetchParser extends ResponseParser<Map<int, String>> {
  _ObjectIdFetchParser(this._kind);

  final ObjectIdKind _kind;
  final Map<int, String> _result = <int, String>{};

  @override
  Map<int, String>? parse(
    ImapResponse imapResponse,
    Response<Map<int, String>> response,
  ) =>
      _result;

  @override
  bool parseUntagged(
    ImapResponse imapResponse,
    Response<Map<int, String>>? response,
  ) {
    final line = imapResponse.first.line;
    if (line != null) {
      final entry = parseObjectIdLine(line, _kind);
      if (entry != null) {
        _result[entry.key] = entry.value;
        return true;
      }
    }
    return super.parseUntagged(imapResponse, response);
  }
}
