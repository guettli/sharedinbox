import 'dart:typed_data';

import 'package:sharedinbox/core/services/share_encryption_service.dart';

/// Stores and retrieves ephemeral X25519 key pairs for secure account sharing.
abstract class ShareKeyRepository {
  /// Generates a new key pair and persists it with a 20-minute expiry.
  Future<ShareKeyMaterial> createKeyPair();

  /// Returns the key pair whose ID matches [keyId], or null if not found /
  /// expired.
  Future<ShareKeyMaterial?> findByKeyId(Uint8List keyId);
}
