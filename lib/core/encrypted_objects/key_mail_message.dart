import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';

import 'package:sharedinbox/core/encrypted_objects/collection_key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Outer RFC 5322 mail of a key mail and a collection-key mail in
/// `SharedInbox/Keys` (`ENCRYPTED-OBJECTS.md` 4.6).
///
/// `multipart/mixed` with a `text/plain` notice and the payload as a
/// `base64` `application/json` part. The MAC of an account-key mail travels
/// in that part's `X-SharedInbox-Key-Mac` header and covers the decoded
/// part bytes.

const keyMailSubject = 'SharedInbox key';
const keyKindHeader = 'X-SharedInbox-Key-Kind';
const keyMacHeader = 'X-SharedInbox-Key-Mac';

const keyMailNotice =
    'This mail holds an encrypted SharedInbox key. Do not delete it.';

// The boundary cannot occur in the parts: the notice is fixed and base64
// has no `-`.
const _boundary = 'si-key-1';
const _crlf = '\r\n';

/// A parsed mail of the keys folder.
sealed class ParsedKeyMail {
  const ParsedKeyMail(this.messageId);

  final String messageId;
}

final class AccountKeyMailMsg extends ParsedKeyMail {
  const AccountKeyMailMsg(super.messageId, this.mail);

  final SignedKeyMail mail;
}

final class CollectionKeyMailMsg extends ParsedKeyMail {
  const CollectionKeyMailMsg(super.messageId, this.mail);

  final CollectionKeyMail mail;
}

/// Builds the mail of an account key ([SignedKeyMail] and its MAC).
Uint8List buildKeyMail({
  required String messageId,
  required SignedKeyMail mail,
  required DateTime date,
}) =>
    _build(
      messageId: messageId,
      kind: keyMailKind,
      json: mail.bytes,
      mac: mail.mac,
      date: date,
    );

/// Builds the mail of a collection key (no MAC, 4.4).
Uint8List buildCollectionKeyMail({
  required String messageId,
  required CollectionKeyMail mail,
  required DateTime date,
}) =>
    _build(
      messageId: messageId,
      kind: collectionKeyMailKind,
      json: mail.bytes,
      date: date,
    );

Uint8List _build({
  required String messageId,
  required String kind,
  required Uint8List json,
  required DateTime date,
  Uint8List? mac,
}) {
  final b64 = base64.encode(json);
  final lines = [
    for (var i = 0; i < b64.length; i += 76)
      b64.substring(i, i + 76 < b64.length ? i + 76 : b64.length),
  ];
  final text = StringBuffer()
    ..write('Date: ${rfc5322Date(date)}$_crlf')
    ..write('Subject: $keyMailSubject$_crlf')
    ..write('Message-ID: $messageId$_crlf')
    ..write('MIME-Version: 1.0$_crlf')
    ..write('$schemaHeader: $objectMailSchema$_crlf')
    ..write('$keyKindHeader: $kind$_crlf')
    ..write('Content-Type: multipart/mixed; boundary="$_boundary"$_crlf')
    ..write(_crlf)
    ..write('--$_boundary$_crlf')
    ..write('Content-Type: text/plain; charset=us-ascii$_crlf')
    ..write('Content-Transfer-Encoding: 7bit$_crlf$_crlf')
    ..write('$keyMailNotice$_crlf')
    ..write('--$_boundary$_crlf')
    ..write('Content-Type: application/json$_crlf')
    ..write('Content-Transfer-Encoding: base64$_crlf')
    ..write(mac == null ? '' : '$keyMacHeader: ${b64url(mac)}$_crlf')
    ..write(_crlf)
    ..writeAll(lines.map((l) => '$l$_crlf'))
    ..write('--$_boundary--$_crlf');
  return Uint8List.fromList(ascii.encode(text.toString()));
}

/// Parses a mail of the keys folder. Throws [FormatException] for any other
/// mail (e.g. a pairing mail), an unknown kind or schema, and an account-key
/// mail with a missing or duplicate MAC. The MAC itself is checked later by
/// [SignedKeyMail.verify] against the decoded part bytes.
ParsedKeyMail parseKeyMailMessage(Uint8List bytes) {
  final msg = MimeMessage.parseFromData(bytes);
  final schema = msg.getHeaderValue(schemaHeader)?.trim();
  if (schema != objectMailSchema) {
    throw const FormatException('not a v1 SharedInbox key mail');
  }
  final messageId = msg.getHeaderValue('Message-ID')?.trim();
  if (messageId == null || messageId.isEmpty) {
    throw const FormatException('missing Message-ID');
  }
  final kind = msg.getHeaderValue(keyKindHeader)?.trim();
  final part = _jsonPart(msg);
  if (part == null) throw const FormatException('missing application/json');
  final json = part.decodeContentBinary();
  if (json == null) throw const FormatException('empty application/json');
  switch (kind) {
    case keyMailKind:
      final macs = part.getHeader(keyMacHeader)?.toList() ?? const [];
      if (macs.length != 1) {
        throw const FormatException('missing or duplicate $keyMacHeader');
      }
      final Uint8List mac;
      try {
        mac = b64urlDecode(macs.single.value?.trim() ?? '');
      } on FormatException {
        throw const FormatException('$keyMacHeader is not base64url');
      }
      return AccountKeyMailMsg(messageId, SignedKeyMail.parse(json, mac));
    case collectionKeyMailKind:
      return CollectionKeyMailMsg(messageId, CollectionKeyMail.parse(json));
  }
  throw const FormatException('unknown $keyKindHeader');
}

MimePart? _jsonPart(MimePart part) {
  if (part.mediaType.text == 'application/json') return part;
  for (final child in part.parts ?? const <MimePart>[]) {
    final found = _jsonPart(child);
    if (found != null) return found;
  }
  return null;
}
