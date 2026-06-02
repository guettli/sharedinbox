import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/repositories/share_key_repository.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Drift-backed implementation of [ShareKeyRepository].
///
/// Each key pair lives for 20 minutes.  Expired rows are pruned whenever a
/// new key pair is created or looked up.
class ShareKeyRepositoryImpl implements ShareKeyRepository {
  ShareKeyRepositoryImpl(this._db);

  final AppDatabase _db;

  @override
  Future<ShareKeyMaterial> createKeyPair() async {
    await _pruneExpired();

    final material = await ShareEncryptionService.generateKeyPair();
    final keyIdHex = _hex(material.keyId);
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 20));

    await _db
        .into(_db.shareKeys)
        .insert(
          ShareKeysCompanion.insert(
            id: keyIdHex,
            publicKey: base64.encode(material.publicKeyBytes),
            privateKey: base64.encode(material.privateKeyBytes),
            expiresAt: expiresAt,
          ),
        );

    return material;
  }

  @override
  Future<ShareKeyMaterial?> findByKeyId(Uint8List keyId) async {
    await _pruneExpired();

    final keyIdHex = _hex(keyId);
    final row = await (_db.select(
      _db.shareKeys,
    )..where((t) => t.id.equals(keyIdHex))).getSingleOrNull();

    if (row == null) return null;
    if (row.expiresAt.isBefore(DateTime.now().toUtc())) return null;

    return ShareKeyMaterial(
      keyId: keyId,
      publicKeyBytes: Uint8List.fromList(base64.decode(row.publicKey)),
      privateKeyBytes: Uint8List.fromList(base64.decode(row.privateKey)),
    );
  }

  Future<void> _pruneExpired() async {
    await (_db.delete(
          _db.shareKeys,
        )..where((t) => t.expiresAt.isSmallerThanValue(DateTime.now().toUtc())))
        .go();
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
