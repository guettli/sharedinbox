import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _pubKeyPrefix = 'sharedinbox.de:pubkey:v1:';
const _encAccountsPrefix = 'sharedinbox.de:encrypted-accounts:v1:';

// ECIES wire sizes (bytes).
const _keyIdLen = 16;
const _pubKeyLen = 32;
const _nonceLen = 12;
const _macLen = 16;

/// Describes a freshly generated key pair before it is written to the database.
class ShareKeyMaterial {
  const ShareKeyMaterial({
    required this.keyId,
    required this.publicKeyBytes,
    required this.privateKeyBytes,
  });

  /// Random 16-byte identifier (hex-encoded when stored / included in QR).
  final Uint8List keyId;

  /// X25519 public key, 32 bytes.
  final Uint8List publicKeyBytes;

  /// X25519 private key, 32 bytes.
  final Uint8List privateKeyBytes;
}

/// An account + password pair, used in the plaintext payload before encryption.
class AccountPayload {
  const AccountPayload({required this.accountJson, required this.password});

  final Map<String, dynamic> accountJson;
  final String password;
}

/// Pure-Dart cryptographic helpers for the secure account-sharing flow.
///
/// Protocol:
///   Receiver generates an X25519 key pair with 20-minute lifetime and shows
///   its public key as a QR code.  The sender scans that QR, encrypts the
///   selected account(s) using ECIES (X25519-ECDH + HKDF-SHA256 + AES-256-GCM)
///   and shows the encrypted payload as a QR code.  The receiver scans that QR,
///   looks up the private key by the embedded key-ID, and decrypts.
class ShareEncryptionService {
  static final _x25519 = X25519();
  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _rng = Random.secure();

  // ── Key generation ──────────────────────────────────────────────────────────

  static Future<ShareKeyMaterial> generateKeyPair() async {
    final keyId = Uint8List(_keyIdLen);
    for (var i = 0; i < _keyIdLen; i++) {
      keyId[i] = _rng.nextInt(256);
    }

    final keyPair = await _x25519.newKeyPair();
    final pub = await keyPair.extractPublicKey();
    final priv = await keyPair.extractPrivateKeyBytes();

    return ShareKeyMaterial(
      keyId: keyId,
      publicKeyBytes: Uint8List.fromList(pub.bytes),
      privateKeyBytes: Uint8List.fromList(priv),
    );
  }

  // ── Public-key QR encoding / parsing ────────────────────────────────────────

  /// Encodes the receiver's public key as a QR-code string.
  ///
  /// Format: `sharedinbox.de:pubkey:v1:<base64(keyId[16] || pubKey[32])>`
  static String encodePublicKeyQr(Uint8List keyId, Uint8List publicKeyBytes) {
    assert(keyId.length == _keyIdLen);
    assert(publicKeyBytes.length == _pubKeyLen);
    final data = Uint8List(_keyIdLen + _pubKeyLen)
      ..setAll(0, keyId)
      ..setAll(_keyIdLen, publicKeyBytes);
    return '$_pubKeyPrefix${base64.encode(data)}';
  }

  /// Parses a public-key QR string.  Returns null if the format is invalid.
  static ({Uint8List keyId, Uint8List publicKeyBytes})? parsePublicKeyQr(
    String s,
  ) {
    if (!s.startsWith(_pubKeyPrefix)) return null;
    try {
      final data = Uint8List.fromList(
        base64.decode(s.substring(_pubKeyPrefix.length)),
      );
      if (data.length != _keyIdLen + _pubKeyLen) return null;
      return (
        keyId: data.sublist(0, _keyIdLen),
        publicKeyBytes: data.sublist(_keyIdLen),
      );
    } catch (_) {
      return null;
    }
  }

  // ── Encryption ───────────────────────────────────────────────────────────────

  /// Encrypts [accounts] for the given recipient key pair using ECIES.
  ///
  /// Returns the QR-code string to show on the sender device.
  ///
  /// Wire format (base64-encoded):
  ///   keyId[16] || ephPubKey[32] || nonce[12] || ciphertext || mac[16]
  static Future<String> encryptAccounts({
    required Uint8List recipientKeyId,
    required Uint8List recipientPublicKeyBytes,
    required List<AccountPayload> accounts,
  }) async {
    // Build plaintext JSON.
    final plaintext = utf8.encode(
      jsonEncode({
        'v': 2,
        'issuedAt': DateTime.now().toUtc().toIso8601String(),
        'accounts': accounts
            .map((a) => {'account': a.accountJson, 'password': a.password})
            .toList(),
      }),
    );

    // Ephemeral sender key pair for forward-secrecy.
    final ephKeyPair = await _x25519.newKeyPair();
    final ephPub = await ephKeyPair.extractPublicKey();

    // ECDH: shared secret = X25519(ephPriv, recipientPub).
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephKeyPair,
      remotePublicKey: SimplePublicKey(
        recipientPublicKeyBytes,
        type: KeyPairType.x25519,
      ),
    );

    // Derive AES key via HKDF-SHA256.
    final aesKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: recipientKeyId,
      info: utf8.encode('sharedinbox-account-transfer'),
    );

    // Encrypt with AES-256-GCM.
    final nonce = Uint8List(_nonceLen);
    for (var i = 0; i < _nonceLen; i++) {
      nonce[i] = _rng.nextInt(256);
    }

    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: aesKey,
      nonce: nonce,
    );

    // Pack wire format.
    final ephPubBytes = Uint8List.fromList(ephPub.bytes);
    final cipherBytes = Uint8List.fromList(box.cipherText);
    final macBytes = Uint8List.fromList(box.mac.bytes);

    final out =
        Uint8List(
            _keyIdLen + _pubKeyLen + _nonceLen + cipherBytes.length + _macLen,
          )
          ..setAll(0, recipientKeyId)
          ..setAll(_keyIdLen, ephPubBytes)
          ..setAll(_keyIdLen + _pubKeyLen, nonce)
          ..setAll(_keyIdLen + _pubKeyLen + _nonceLen, cipherBytes)
          ..setAll(
            _keyIdLen + _pubKeyLen + _nonceLen + cipherBytes.length,
            macBytes,
          );

    return '$_encAccountsPrefix${base64.encode(out)}';
  }

  // ── Decryption ───────────────────────────────────────────────────────────────

  /// Parses and decrypts an encrypted-accounts QR string.
  ///
  /// Throws [FormatException] if the format is invalid.
  /// Throws [SecretBoxAuthenticationError] if authentication fails (tampered).
  static Future<List<AccountPayload>> decryptAccounts({
    required String qrString,
    required Uint8List privateKeyBytes,
    required Uint8List publicKeyBytes,
    required Uint8List keyId,
  }) async {
    if (!qrString.startsWith(_encAccountsPrefix)) {
      throw const FormatException('Not an encrypted-accounts QR code');
    }

    final Uint8List data;
    try {
      data = Uint8List.fromList(
        base64.decode(qrString.substring(_encAccountsPrefix.length)),
      );
    } catch (_) {
      throw const FormatException('Invalid base64 in encrypted-accounts QR');
    }

    // Minimum: keyId + ephPubKey + nonce + mac (no ciphertext is valid but odd).
    if (data.length < _keyIdLen + _pubKeyLen + _nonceLen + _macLen) {
      throw const FormatException('Encrypted-accounts payload too short');
    }

    final embeddedKeyId = data.sublist(0, _keyIdLen);
    // Verify that this payload was encrypted for the right key pair.
    for (var i = 0; i < _keyIdLen; i++) {
      if (embeddedKeyId[i] != keyId[i]) {
        throw const FormatException(
          'Key ID mismatch — please scan a fresh public-key QR code',
        );
      }
    }

    final ephPubBytes = data.sublist(_keyIdLen, _keyIdLen + _pubKeyLen);
    final nonce = data.sublist(
      _keyIdLen + _pubKeyLen,
      _keyIdLen + _pubKeyLen + _nonceLen,
    );
    final cipherText = data.sublist(
      _keyIdLen + _pubKeyLen + _nonceLen,
      data.length - _macLen,
    );
    final mac = data.sublist(data.length - _macLen);

    // Reconstruct key pair.
    final keyPair = SimpleKeyPairData(
      privateKeyBytes,
      publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );

    // ECDH.
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(ephPubBytes, type: KeyPairType.x25519),
    );

    // Re-derive AES key.
    final aesKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: keyId,
      info: utf8.encode('sharedinbox-account-transfer'),
    );

    // Decrypt — throws SecretBoxAuthenticationError if tampered.
    final plaintext = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: aesKey,
    );

    // Parse JSON.
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Decrypted payload is not valid JSON');
    }

    if ((json['v'] as int?) != 2) {
      throw const FormatException('Unsupported encrypted-accounts version');
    }

    // Verify issuedAt is within 20 minutes.
    final issuedAtRaw = json['issuedAt'] as String?;
    if (issuedAtRaw != null) {
      final issuedAt = DateTime.tryParse(issuedAtRaw);
      if (issuedAt != null) {
        final age = DateTime.now().toUtc().difference(issuedAt.toUtc());
        if (age.abs() > const Duration(minutes: 20)) {
          throw const FormatException(
            'The encrypted payload has expired (older than 20 minutes)',
          );
        }
      }
    }

    final rawAccounts = json['accounts'] as List<dynamic>;
    return rawAccounts.map((entry) {
      final m = entry as Map<String, dynamic>;
      return AccountPayload(
        accountJson: m['account'] as Map<String, dynamic>,
        password: m['password'] as String,
      );
    }).toList();
  }
}
