import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/services/share_encryption_service.dart';
import 'package:test/test.dart';

void main() {
  group('ShareEncryptionService', () {
    // ── generateKeyPair ─────────────────────────────────────────────────────

    test('generateKeyPair returns 16-byte key ID and 32-byte keys', () async {
      final m = await ShareEncryptionService.generateKeyPair();
      expect(m.keyId.length, 16);
      expect(m.publicKeyBytes.length, 32);
      expect(m.privateKeyBytes.length, 32);
    });

    test('generateKeyPair returns unique key IDs', () async {
      final a = await ShareEncryptionService.generateKeyPair();
      final b = await ShareEncryptionService.generateKeyPair();
      expect(a.keyId, isNot(equals(b.keyId)));
    });

    // ── encodePublicKeyQr / parsePublicKeyQr ────────────────────────────────

    test('encodePublicKeyQr produces expected prefix', () async {
      final m = await ShareEncryptionService.generateKeyPair();
      final qr = ShareEncryptionService.encodePublicKeyQr(
        m.keyId,
        m.publicKeyBytes,
      );
      expect(qr, startsWith('sharedinbox.de:pubkey:v1:'));
    });

    test('parsePublicKeyQr round-trips correctly', () async {
      final m = await ShareEncryptionService.generateKeyPair();
      final qr = ShareEncryptionService.encodePublicKeyQr(
        m.keyId,
        m.publicKeyBytes,
      );
      final parsed = ShareEncryptionService.parsePublicKeyQr(qr);
      expect(parsed, isNotNull);
      expect(parsed!.keyId, equals(m.keyId));
      expect(parsed.publicKeyBytes, equals(m.publicKeyBytes));
    });

    test('parsePublicKeyQr returns null for invalid input', () {
      expect(ShareEncryptionService.parsePublicKeyQr('not-valid'), isNull);
      expect(
        ShareEncryptionService.parsePublicKeyQr('sharedinbox.de:pubkey:v1:!!!'),
        isNull,
      );
      expect(
        ShareEncryptionService.parsePublicKeyQr(
          'sharedinbox.de:pubkey:v1:${base64.encode(Uint8List(10))}',
        ),
        isNull,
      );
    });

    // ── encrypt / decrypt round-trip ────────────────────────────────────────

    test('encrypt + decrypt round-trip restores account payload', () async {
      final m = await ShareEncryptionService.generateKeyPair();

      final accounts = [
        const AccountPayload(
          accountJson: {
            'id': 'acc-1',
            'displayName': 'Alice',
            'email': 'alice@example.com',
            'username': '',
            'type': 'imap',
            'imapHost': 'imap.example.com',
            'imapPort': 993,
            'imapSsl': true,
            'smtpHost': 'smtp.example.com',
            'smtpPort': 465,
            'smtpSsl': true,
            'manageSieveHost': '',
            'manageSievePort': 4190,
            'manageSieveSsl': true,
            'manageSieveAvailable': null,
            'jmapUrl': null,
            'verbose': false,
          },
          password: 'hunter2',
        ),
      ];

      final qr = await ShareEncryptionService.encryptAccounts(
        recipientKeyId: m.keyId,
        recipientPublicKeyBytes: m.publicKeyBytes,
        accounts: accounts,
      );

      expect(qr, startsWith('sharedinbox.de:encrypted-accounts:v1:'));

      final decrypted = await ShareEncryptionService.decryptAccounts(
        qrString: qr,
        privateKeyBytes: m.privateKeyBytes,
        publicKeyBytes: m.publicKeyBytes,
        keyId: m.keyId,
      );

      expect(decrypted, hasLength(1));
      expect(decrypted.first.password, 'hunter2');
      expect(decrypted.first.accountJson['email'], 'alice@example.com');
      expect(decrypted.first.accountJson['displayName'], 'Alice');
    });

    test('decrypt multiple accounts', () async {
      final m = await ShareEncryptionService.generateKeyPair();

      final accounts = [
        const AccountPayload(
          accountJson: {
            'id': '1',
            'email': 'a@x.com',
            'displayName': 'A',
            'username': '',
            'type': 'imap',
            'imapHost': 'h',
            'imapPort': 993,
            'imapSsl': true,
            'smtpHost': 'h',
            'smtpPort': 465,
            'smtpSsl': true,
            'manageSieveHost': '',
            'manageSievePort': 4190,
            'manageSieveSsl': true,
            'manageSieveAvailable': null,
            'jmapUrl': null,
            'verbose': false,
          },
          password: 'pw1',
        ),
        const AccountPayload(
          accountJson: {
            'id': '2',
            'email': 'b@x.com',
            'displayName': 'B',
            'username': '',
            'type': 'imap',
            'imapHost': 'h',
            'imapPort': 993,
            'imapSsl': true,
            'smtpHost': 'h',
            'smtpPort': 465,
            'smtpSsl': true,
            'manageSieveHost': '',
            'manageSievePort': 4190,
            'manageSieveSsl': true,
            'manageSieveAvailable': null,
            'jmapUrl': null,
            'verbose': false,
          },
          password: 'pw2',
        ),
      ];

      final qr = await ShareEncryptionService.encryptAccounts(
        recipientKeyId: m.keyId,
        recipientPublicKeyBytes: m.publicKeyBytes,
        accounts: accounts,
      );

      final decrypted = await ShareEncryptionService.decryptAccounts(
        qrString: qr,
        privateKeyBytes: m.privateKeyBytes,
        publicKeyBytes: m.publicKeyBytes,
        keyId: m.keyId,
      );

      expect(decrypted, hasLength(2));
      expect(decrypted.map((a) => a.password), containsAll(['pw1', 'pw2']));
    });

    test('decrypt rejects wrong key ID', () async {
      final sender = await ShareEncryptionService.generateKeyPair();
      final other = await ShareEncryptionService.generateKeyPair();

      final qr = await ShareEncryptionService.encryptAccounts(
        recipientKeyId: sender.keyId,
        recipientPublicKeyBytes: sender.publicKeyBytes,
        accounts: [const AccountPayload(accountJson: {}, password: 'pw')],
      );

      expect(
        () => ShareEncryptionService.decryptAccounts(
          qrString: qr,
          privateKeyBytes: other.privateKeyBytes,
          publicKeyBytes: other.publicKeyBytes,
          keyId: other.keyId, // different key ID
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('decrypt rejects invalid prefix', () async {
      final m = await ShareEncryptionService.generateKeyPair();
      expect(
        () => ShareEncryptionService.decryptAccounts(
          qrString: 'not-valid',
          privateKeyBytes: m.privateKeyBytes,
          publicKeyBytes: m.publicKeyBytes,
          keyId: m.keyId,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('decrypt rejects tampered ciphertext', () async {
      final m = await ShareEncryptionService.generateKeyPair();

      final qr = await ShareEncryptionService.encryptAccounts(
        recipientKeyId: m.keyId,
        recipientPublicKeyBytes: m.publicKeyBytes,
        accounts: [
          const AccountPayload(
            accountJson: {'id': '1', 'email': 'a@x.com'},
            password: 'pw',
          ),
        ],
      );

      // Flip a byte in the base64 payload.
      const prefix = 'sharedinbox.de:encrypted-accounts:v1:';
      final raw = qr.substring(prefix.length);
      final bytes = base64.decode(raw);
      bytes[40] ^= 0xFF; // Corrupt a byte in the ciphertext area.
      final tampered = '$prefix${base64.encode(bytes)}';

      await expectLater(
        ShareEncryptionService.decryptAccounts(
          qrString: tampered,
          privateKeyBytes: m.privateKeyBytes,
          publicKeyBytes: m.publicKeyBytes,
          keyId: m.keyId,
        ),
        throwsA(anything),
      );
    });
  });
}
