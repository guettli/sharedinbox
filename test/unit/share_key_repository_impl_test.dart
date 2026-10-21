import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/services/share_encryption_service.dart';
import 'package:sharedinbox/data/repositories/share_key_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  group('ShareKeyRepositoryImpl', () {
    test('createKeyPair reports when the stored key expires', () async {
      final db = openTestDatabase();
      final repo = ShareKeyRepositoryImpl(db);

      final before = DateTime.now().toUtc();
      final material = await repo.createKeyPair();

      final expiresAt = material.expiresAt!;
      expect(
        expiresAt.isBefore(before.add(ShareKeyMaterial.lifetime)),
        isFalse,
      );
      expect(
        expiresAt.isAfter(
          DateTime.now().toUtc().add(ShareKeyMaterial.lifetime),
        ),
        isFalse,
      );

      final found = await repo.findByKeyId(material.keyId);
      expect(found!.privateKeyBytes, material.privateKeyBytes);
      // The DB keeps whole seconds.
      expect(
        found.expiresAt!.difference(expiresAt).abs(),
        lessThan(const Duration(seconds: 1)),
      );

      await db.close();
    });
  });
}
