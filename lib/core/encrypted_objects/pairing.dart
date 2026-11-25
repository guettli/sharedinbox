import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:enough_mail/enough_mail.dart';

import 'package:sharedinbox/core/encrypted_objects/key_mail_message.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/repositories/share_key_repository.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';

/// Pairing v2 (`ENCRYPTED-OBJECTS.md` 4.2, 4.6): an unlocked device sends
/// the account key to a new device, encrypted to the new device's ephemeral
/// X25519 key with `ShareEncryptionService.encryptBytes`
/// ([HkdfInfo.pairingV2]), bound to the request's secret and both public
/// keys. The request (public key and secret) travels only out-of-band and
/// is as secret as a password while it is valid; the reply as a pairing
/// mail in `SharedInbox/Keys` or as a pasted code. Both devices show
/// [pairingFingerprint] to compare.

const pairingRequestPrefix = 'sharedinbox.de:pair:v2:';
const pairingCodePrefix = 'sharedinbox.de:pairing:v2:';
const pairingMailKind = 'pairing';
const pairingMailSubject = 'SharedInbox pairing';
const pairingPlaintextKind = 'pairing';

/// How far `issuedAt` may lie in the future (clock skew); also the grace
/// after [ShareKeyMaterial.lifetime] before a pairing mail is deleted.
const pairingClockSkew = Duration(minutes: 5);

const _pubLength = 32;
const _secretLength = 16;
const _crlf = '\r\n';

/// The request secret of a key pair: the first 16 bytes of
/// HMAC-SHA256(privateKey, "sharedinbox-pairing-secret-v2"). Derived, so the
/// new device needs to store nothing besides its key pair.
Uint8List pairingSecret(Uint8List privateKeyBytes) => Uint8List.fromList(
      crypto.Hmac(crypto.sha256, privateKeyBytes)
          .convert(utf8.encode('sharedinbox-pairing-secret-v2'))
          .bytes
          .sublist(0, _secretLength),
    );

/// The comparison code both devices show: the first 80 bits of
/// SHA-256("sharedinbox-pairing-fp-v2" ‖ keyId ‖ publicKey ‖ secret) in
/// Crockford base32, as 4 groups of 4. 80 bits, so a swapped request cannot
/// be ground to show the same code.
String pairingFingerprint(PairingRequest request) {
  final digest = crypto.sha256.convert([
    ...utf8.encode('sharedinbox-pairing-fp-v2'),
    ...request.keyId,
    ...request.publicKey,
    ...request.secret,
  ]).bytes;
  var n = BigInt.zero;
  for (final b in digest.sublist(0, 10)) {
    n = (n << 8) | BigInt.from(b);
  }
  final out = StringBuffer();
  for (var i = 15; i >= 0; i--) {
    final c = ((n >> (5 * i)) & BigInt.from(31)).toInt();
    out.write('0123456789ABCDEFGHJKMNPQRSTVWXYZ'[c]);
    if (i % 4 == 0 && i != 0) out.write('-');
  }
  return out.toString();
}

/// What the new device shows: its ephemeral public key and the account it
/// wants the key of.
class PairingRequest {
  const PairingRequest({
    required this.keyId,
    required this.publicKey,
    required this.secret,
    required this.server,
    required this.username,
  });

  final Uint8List keyId;
  final Uint8List publicKey;

  /// [pairingSecret] of the key pair: mixed into the reply's key, so only
  /// who saw the request can write a reply the new device accepts.
  final Uint8List secret;
  final String server;
  final String username;
}

/// `sharedinbox.de:pair:v2:<base64url(keyId ‖ pub ‖ secret ‖ enc(server) ‖
/// enc(username))>`.
String encodePairingRequest(PairingRequest request) {
  if (request.keyId.length != idLength ||
      request.publicKey.length != _pubLength ||
      request.secret.length != _secretLength) {
    throw ArgumentError.value(request, 'request', 'bad key length');
  }
  final bytes = buildAad([
    request.keyId,
    request.publicKey,
    request.secret,
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
  const head = idLength + _pubLength + _secretLength;
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
    publicKey: bytes.sublist(idLength, idLength + _pubLength),
    secret: bytes.sublist(idLength + _pubLength, head),
    server: server,
    username: username,
  );
}

/// The comparison code of a pasted request, or null if it is none.
String? pairingFingerprintOf(String text) {
  final request = parsePairingRequest(text);
  return request == null ? null : pairingFingerprint(request);
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
      info: HkdfInfo.pairingV2,
      bindSecret: request.secret,
    );

/// The paste fallback: `sharedinbox.de:pairing:v2:<base64url(ecies)>`.
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
      info: HkdfInfo.pairingV2,
      bindSecret: pairingSecret(pair.privateKeyBytes),
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
