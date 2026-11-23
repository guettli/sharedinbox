import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:enough_mail/enough_mail.dart';

import 'package:sharedinbox/core/encrypted_objects/key_mail_message.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/repositories/share_key_repository.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';

/// Pairing (`ENCRYPTED-OBJECTS.md` 4.2, 4.6): an unlocked device sends the
/// account key to a new device, encrypted to the new device's ephemeral
/// X25519 key with `ShareEncryptionService.encryptBytes`
/// ([HkdfInfo.pairing]). The request (the public key) travels only
/// out-of-band; the reply as a pairing mail in `SharedInbox/Keys` or as a
/// pasted code.

const pairingRequestPrefix = 'sharedinbox.de:pair:v1:';
const pairingCodePrefix = 'sharedinbox.de:pairing:v1:';
const pairingMailKind = 'pairing';
const pairingMailSubject = 'SharedInbox pairing';
const pairingPlaintextKind = 'pairing';

/// How far `issuedAt` may lie in the future (clock skew); also the grace
/// after [ShareKeyMaterial.lifetime] before a pairing mail is deleted.
const pairingClockSkew = Duration(minutes: 5);

const _pubLength = 32;
const _crlf = '\r\n';

/// What the new device shows: its ephemeral public key and the account it
/// wants the key of.
class PairingRequest {
  const PairingRequest({
    required this.keyId,
    required this.publicKey,
    required this.server,
    required this.username,
  });

  final Uint8List keyId;
  final Uint8List publicKey;
  final String server;
  final String username;
}

/// `sharedinbox.de:pair:v1:<base64url(keyId ‖ pub ‖ enc(server) ‖
/// enc(username))>`.
String encodePairingRequest(PairingRequest request) {
  if (request.keyId.length != idLength ||
      request.publicKey.length != _pubLength) {
    throw ArgumentError.value(request, 'request', 'bad key length');
  }
  final bytes = buildAad([
    request.keyId,
    request.publicKey,
    request.server,
    request.username,
  ]);
  return '$pairingRequestPrefix${b64url(bytes)}';
}

/// Parses a request; null for anything else (e.g. an account-transfer code).
PairingRequest? parsePairingRequest(String text) {
  final s = text.trim();
  if (!s.startsWith(pairingRequestPrefix)) return null;
  final Uint8List bytes;
  try {
    bytes = b64urlDecode(s.substring(pairingRequestPrefix.length));
  } on FormatException {
    return null;
  }
  const head = idLength + _pubLength;
  if (bytes.length < head) return null;
  var pos = head;
  String? readString() {
    if (pos + 2 > bytes.length) return null;
    final len = (bytes[pos] << 8) | bytes[pos + 1];
    pos += 2;
    if (pos + len > bytes.length) return null;
    final String value;
    try {
      value = utf8.decode(bytes.sublist(pos, pos + len));
    } on FormatException {
      return null;
    }
    pos += len;
    return value;
  }

  final server = readString();
  final username = readString();
  if (server == null || username == null || pos != bytes.length) return null;
  return PairingRequest(
    keyId: bytes.sublist(0, idLength),
    publicKey: bytes.sublist(idLength, head),
    server: server,
    username: username,
  );
}

/// The decrypted pairing plaintext.
class PairingPayload {
  const PairingPayload({
    required this.accountKey,
    required this.server,
    required this.username,
    required this.issuedAt,
  });

  final AccountKey accountKey;
  final String server;
  final String username;
  final DateTime issuedAt;

  /// `{"v":1,"kind":"pairing","accountKeyId","accountKey","server",
  /// "username","issuedAt"}`.
  Uint8List toBytes() => Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': 1,
            'kind': pairingPlaintextKind,
            'accountKeyId': b64url(accountKey.accountKeyId),
            'accountKey': b64url(accountKey.key.bytes),
            'server': server,
            'username': username,
            'issuedAt': issuedAt.toUtc().toIso8601String(),
          }),
        ),
      );

  /// Throws [FormatException].
  static PairingPayload parse(Uint8List bytes) {
    final json = decodeJsonObject(bytes);
    if (json['v'] != 1 || json['kind'] != pairingPlaintextKind) {
      throw const FormatException('not a v1 pairing payload');
    }
    final issuedAt = DateTime.tryParse(readStringField(json, 'issuedAt'));
    if (issuedAt == null) throw const FormatException('bad issuedAt');
    return PairingPayload(
      accountKey: AccountKey(
        readBytesField(json, 'accountKeyId', idLength),
        readBytesField(json, 'accountKey', keyLength),
      ),
      server: readStringField(json, 'server'),
      username: readStringField(json, 'username'),
      issuedAt: issuedAt,
    );
  }
}

/// Encrypts [accountKey] to [request]: the ECIES bytes
/// `keyId ‖ ephPub ‖ nonce ‖ ciphertext ‖ mac`.
Future<Uint8List> sealPairing({
  required PairingRequest request,
  required AccountKey accountKey,
  required DateTime issuedAt,
}) =>
    ShareEncryptionService.encryptBytes(
      recipientKeyId: request.keyId,
      recipientPublicKeyBytes: request.publicKey,
      plaintext: PairingPayload(
        accountKey: accountKey,
        server: request.server,
        username: request.username,
        issuedAt: issuedAt,
      ).toBytes(),
      info: HkdfInfo.pairing,
    );

/// The paste fallback: `sharedinbox.de:pairing:v1:<base64url(ecies)>`.
String encodePairingCode(Uint8List ecies) =>
    '$pairingCodePrefix${b64url(ecies)}';

/// The ECIES bytes of a pasted code. Throws [PairingRejected] (`badFormat`).
Uint8List parsePairingCode(String text) {
  final s = text.trim();
  if (!s.startsWith(pairingCodePrefix)) {
    throw const PairingRejected(PairingRejection.badFormat);
  }
  try {
    return b64urlDecode(s.substring(pairingCodePrefix.length));
  } on FormatException {
    throw const PairingRejected(PairingRejection.badFormat);
  }
}

/// The pairing mail: one `base64` `application/octet-stream` part with the
/// ECIES bytes. [parseKeyMailMessage] rejects it.
Uint8List buildPairingMail({
  required String messageId,
  required Uint8List ecies,
  required DateTime date,
}) {
  final b64 = base64.encode(ecies);
  final text = StringBuffer()
    ..write('Date: ${rfc5322Date(date)}$_crlf')
    ..write('Subject: $pairingMailSubject$_crlf')
    ..write('Message-ID: $messageId$_crlf')
    ..write('MIME-Version: 1.0$_crlf')
    ..write('$schemaHeader: $objectMailSchema$_crlf')
    ..write('$keyKindHeader: $pairingMailKind$_crlf')
    ..write('Content-Type: application/octet-stream$_crlf')
    ..write('Content-Transfer-Encoding: base64$_crlf')
    ..write(_crlf);
  for (var i = 0; i < b64.length; i += 76) {
    final end = i + 76 < b64.length ? i + 76 : b64.length;
    text.write('${b64.substring(i, end)}$_crlf');
  }
  return Uint8List.fromList(ascii.encode(text.toString()));
}

typedef PairingMail = ({String messageId, DateTime? date, Uint8List ecies});

/// Parses a pairing mail. Throws [FormatException] for any other mail (e.g.
/// a key mail).
PairingMail parsePairingMail(Uint8List bytes) {
  final msg = MimeMessage.parseFromData(bytes);
  if (msg.getHeaderValue(schemaHeader)?.trim() != objectMailSchema ||
      msg.getHeaderValue(keyKindHeader)?.trim() != pairingMailKind) {
    throw const FormatException('not a v1 SharedInbox pairing mail');
  }
  final messageId = msg.getHeaderValue('Message-ID')?.trim();
  if (messageId == null || messageId.isEmpty) {
    throw const FormatException('missing Message-ID');
  }
  if (msg.mediaType.text != 'application/octet-stream') {
    throw const FormatException('missing application/octet-stream');
  }
  final ecies = msg.decodeContentBinary();
  if (ecies == null || ecies.isEmpty) {
    throw const FormatException('empty pairing mail');
  }
  return (messageId: messageId, date: msg.decodeDate(), ecies: ecies);
}

/// Why a pairing payload was not accepted.
enum PairingRejection {
  badFormat,

  /// The `keyId` is not a key pair of this device, or it expired.
  unknownOrExpiredKey,

  /// Authentication failed: tampered, another key, or another HKDF info.
  tampered,

  /// `issuedAt` older than [ShareKeyMaterial.lifetime] or in the future.
  expired,

  /// Another server or username than this account's.
  wrongAccount,

  /// The key does not verify against the winning key mail (4.3).
  keyMismatch,
}

class PairingRejected implements Exception {
  const PairingRejected(this.reason);

  final PairingRejection reason;

  @override
  String toString() => 'PairingRejected: ${reason.name}';
}

/// Decrypts [ecies] with the key pair its `keyId` names and checks age and
/// account. The slot-list check against the winning key mail is the
/// caller's. Throws [PairingRejected].
Future<AccountKey> openPairing({
  required Uint8List ecies,
  required ShareKeyRepository keys,
  required String server,
  required String username,
  required DateTime now,
}) async {
  if (ecies.length < idLength) {
    throw const PairingRejected(PairingRejection.badFormat);
  }
  final keyId = ecies.sublist(0, idLength);
  final pair = await keys.findByKeyId(keyId);
  final expiresAt = pair?.expiresAt;
  if (pair == null || (expiresAt != null && expiresAt.isBefore(now))) {
    throw const PairingRejected(PairingRejection.unknownOrExpiredKey);
  }
  final Uint8List clear;
  try {
    clear = await ShareEncryptionService.decryptBytes(
      data: ecies,
      privateKeyBytes: pair.privateKeyBytes,
      publicKeyBytes: pair.publicKeyBytes,
      keyId: keyId,
      info: HkdfInfo.pairing,
    );
  } on SecretBoxAuthenticationError {
    throw const PairingRejected(PairingRejection.tampered);
  } on FormatException {
    throw const PairingRejected(PairingRejection.badFormat);
  }
  final PairingPayload payload;
  try {
    payload = PairingPayload.parse(clear);
  } on FormatException {
    throw const PairingRejected(PairingRejection.badFormat);
  }
  final age = now.toUtc().difference(payload.issuedAt.toUtc());
  if (age > ShareKeyMaterial.lifetime || -age > pairingClockSkew) {
    throw const PairingRejected(PairingRejection.expired);
  }
  if (payload.server != server || payload.username != username) {
    throw const PairingRejected(PairingRejection.wrongAccount);
  }
  return payload.accountKey;
}
