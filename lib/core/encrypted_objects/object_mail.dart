import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Outer RFC 5322 mail of an object (`ENCRYPTED-OBJECTS.md` 5.1, 5.6). IMAP
/// APPEND and JMAP upload + `Email/import` send the same bytes; the stores
/// set `\Seen`.

const objectMailSubject = 'SharedInbox item';
const objectMailSchema = '1';
const schemaHeader = 'X-SharedInbox-Schema';
const itemHeader = 'X-SharedInbox-Item';
const messageIdDomain = 'sharedinbox.invalid';

const objectMailNotice =
    'This mail holds encrypted SharedInbox data. Do not delete it.';

const _base32 = 'abcdefghijklmnopqrstuvwxyz234567';

/// RFC 4648 base32, lowercase, without padding.
String base32Lower(List<int> bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final b in bytes) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_base32[(buffer >> bits) & 31]);
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_base32[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

/// A new version Message-ID: `<base32(16 random bytes)@sharedinbox.invalid>`
/// (26 lowercase base32 chars). Chosen before upload and persisted.
String newMessageId({RandomBytes random = secureRandomBytes}) =>
    '<${base32Lower(random(idLength))}@$messageIdDomain>';

// The boundary cannot occur in the parts: the notice is fixed and base64
// has no `-`.
const _boundary = 'si-object-1';
const _crlf = '\r\n';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// RFC 5322 date in UTC, e.g. `Sun, 22 Nov 2026 10:00:00 +0000`.
String rfc5322Date(DateTime date) {
  final d = date.toUtc();
  return '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]} '
      '${d.year} ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)} +0000';
}

/// Builds the object mail. Hand-written, so the bytes depend only on the
/// arguments.
Uint8List buildObjectMail({
  required String messageId,
  required Uint8List itemHmac,
  required Uint8List blob,
  required DateTime date,
  String? from,
}) {
  final b64 = base64.encode(blob);
  final lines = [
    for (var i = 0; i < b64.length; i += 76)
      b64.substring(i, i + 76 < b64.length ? i + 76 : b64.length),
  ];
  final text = StringBuffer()
    ..write(from == null ? '' : 'From: $from$_crlf')
    ..write('Date: ${rfc5322Date(date)}$_crlf')
    ..write('Subject: $objectMailSubject$_crlf')
    ..write('Message-ID: $messageId$_crlf')
    ..write('MIME-Version: 1.0$_crlf')
    ..write('$schemaHeader: $objectMailSchema$_crlf')
    ..write('$itemHeader: ${b64url(itemHmac)}$_crlf')
    ..write('Content-Type: multipart/mixed; boundary="$_boundary"$_crlf')
    ..write(_crlf)
    ..write('--$_boundary$_crlf')
    ..write('Content-Type: text/plain; charset=us-ascii$_crlf')
    ..write('Content-Transfer-Encoding: 7bit$_crlf$_crlf')
    ..write('$objectMailNotice$_crlf')
    ..write('--$_boundary$_crlf')
    ..write('Content-Type: application/octet-stream$_crlf')
    ..write('Content-Transfer-Encoding: base64$_crlf$_crlf')
    ..writeAll(lines.map((l) => '$l$_crlf'))
    ..write('--$_boundary--$_crlf');
  return Uint8List.fromList(ascii.encode(text.toString()));
}

/// The parsed fields of an object mail.
class ObjectMail {
  const ObjectMail({
    required this.messageId,
    required this.schema,
    required this.itemHmac,
    required this.blob,
  });

  final String messageId;
  final String schema;
  final Uint8List itemHmac;
  final Uint8List blob;
}

/// Parses an object mail. Throws [FormatException] for a missing header, an
/// unknown schema or a missing `application/octet-stream` part.
ObjectMail parseObjectMail(Uint8List bytes) {
  final msg = MimeMessage.parseFromData(bytes);
  final schema = msg.getHeaderValue(schemaHeader)?.trim();
  if (schema == null) throw const FormatException('missing $schemaHeader');
  if (schema != objectMailSchema) {
    throw FormatException('unknown $schemaHeader', schema);
  }
  final item = msg.getHeaderValue(itemHeader)?.trim();
  if (item == null) throw const FormatException('missing $itemHeader');
  final Uint8List hmac;
  try {
    hmac = b64urlDecode(item);
  } on FormatException {
    throw const FormatException('$itemHeader is not base64url');
  }
  if (hmac.length != itemHmacLength) {
    throw const FormatException('$itemHeader must be 32 bytes');
  }
  final messageId = msg.getHeaderValue('Message-ID')?.trim();
  if (messageId == null) throw const FormatException('missing Message-ID');
  final blob = _octetStream(msg);
  if (blob == null) {
    throw const FormatException('missing application/octet-stream part');
  }
  return ObjectMail(
    messageId: messageId,
    schema: schema,
    itemHmac: hmac,
    blob: blob,
  );
}

Uint8List? _octetStream(MimePart part) {
  if (part.mediaType.text == 'application/octet-stream') {
    return part.decodeContentBinary();
  }
  for (final child in part.parts ?? const <MimePart>[]) {
    final found = _octetStream(child);
    if (found != null) return found;
  }
  return null;
}
