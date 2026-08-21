// ignore_for_file: implementation_imports
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail/src/private/imap/command.dart';
import 'package:enough_mail/src/private/imap/imap_response.dart';
import 'package:enough_mail/src/private/imap/response_parser.dart';

import 'package:sharedinbox/data/imap/preview_snippet.dart';

/// Fetches the leading [maxBytes] of every message's first body part in
/// [sequence], returning a `{uid: rawPartPrefix}` map for [previewFromSnippet].
///
/// Part 1 rather than the whole body: for a multipart message that is the
/// text/plain alternative (typically a couple of KB, and free of the multipart
/// boundaries and the HTML alternative), and for a single-part message it is
/// the body itself.
///
/// This has to bypass `enough_mail`'s own fetch: its response tokeniser splits
/// the partial-fetch suffix off the data item (`BODY[1]<0>` becomes `BODY[1]` +
/// `0>`), so the parser hands back the string `0>` as the message body and
/// drops the actual literal. Requesting the prefix with a raw
/// command and reading the literal ourselves sidesteps that — the same trick
/// already used for `EMAILID`/`X-GM-MSGID` in `object_id_fetch.dart`.
typedef FetchPreviewSnippetsFn = Future<Map<int, Uint8List>> Function(
  ImapClient client,
  MessageSequence sequence,
  int maxBytes,
);

/// Default [FetchPreviewSnippetsFn] used in production. Callers treat a failure
/// as "no snippets" (fail-open): a server that mishandles the partial fetch
/// costs previews at sync time, not the sync itself.
Future<Map<int, Uint8List>> fetchPreviewSnippetsFromServer(
  ImapClient client,
  MessageSequence sequence,
  int maxBytes,
) {
  final buffer = StringBuffer('UID FETCH ');
  sequence.render(buffer);
  buffer
    ..write(' (UID BODY.PEEK[1]<0.')
    ..write(maxBytes)
    ..write('>)');

  return client.sendCommand<Map<int, Uint8List>>(
    Command(buffer.toString()),
    _PreviewSnippetParser(),
  );
}

class _PreviewSnippetParser extends ResponseParser<Map<int, Uint8List>> {
  final Map<int, Uint8List> _result = <int, Uint8List>{};

  @override
  Map<int, Uint8List>? parse(
    ImapResponse imapResponse,
    Response<Map<int, Uint8List>> response,
  ) =>
      _result;

  @override
  bool parseUntagged(
    ImapResponse imapResponse,
    Response<Map<int, Uint8List>>? response,
  ) {
    final firstLine = imapResponse.first.line;
    final uid = firstLine == null ? null : parsePreviewSnippetUid(firstLine);
    if (uid != null) {
      final bytes = BytesBuilder(copy: false);
      // The literal arrives as its own line(s); the trailing `)` line and any
      // other text line is response syntax, not body content.
      for (final line in imapResponse.lines.skip(1)) {
        final data = line.rawData;
        if (data != null) bytes.add(data);
      }
      if (bytes.isNotEmpty) {
        _result[uid] = bytes.takeBytes();
        return true;
      }
    }
    return super.parseUntagged(imapResponse, response);
  }
}
