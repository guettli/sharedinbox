import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/data/imap/preview_snippet.dart';
import 'package:test/test.dart';

/// A single-part message as the sync fetch leaves it: BODYSTRUCTURE parsed, no
/// body. The snippet holds the whole body, so the message-level content type
/// describes it.
imap.MimeMessage _singlePart(String contentType, {String? encoding}) =>
    imap.MimeMessage()
      ..body = (imap.BodyPart()
        ..contentType = imap.ContentTypeHeader(contentType)
        ..encoding = encoding);

/// A multipart message as the sync fetch leaves it. The snippet holds body
/// part 1, so *its* content type is the one that must be used — the
/// message-level `multipart/alternative` would decode nothing.
imap.MimeMessage _multipart(String partContentType, {String? partEncoding}) {
  final body = imap.BodyPart()
    ..contentType = imap.ContentTypeHeader('multipart/alternative');
  body.addPart(
    imap.BodyPart()
      ..contentType = imap.ContentTypeHeader(partContentType)
      ..encoding = partEncoding,
  );
  body.addPart(
    imap.BodyPart()..contentType = imap.ContentTypeHeader('text/html'),
  );
  return imap.MimeMessage()..body = body;
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('previewFromSnippet (#680)', () {
    test('decodes the text part of a multipart message', () {
      // Modelled on Gmail INBOX UID 27025, the message whose FETCH response
      // first exposed the mis-parse: multipart/alternative, part 1 text/plain
      // charset UTF-8, 7bit. enough_mail reported its body as the partial-fetch
      // offset token `0>`.
      final preview = previewFromSnippet(
        _multipart('text/plain; charset="UTF-8"', partEncoding: '7bit'),
        _bytes('Speech error, see subject.\r\n'),
      );

      expect(preview, 'Speech error, see subject.');
      // The regression this guards: the offset token used to be stored as the
      // preview verbatim, where the backfill could never replace it.
      expect(preview, isNot('0>'));
    });

    test('strips markup when part 1 is html', () {
      expect(
        previewFromSnippet(
          _multipart('text/html; charset="UTF-8"'),
          _bytes('<p>Hello <b>world</b></p>'),
        ),
        'Hello world',
      );
    });

    test('decodes a single-part body using the message content type', () {
      expect(
        previewFromSnippet(
          _singlePart('text/plain; charset="UTF-8"'),
          _bytes('Line one.\r\nLine two.'),
        ),
        'Line one. Line two.',
      );
    });

    test('decodes quoted-printable using the BODYSTRUCTURE encoding', () {
      expect(
        previewFromSnippet(
          _singlePart(
            'text/plain; charset="UTF-8"',
            encoding: 'quoted-printable',
          ),
          _bytes('Gr=C3=BC=C3=9Fe aus Fu=C3=9F'),
        ),
        'Grüße aus Fuß',
      );
    });

    test('decodes non-ascii text in the part charset', () {
      expect(
        previewFromSnippet(
          _multipart('text/plain; charset="UTF-8"'),
          _bytes('Tägliche Übungen — im Überblick'),
        ),
        'Tägliche Übungen — im Überblick',
      );
    });

    test('handles a snippet truncated mid-way', () {
      expect(
        previewFromSnippet(
          _multipart('text/plain; charset="UTF-8"'),
          _bytes('The visible beginning of a very long mes'),
        ),
        'The visible beginning of a very long mes',
      );
    });

    test('returns null for an empty or missing snippet', () {
      final message = _singlePart('text/plain; charset="UTF-8"');

      expect(previewFromSnippet(message, null), isNull);
      expect(previewFromSnippet(message, Uint8List(0)), isNull);
      expect(previewFromSnippet(message, _bytes('\r\n')), isNull);
    });

    test('returns null when the message has no content type at all', () {
      expect(previewFromSnippet(imap.MimeMessage(), _bytes('body')), isNull);
    });
  });

  group('parsePreviewSnippetUid', () {
    test('reads the uid from an untagged FETCH line', () {
      expect(
        parsePreviewSnippetUid('* 2589 FETCH (UID 27025 BODY[1]<0> {215}'),
        27025,
      );
    });

    test('returns null for a line without a uid', () {
      expect(parsePreviewSnippetUid('* 2589 FETCH (FLAGS (\\Seen)'), isNull);
      expect(parsePreviewSnippetUid(')'), isNull);
    });
  });
}
