import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/services/share_encryption_service.dart';

/// Base URL of the self-hosted report service that serves the maintainer's
/// public key and creates the GitHub issue. Overridable at build time with
/// `--dart-define=REPORT_API_BASE_URL=...`, mirroring `BUG_REPORT_API_URL`.
const _reportApiBaseUrl = String.fromEnvironment(
  'REPORT_API_BASE_URL',
  defaultValue: 'https://sharedinbox.de/api/v1',
);

// ECIES key sizes (bytes).
const _keyIdLen = 16;
const _pubKeyLen = 32;

/// The maintainer's public key, fetched from the report service. The matching
/// private key never leaves the maintainer's machine, so only they can read a
/// report's encrypted mail.
class ReportKey {
  const ReportKey({required this.keyId, required this.publicKeyBytes});

  /// Random 16-byte key identifier, embedded in the ciphertext.
  final Uint8List keyId;

  /// X25519 public key, 32 bytes.
  final Uint8List publicKeyBytes;
}

/// Fetches the maintainer's public key and encrypts the raw mail to it on the
/// device, so the plaintext is never exposed on the public issue tracker.
class EncryptedReportService {
  EncryptedReportService(this._client, {String? baseUrl})
      : _baseUrl = baseUrl ?? _reportApiBaseUrl;

  final http.Client _client;
  final String _baseUrl;

  /// HKDF domain-separation label; must match the maintainer's decrypt tool.
  static const encryptionInfo = 'sharedinbox-encrypted-report';

  /// URL the app POSTs the encrypted report to.
  String get submitUrl => '$_baseUrl/encrypted-reports';

  /// Fetches the maintainer's public key from `GET /report-key`.
  Future<ReportKey> fetchPublicKey() async {
    final resp = await _client.get(Uri.parse('$_baseUrl/report-key'));
    if (resp.statusCode != 200) {
      throw Exception(
        'Could not fetch the public key (HTTP ${resp.statusCode}).',
      );
    }
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Public-key response is not valid JSON.');
    }
    final keyId = Uint8List.fromList(base64.decode(json['keyId'] as String));
    final publicKey =
        Uint8List.fromList(base64.decode(json['publicKey'] as String));
    if (keyId.length != _keyIdLen || publicKey.length != _pubKeyLen) {
      throw const FormatException('Public-key response has invalid key sizes.');
    }
    return ReportKey(keyId: keyId, publicKeyBytes: publicKey);
  }

  /// Encrypts [rawMail] to [key] using ECIES (X25519 + AES-256-GCM). The
  /// returned bytes are the attachment uploaded with the report.
  Future<Uint8List> encryptMail(ReportKey key, List<int> rawMail) {
    return ShareEncryptionService.encryptBytes(
      recipientKeyId: key.keyId,
      recipientPublicKeyBytes: key.publicKeyBytes,
      plaintext: rawMail,
      info: encryptionInfo,
    );
  }
}
