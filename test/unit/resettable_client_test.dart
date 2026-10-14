import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/net/resettable_client.dart';

/// A delegate that records whether it was closed and which one answered, so a
/// test can prove [ResettableClient] swaps and closes delegates correctly.
class _FakeClient extends http.BaseClient {
  _FakeClient(this.id);

  final String id;
  bool closed = false;
  int sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    return http.StreamedResponse(Stream.value(utf8.encode(id)), 200);
  }

  @override
  void close() => closed = true;
}

/// Builds a [ResettableClient] whose delegates are [_FakeClient]s, returning
/// the list each `reset()` appends to so a test can inspect them.
({ResettableClient client, List<_FakeClient> made}) _build() {
  final made = <_FakeClient>[];
  final client = ResettableClient(() {
    final c = _FakeClient('c${made.length}');
    made.add(c);
    return c;
  });
  return (client: client, made: made);
}

void main() {
  group('ResettableClient', () {
    test('reset swaps the delegate and closes the old one', () async {
      final (:client, :made) = _build();

      expect(made.length, 1, reason: 'one delegate built up front');
      final r1 = await client.get(Uri.parse('https://example.test/'));
      expect(r1.body, 'c0');

      client.reset();
      expect(made[0].closed, isTrue, reason: 'old delegate closed on reset');
      expect(made.length, 2, reason: 'a fresh delegate was built');

      final r2 = await client.get(Uri.parse('https://example.test/'));
      expect(r2.body, 'c1', reason: 'requests now hit the fresh delegate');
      expect(made[1].closed, isFalse);
    });

    test('close closes the inner, and reset is then a no-op', () {
      final (:client, :made) = _build();

      client.close();
      expect(made[0].closed, isTrue);

      client.reset();
      expect(made.length, 1, reason: 'no new delegate is built after close');
    });
  });
}
