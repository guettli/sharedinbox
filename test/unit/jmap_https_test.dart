import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sharedinbox/core/utils/host_utils.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';

Map<String, dynamic> _session({
  String apiUrl = 'https://jmap.example.com/api/',
  String? uploadUrl,
  String? downloadUrl,
  String? eventSourceUrl,
}) {
  return {
    'apiUrl': apiUrl,
    if (uploadUrl != null) 'uploadUrl': uploadUrl,
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
    if (eventSourceUrl != null) 'eventSourceUrl': eventSourceUrl,
    'accounts': {
      'u1': {'name': 'alice@example.com', 'isPersonal': true},
    },
    'primaryAccounts': {
      'urn:ietf:params:jmap:core': 'u1',
      'urn:ietf:params:jmap:mail': 'u1',
    },
    'capabilities': {
      'urn:ietf:params:jmap:core': <String, dynamic>{},
      'urn:ietf:params:jmap:mail': <String, dynamic>{},
    },
    'username': 'alice@example.com',
    'state': 'st1',
  };
}

Future<JmapClient> _connect(
  String jmapUrl, {
  Map<String, dynamic>? session,
  void Function()? onRequest,
}) {
  final client = MockClient((req) async {
    onRequest?.call();
    return http.Response(jsonEncode(session ?? _session()), 200);
  });
  return JmapClient.connect(
    httpClient: client,
    jmapUrl: Uri.parse(jmapUrl),
    username: 'alice@example.com',
    password: 'hunter2',
  );
}

void main() {
  // The seam is a process-wide static; clear after every test so a host one
  // test registers can never mask a rejection another test means to assert.
  tearDown(JmapClient.debugAllowedHttpHosts.clear);

  group('isSecureUrl: userinfo cannot smuggle a cleartext remote host', () {
    test('a localhost-looking userinfo does not make a remote host safe', () {
      // Uri.host is evil.com; scanning the authority string for the host would
      // wrongly stop at the colon inside the userinfo and see 127.0.0.1.
      expect(
        JmapClient.isSecureUrl(Uri.parse('http://127.0.0.1:pw@evil.com/x')),
        isFalse,
      );
      expect(
        JmapClient.isSecureUrl(Uri.parse('http://localhost@evil.com/x')),
        isFalse,
      );
    });

    test('accepts https and http-localhost, rejects host-less', () {
      expect(
        JmapClient.isSecureUrl(Uri.parse('https://any.example/x')),
        isTrue,
      );
      expect(
        JmapClient.isSecureUrl(Uri.parse('http://localhost:8080/x')),
        isTrue,
      );
      expect(JmapClient.isSecureUrl(Uri.parse('https://')), isFalse);
    });
  });

  group('JmapClient.connect scheme enforcement', () {
    test('rejects a remote http:// URL without making the request', () async {
      var requested = false;
      await expectLater(
        _connect(
          'http://mail.example.com/jmap',
          onRequest: () => requested = true,
        ),
        throwsA(
          isA<JmapException>().having(
            (e) => e.message,
            'message',
            allOf(contains('https'), contains('mail.example.com')),
          ),
        ),
      );
      // The credential must never leave the device for a cleartext URL.
      expect(requested, isFalse);
    });

    test('rejects a scheme-less URL (nothing to inherit at the entry point)',
        () async {
      var requested = false;
      await expectLater(
        _connect('mail.example.com/jmap', onRequest: () => requested = true),
        throwsA(isA<JmapException>()),
      );
      expect(requested, isFalse);
    });

    test('allows https', () async {
      final c = await _connect('https://jmap.example.com/.well-known/jmap');
      expect(c.accountId, 'u1');
    });

    test('allows http only for a localhost dev server', () async {
      for (final host in ['localhost', '127.0.0.1']) {
        final c = await _connect('http://$host:8080/jmap');
        expect(c.accountId, 'u1', reason: host);
      }
    });

    test('rejects a server that downgrades the apiUrl to http', () async {
      // Session fetched over https, but the server returns an absolute http
      // apiUrl — every call() would then carry the credential in cleartext.
      await expectLater(
        _connect(
          'https://jmap.example.com/.well-known/jmap',
          session: _session(apiUrl: 'http://evil.example.com/api/'),
        ),
        throwsA(
          isA<JmapException>()
              .having((e) => e.message, 'message', contains('apiUrl')),
        ),
      );
    });

    test('a relative apiUrl inherits the https session scheme', () async {
      final c = await _connect(
        'https://jmap.example.com/.well-known/jmap',
        session: _session(apiUrl: '/api/'),
      );
      expect(c.accountId, 'u1');
    });

    test('rejects a userinfo-smuggled http uploadUrl at connect', () async {
      // Session fetched over https, but a malicious server advertises an
      // uploadUrl whose userinfo mimics localhost while the real host is
      // remote. Must be rejected (the host is evil.com, not 127.0.0.1).
      await expectLater(
        _connect(
          'https://jmap.example.com/.well-known/jmap',
          session: _session(
            uploadUrl: 'http://127.0.0.1:pw@evil.com/upload/{accountId}',
          ),
        ),
        throwsA(isA<JmapException>()),
      );
    });

    test('rejects an http uploadUrl / downloadUrl / eventSourceUrl', () async {
      for (final s in [
        _session(uploadUrl: 'http://cdn.example.com/upload/{accountId}'),
        _session(downloadUrl: 'http://cdn.example.com/dl/{accountId}/{blobId}'),
        _session(eventSourceUrl: 'http://push.example.com/events'),
      ]) {
        await expectLater(
          _connect('https://jmap.example.com/.well-known/jmap', session: s),
          throwsA(isA<JmapException>()),
        );
      }
    });

    test('allows an http localhost uploadUrl (dev) and https remote ones',
        () async {
      final dev = await _connect(
        'http://localhost:8080/jmap',
        session: _session(
          uploadUrl: 'http://localhost:8080/upload/{accountId}',
        ),
      );
      expect(dev.accountId, 'u1');

      final prod = await _connect(
        'https://jmap.example.com/.well-known/jmap',
        session: _session(
          uploadUrl: 'https://jmap.example.com/upload/{accountId}',
        ),
      );
      expect(prod.accountId, 'u1');
    });
  });

  group('validateJmapUrl', () {
    test('rejects empty', () => expect(validateJmapUrl(''), 'Required'));

    test('rejects a remote http URL', () {
      expect(validateJmapUrl('http://mail.example.com/jmap'), isNotNull);
    });

    test('rejects a scheme-less or malformed value', () {
      expect(validateJmapUrl('mail.example.com/jmap'), isNotNull);
      expect(validateJmapUrl('https://'), isNotNull);
    });

    test('accepts https', () {
      expect(validateJmapUrl('https://mail.example.com/jmap'), isNull);
    });

    test('accepts http only for localhost', () {
      expect(validateJmapUrl('http://localhost:8080/jmap'), isNull);
      expect(validateJmapUrl('http://127.0.0.1/jmap'), isNull);
    });
  });

  group('debugAllowedHttpHosts seam', () {
    test('off by default; a registered dev host is then allowed over http',
        () async {
      // Unregistered: a non-localhost http host is rejected like any other.
      await expectLater(
        _connect('http://devbox.test:8080/jmap'),
        throwsA(isA<JmapException>()),
      );
      // Registered (as the backend harness does for the dev Stalwart host):
      // http to exactly that host is allowed. The guard is additionally gated
      // on !kReleaseMode in production, so this set is inert in a shipped app.
      JmapClient.debugAllowedHttpHosts.add('devbox.test');
      final c = await _connect('http://devbox.test:8080/jmap');
      expect(c.accountId, 'u1');
      // Still scoped to the one host — a different http host stays rejected.
      await expectLater(
        _connect('http://other.test:8080/jmap'),
        throwsA(isA<JmapException>()),
      );
    });

    test('also admits an http session URL (upload/apiUrl) for that host',
        () async {
      JmapClient.debugAllowedHttpHosts.add('devbox.test');
      final c = await _connect(
        'http://devbox.test:8080/jmap',
        session: _session(
          apiUrl: 'http://devbox.test:8080/api/',
          uploadUrl: 'http://devbox.test:8080/upload/{accountId}',
        ),
      );
      expect(c.accountId, 'u1');
    });
  });
}
