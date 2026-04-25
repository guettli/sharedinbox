import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/sieve_script.dart';

void main() {
  test('SieveScript holds fields', () {
    const s = SieveScript(
      id: 'id1',
      name: 'My filter',
      blobId: 'blob1',
      isActive: true,
    );
    expect(s.id, 'id1');
    expect(s.name, 'My filter');
    expect(s.blobId, 'blob1');
    expect(s.isActive, true);
  });
}
