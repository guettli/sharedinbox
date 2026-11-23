// ignore_for_file: implementation_imports
import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail/src/private/imap/command.dart';
import 'package:enough_mail/src/private/imap/imap_response.dart';
import 'package:enough_mail/src/private/imap/response_parser.dart';

/// Asks the server for its personal NAMESPACE prefix (RFC 2342), e.g.
/// `INBOX.`; `''` when it has none. Only for a server that advertises the
/// `NAMESPACE` capability.
typedef ImapNamespaceFn = Future<String> Function(ImapClient client);

/// Default [ImapNamespaceFn]. `enough_mail` has no NAMESPACE command, so
/// this sends the raw command and reads the untagged answer
/// ([parsePersonalNamespace]).
Future<String> imapNamespaceFromServer(ImapClient client) =>
    client.sendCommand<String>(
      Command(
        'NAMESPACE',
        writeTimeout: client.defaultWriteTimeout,
        responseTimeout: client.defaultResponseTimeout,
      ),
      _NamespaceParser(),
    );

final _personal = RegExp(
  r'^NAMESPACE\s+\(\(\s*"((?:[^"\\]|\\.)*)"',
  caseSensitive: false,
);
final _namespaceWord = RegExp(r'^NAMESPACE\s', caseSensitive: false);

/// The prefix of the first personal namespace of an untagged `NAMESPACE`
/// answer [text] (without the leading `* `), e.g. `NAMESPACE (("INBOX."
/// ".")) NIL NIL` → `INBOX.`; `''` when the personal namespace is `NIL`;
/// null when [text] is no `NAMESPACE` answer.
String? parsePersonalNamespace(String text) {
  final trimmed = text.startsWith('* ') ? text.substring(2) : text;
  if (!_namespaceWord.hasMatch(trimmed)) return null;
  final match = _personal.firstMatch(trimmed);
  if (match == null) return '';
  return match.group(1)!.replaceAllMapped(
        RegExp(r'\\(.)'),
        (m) => m.group(1)!,
      );
}

class _NamespaceParser extends ResponseParser<String> {
  String? _prefix;

  @override
  String? parse(ImapResponse imapResponse, Response<String> response) =>
      response.isOkStatus ? _prefix ?? '' : null;

  @override
  bool parseUntagged(ImapResponse imapResponse, Response<String>? response) {
    final prefix = parsePersonalNamespace(imapResponse.parseText);
    if (prefix != null) {
      _prefix ??= prefix;
      return true;
    }
    return super.parseUntagged(imapResponse, response);
  }
}
