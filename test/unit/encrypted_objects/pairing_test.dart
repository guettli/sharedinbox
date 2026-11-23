import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail_message.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/pairing.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/share_key_repository.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

const _server = 'mail.example.com';
const _user = 'alice@example.com';
final _now = DateTime.utc(2026, 11, 23, 10);

/// In-memory key pairs by hex keyId.
class _Keys implements ShareKeyRepository {
  final pairs = <String, ShareKeyMaterial>{};

  @override
  Future<ShareKeyMaterial> createKeyPair() async {
    final m = await ShareEncryptionService.generateKeyPair();
    final stored = ShareKeyMaterial(
      keyId: m.keyId,
      publicKeyBytes: m.publicKeyBytes,
      privateKeyBytes: m.privateKeyBytes,
      expiresAt: _now.add(ShareKeyMaterial.lifetime),
    );
    pairs[toHex(m.keyId)] = stored;
    return stored;
  }

  @override
  Future<ShareKeyMaterial?> findByKeyId(Uint8List keyId) async =>
      pairs[toHex(keyId)];
}

PairingRequest _request(ShareKeyMaterial pair) => PairingRequest(
      keyId: pair.keyId,
      publicKey: pair.publicKeyBytes,
      server: _server,
      username: _user,
    );

void main() {
  late _Keys keys;
  late ShareKeyMaterial pair;

  setUp(() async {
    keys = _Keys();
    pair = await keys.createKeyPair();
  });

  Future<AccountKey> open(
    Uint8List ecies, {
    String server = _server,
    String username = _user,
    DateTime? now,
  }) =>
      openPairing(
        ecies: ecies,
        keys: keys,
        server: server,
        username: username,
        now: now ?? _now,
      );

  Future<Uint8List> seal({PairingRequest? request, DateTime? issuedAt}) =>
      sealPairing(
        request: request ?? _request(pair),
        accountKey: testAccountKey,
        issuedAt: issuedAt ?? _now,
      );

  Matcher rejected(PairingRejection reason) => throwsA(
        isA<PairingRejected>().having((e) => e.reason, 'reason', reason),
      );

  group('request', () {
    test('round-trips', () {
      final text = encodePairingRequest(_request(pair));
      expect(text, startsWith('sharedinbox.de:pair:v1:'));

      final parsed = parsePairingRequest('  $text\n')!;
      expect(parsed.keyId, pair.keyId);
      expect(parsed.publicKey, pair.publicKeyBytes);
      expect(parsed.server, _server);
      expect(parsed.username, _user);
    });

    test('anything else is null', () {
      final text = encodePairingRequest(_request(pair));
      final body = b64urlDecode(text.substring(pairingRequestPrefix.length));
      expect(
        parsePairingRequest(
          ShareEncryptionService.encodePublicKeyQr(
            pair.keyId,
            pair.publicKeyBytes,
          ),
        ),
        isNull,
        reason: 'an account-transfer code',
      );
      expect(parsePairingRequest('${pairingRequestPrefix}not*base64'), isNull);
      expect(
        parsePairingRequest('$pairingRequestPrefix${b64url([...body, 0])}'),
        isNull,
        reason: 'trailing bytes',
      );
      expect(
        parsePairingRequest(
          '$pairingRequestPrefix${b64url(body.sublist(0, body.length - 1))}',
        ),
        isNull,
        reason: 'truncated',
      );
    });
  });

  test('the pairing mail and the paste code carry the same payload', () async {
    final ecies = await seal();
    final mail = buildPairingMail(
      messageId: '<p@sharedinbox.invalid>',
      ecies: ecies,
      date: _now,
    );
    final text = ascii.decode(mail);
    expect(text, contains('X-SharedInbox-Key-Kind: pairing\r\n'));
    expect(text, contains('Subject: SharedInbox pairing\r\n'));

    final parsed = parsePairingMail(mail);
    expect(parsed.messageId, '<p@sharedinbox.invalid>');
    expect(parsed.date!.isAtSameMomentAs(_now), isTrue);
    expect(parsed.ecies, ecies);

    final code = encodePairingCode(ecies);
    expect(code, startsWith('sharedinbox.de:pairing:v1:'));
    expect(parsePairingCode(' $code '), ecies);

    final key = await open(parsed.ecies);
    expect(key.accountKeyId, testAccountKey.accountKeyId);
    expect(key.key.bytes, testAccountKey.key.bytes);
  });

  test('the key-mail parser rejects a pairing mail and vice versa', () async {
    final pairing = buildPairingMail(
      messageId: '<p@sharedinbox.invalid>',
      ecies: await seal(),
      date: _now,
    );
    expect(() => parseKeyMailMessage(pairing), throwsFormatException);

    final payload = KeyMailPayload(
      accountKeyId: testAccountKey.accountKeyId,
      slotListVersion: 1,
      slots: const [],
    );
    final keyMail = buildKeyMail(
      messageId: '<k@sharedinbox.invalid>',
      mail: await payload.serialize(await testAccountKey.kSlots()),
      date: _now,
    );
    expect(() => parsePairingMail(keyMail), throwsFormatException);
  });

  test('a bad paste code is badFormat', () {
    expect(
      () => parsePairingCode('sharedinbox.de:pubkey:v1:AAAA'),
      rejected(PairingRejection.badFormat),
    );
    expect(
      () => parsePairingCode('${pairingCodePrefix}not*base64'),
      rejected(PairingRejection.badFormat),
    );
  });

  group('openPairing rejects', () {
    test('a wrong recipient key or an unknown keyId', () async {
      final other = await ShareEncryptionService.generateKeyPair();
      // Our keyId, another public key: does not decrypt.
      final wrongPub = await seal(
        request: PairingRequest(
          keyId: pair.keyId,
          publicKey: other.publicKeyBytes,
          server: _server,
          username: _user,
        ),
      );
      await expectLater(open(wrongPub), rejected(PairingRejection.tampered));

      final unknownId = await seal(
        request: PairingRequest(
          keyId: other.keyId,
          publicKey: other.publicKeyBytes,
          server: _server,
          username: _user,
        ),
      );
      await expectLater(
        open(unknownId),
        rejected(PairingRejection.unknownOrExpiredKey),
      );
    });

    test('a key pair that expired', () async {
      final ecies = await seal();
      await expectLater(
        open(ecies, now: pair.expiresAt!.add(const Duration(seconds: 1))),
        rejected(PairingRejection.unknownOrExpiredKey),
      );
    });

    test('issuedAt too old or in the future', () async {
      final old = await seal(
        issuedAt: _now.subtract(const Duration(minutes: 21)),
      );
      await expectLater(open(old), rejected(PairingRejection.expired));

      final future = await seal(issuedAt: _now.add(const Duration(minutes: 6)));
      await expectLater(open(future), rejected(PairingRejection.expired));

      final skewed = await seal(issuedAt: _now.add(const Duration(minutes: 4)));
      expect((await open(skewed)).key.bytes, testAccountKey.key.bytes);
    });

    test('a flipped byte in the ephemeral key, nonce, ciphertext or MAC',
        () async {
      final ecies = await seal();
      for (final at in [20, 50, 70, ecies.length - 1]) {
        final bad = Uint8List.fromList(ecies);
        bad[at] ^= 0x01;
        await expectLater(
          open(bad),
          rejected(PairingRejection.tampered),
          reason: 'byte $at',
        );
      }
    });

    test('another HKDF info', () async {
      final ecies = await ShareEncryptionService.encryptBytes(
        recipientKeyId: pair.keyId,
        recipientPublicKeyBytes: pair.publicKeyBytes,
        plaintext: PairingPayload(
          accountKey: testAccountKey,
          server: _server,
          username: _user,
          issuedAt: _now,
        ).toBytes(),
        info: 'sharedinbox-account-transfer',
      );
      await expectLater(open(ecies), rejected(PairingRejection.tampered));
    });

    test('another server or username', () async {
      final ecies = await seal();
      await expectLater(
        open(ecies, server: 'imap.other.org'),
        rejected(PairingRejection.wrongAccount),
      );
      await expectLater(
        open(ecies, username: 'bob@example.com'),
        rejected(PairingRejection.wrongAccount),
      );
    });

    test('a payload that is not a pairing plaintext, or too short', () async {
      final ecies = await ShareEncryptionService.encryptBytes(
        recipientKeyId: pair.keyId,
        recipientPublicKeyBytes: pair.publicKeyBytes,
        plaintext: utf8.encode('{"v":2}'),
        info: HkdfInfo.pairing,
      );
      await expectLater(open(ecies), rejected(PairingRejection.badFormat));
      await expectLater(
        open(Uint8List(8)),
        rejected(PairingRejection.badFormat),
      );
      await expectLater(
        open(Uint8List.fromList([...pair.keyId, 1, 2, 3])),
        rejected(PairingRejection.badFormat),
      );
    });
  });

  test('the account identity: host and username, lower case', () {
    const imap = Account(
      id: '1',
      displayName: 'A',
      email: 'Alice@Example.com',
      imapHost: 'Mail.Example.com ',
    );
    expect(imap.pairingServer, 'mail.example.com');
    expect(imap.pairingUsername, 'alice@example.com');

    const jmap = Account(
      id: '2',
      displayName: 'B',
      email: 'bob@example.com',
      username: 'Bob',
      type: AccountType.jmap,
      jmapUrl: 'https://JMAP.example.com/.well-known/jmap',
    );
    expect(jmap.pairingServer, 'jmap.example.com');
    expect(jmap.pairingUsername, 'bob');
  });
}
