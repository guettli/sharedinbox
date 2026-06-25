import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/mailto_parser.dart';
import 'package:sharedinbox/data/intents/mail_intent_handler.dart';

void main() {
  group('parseMailto', () {
    test('returns null for non-mailto URI', () {
      expect(parseMailto(Uri.parse('https://example.com')), isNull);
    });

    test('extracts the recipient from the path', () {
      final fields = parseMailto(Uri.parse('mailto:alice@example.com'))!;
      expect(fields.to, 'alice@example.com');
      expect(fields.cc, isNull);
      expect(fields.subject, isNull);
      expect(fields.body, isNull);
    });

    test('extracts subject and body from the query string', () {
      final fields = parseMailto(
        Uri.parse('mailto:a@b?subject=Hi%20there&body=Line1%0ALine2'),
      )!;
      expect(fields.to, 'a@b');
      expect(fields.subject, 'Hi there');
      expect(fields.body, 'Line1\nLine2');
    });

    test('extracts cc and bcc', () {
      final fields = parseMailto(
        Uri.parse('mailto:a@b?cc=c@d&bcc=e@f'),
      )!;
      expect(fields.to, 'a@b');
      expect(fields.cc, 'c@d');
      expect(fields.bcc, 'e@f');
    });

    test('joins multiple cc values with a comma', () {
      final fields = parseMailto(
        Uri.parse('mailto:a@b?cc=c@d&cc=e@f'),
      )!;
      expect(fields.cc, 'c@d, e@f');
    });

    test('treats query keys case-insensitively', () {
      final fields = parseMailto(
        Uri.parse('mailto:a@b?Subject=Hello&BODY=Body'),
      )!;
      expect(fields.subject, 'Hello');
      expect(fields.body, 'Body');
    });

    test('ignores unknown query keys', () {
      final fields = parseMailto(
        Uri.parse('mailto:a@b?in-reply-to=x&subject=S'),
      )!;
      expect(fields.subject, 'S');
    });

    test('returns null path when mailto has no recipient', () {
      final fields = parseMailto(Uri.parse('mailto:?subject=Hello'))!;
      expect(fields.to, isNull);
      expect(fields.subject, 'Hello');
    });
  });

  group('mailIntentFromMailtoString', () {
    test('produces a MailIntent with the expected fields', () {
      final intent = mailIntentFromMailtoString(
        'mailto:a@b?cc=c@d&subject=Hi%20there&body=Line1%0ALine2',
      )!;
      expect(intent.to, 'a@b');
      expect(intent.cc, 'c@d');
      expect(intent.subject, 'Hi there');
      expect(intent.body, 'Line1\nLine2');
    });

    test('returns null for an http URI', () {
      expect(mailIntentFromMailtoString('https://example.com'), isNull);
    });
  });

  group('MailIntent.toComposeExtra', () {
    test('omits null fields so existing prefill semantics are preserved', () {
      const intent = MailIntent(to: 'a@b', subject: 'S');
      expect(
          intent.toComposeExtra(), {'prefillTo': 'a@b', 'prefillSubject': 'S'});
    });

    test('includes every populated field', () {
      const intent = MailIntent(
        to: 'a@b',
        cc: 'c@d',
        subject: 'S',
        body: 'B',
      );
      expect(intent.toComposeExtra(), {
        'prefillTo': 'a@b',
        'prefillCc': 'c@d',
        'prefillSubject': 'S',
        'prefillBody': 'B',
      });
    });
  });

  group('MailIntent.fromMap', () {
    test('returns null when every field is empty', () {
      expect(MailIntent.fromMap({}), isNull);
      expect(
        MailIntent.fromMap({'to': null, 'attachmentPaths': <String>[]}),
        isNull,
      );
    });

    test('reads attachment paths', () {
      final intent = MailIntent.fromMap({
        'attachmentPaths': ['/tmp/a.png', '/tmp/b.pdf'],
      })!;
      expect(intent.attachmentPaths, ['/tmp/a.png', '/tmp/b.pdf']);
    });
  });
}
