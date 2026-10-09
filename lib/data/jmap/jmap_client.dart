import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'package:sharedinbox/data/imap/imap_client_factory.dart'
    show verboseLogKey;

const _coreUsing = ['urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:mail'];

const _submissionCapability = 'urn:ietf:params:jmap:submission';
const _sieveCapability = 'urn:ietf:params:jmap:sieve';

/// A connected JMAP session. Fetch via [JmapClient.connect].
///
/// Parses the JMAP Session object (RFC 8620 §2), stores the resolved
/// [apiUrl] and server-side [accountId], and wraps API calls in [call].
class JmapClient {
  JmapClient._({
    required http.Client httpClient,
    required String credentials,
    required Uri apiUrl,
    required String accountId,
    required Set<String> capabilities,
    String? uploadUrl,
    String? downloadUrl,
    String? eventSourceUrl,
  })  : _httpClient = httpClient,
        _credentials = credentials,
        _apiUrl = apiUrl,
        _accountId = accountId,
        _capabilities = capabilities,
        _uploadUrl = uploadUrl,
        _downloadUrl = downloadUrl,
        _eventSourceUrl = eventSourceUrl;

  final http.Client _httpClient;
  final String _credentials;
  final Uri _apiUrl;
  final String _accountId;
  final Set<String> _capabilities;
  final String? _uploadUrl;
  final String? _downloadUrl;
  final String? _eventSourceUrl;

  String get accountId => _accountId;

  /// Whether the server supports `EmailSubmission/set` (RFC 8621 §7).
  bool get supportsSubmission => _capabilities.contains(_submissionCapability);

  /// Whether the server supports Sieve script management (RFC 9661).
  bool get supportsSieve => _capabilities.contains(_sieveCapability);

  /// All capability URNs advertised by the server's Session object
  /// (RFC 8620 §2), e.g. `urn:ietf:params:jmap:core`.
  Set<String> get capabilities => _capabilities;

  /// SSE push URL advertised by the server, or null if push is unsupported.
  String? get eventSourceUrl => _eventSourceUrl;

  /// Request timeout for an API call that only moves metadata — ids, flags,
  /// mailboxes, state tokens. Those payloads are small in both directions, so
  /// a server that has not answered within this long is not about to.
  static const metadataTimeout = Duration(seconds: 10);

  /// Request timeout for an API call the server cannot answer from an index
  /// alone, and so needs a far larger budget than a metadata round trip:
  ///
  /// - `Email/get` with `fetchTextBodyValues` / `fetchHTMLBodyValues`, which
  ///   has to read and serialize every requested message first;
  /// - `Email/query` with `calculateTotal`, which forces a server-side count
  ///   of the whole result set.
  ///
  /// One flat 10 s for everything was enough to fail a routine catch-up
  /// against a demonstrably healthy server, and because the failure surfaced
  /// as a `TimeoutException` it was reported to the user as "could not reach
  /// the mail server" (issue #967).
  static const slowRequestTimeout = Duration(seconds: 60);

  /// Timeout for moving a whole blob in or out (attachment upload/download).
  /// Bounded by the attachment size and the user's uplink, not by server
  /// think-time.
  static const blobTimeout = Duration(seconds: 30);

  /// Total attempts for the session fetch in [connect] before giving up on a
  /// timeout or transient transport error (1 initial + retries).
  ///
  /// The session `GET` is the *first* request of every sync cycle, so on
  /// mobile it runs against the worst-case radio state: a cold/dozed data
  /// connection that needs to be brought up, or a keep-alive socket the
  /// carrier already killed while the client slept. A single slow or dead
  /// first attempt would otherwise fail the whole cycle with `0 fetched`
  /// (issue #1012), even though the very next attempt usually succeeds.
  ///
  /// Kept deliberately small: [Future.timeout] does not cancel the underlying
  /// request, so each timed-out attempt leaves one request in flight, and
  /// [connect] runs several times per cycle — a generous count would multiply
  /// [metadataTimeout] waits under a genuinely bad connection.
  static const _connectMaxAttempts = 3;

  /// Fetches the JMAP Session object from [jmapUrl] and returns a connected
  /// client. Throws [JmapException] on HTTP errors or missing capabilities.
  static Future<JmapClient> connect({
    required http.Client httpClient,
    required Uri jmapUrl,
    required String username,
    required String password,
  }) async {
    final credentials = base64.encode(utf8.encode('$username:$password'));
    http.Response resp;
    var rateLimitAttempt = 0;
    var transientAttempt = 0;
    while (true) {
      try {
        resp = await httpClient.get(
          jmapUrl,
          headers: {
            'Authorization': 'Basic $credentials',
          },
        ).timeout(metadataTimeout);
      } on Exception catch (e) {
        // A slow first request (cold/dozed radio) throws TimeoutException; a
        // dropped or stale pooled socket surfaces from IOClient as a
        // ClientException. Both are worth a bounded retry; anything else
        // (e.g. a programming error) propagates.
        final transient = e is TimeoutException || e is http.ClientException;
        if (!transient || transientAttempt >= _connectMaxAttempts - 1) rethrow;
        // Cumulative across the whole connect() — not reset by an intervening
        // 429 retry — so the total number of attempts stays bounded.
        transientAttempt++;
        await Future<void>.delayed(
          Duration(milliseconds: 300 * transientAttempt),
        );
        continue;
      }
      if (resp.statusCode != 429 || rateLimitAttempt >= 4) {
        break;
      }
      rateLimitAttempt++;
      await Future<void>.delayed(
        Duration(milliseconds: 200 * rateLimitAttempt),
      );
    }

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw JmapException('Authentication failed (HTTP ${resp.statusCode})');
    }
    if (resp.statusCode != 200) {
      throw JmapException('Session fetch failed (HTTP ${resp.statusCode})');
    }

    final contentType = resp.headers['content-type'] ?? '';
    if (contentType.isNotEmpty && !contentType.contains('json')) {
      throw JmapException(
        'Expected JSON session but got $contentType — is the JMAP URL correct? ($jmapUrl)',
      );
    }

    final session = jsonDecode(resp.body) as Map<String, dynamic>;
    final apiUrl = _extractApiUrl(session, jmapUrl);
    final accountId = _extractAccountId(session);

    final capabilities = _extractCapabilities(session);
    final uploadUrl = session['uploadUrl'] as String?;
    final downloadUrl = session['downloadUrl'] as String?;
    final eventSourceUrl = session['eventSourceUrl'] as String?;

    return JmapClient._(
      httpClient: httpClient,
      credentials: credentials,
      apiUrl: apiUrl,
      accountId: accountId,
      capabilities: capabilities,
      uploadUrl: uploadUrl,
      downloadUrl: downloadUrl,
      eventSourceUrl: eventSourceUrl,
    );
  }

  /// Issues a JMAP API request with [methodCalls].
  ///
  /// Each call is a triple `[methodName, arguments, callId]`.
  /// Returns the raw `methodResponses` list from the server.
  ///
  /// Pass [withSubmission] to include `urn:ietf:params:jmap:submission` in
  /// the `using` declaration (required for `EmailSubmission/set` calls).
  ///
  /// Pass [timeout] to override the budget this call is given. By default it is
  /// derived from the request: [slowRequestTimeout] when a method call asks
  /// the server for real work, [metadataTimeout] otherwise.
  ///
  /// Throws [JmapException] on HTTP errors or a top-level JMAP error response.
  Future<List<dynamic>> call(
    List<List<dynamic>> methodCalls, {
    bool withSubmission = false,
    bool withSieve = false,
    Duration? timeout,
  }) async {
    final using = [
      ..._coreUsing,
      if (withSubmission) _submissionCapability,
      if (withSieve) _sieveCapability,
    ];
    final body = jsonEncode({'using': using, 'methodCalls': methodCalls});

    final resp = await _httpClient
        .post(
          _apiUrl,
          headers: {
            'Authorization': 'Basic $_credentials',
            'Content-Type': 'application/json',
          },
          body: body,
        )
        .timeout(timeout ?? defaultTimeoutFor(methodCalls));

    final log = Zone.current[verboseLogKey] as StringBuffer?;
    if (log != null) {
      log.writeln('JMAP → POST $_apiUrl');
      log.writeln(body);
      log.writeln('JMAP ← ${resp.statusCode}');
      log.writeln(resp.body);
    }

    if (resp.statusCode != 200) {
      throw JmapException('API call failed (HTTP ${resp.statusCode})');
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;

    // Top-level error (e.g. unknownCapability)
    if (decoded.containsKey('type')) {
      throw JmapException(
        'JMAP error: ${decoded['type']} — ${decoded['description'] ?? ''}',
      );
    }

    return decoded['methodResponses'] as List<dynamic>;
  }

  /// Picks the request budget from what [methodCalls] asks the server to do.
  ///
  /// Deliberately derived here rather than passed in at each of the ~40 call
  /// sites: a new expensive call then cannot forget to ask for the larger
  /// budget, which is how the original flat 10 s went unnoticed.
  ///
  /// Response-shaped only — it says nothing about how long a large *upload*
  /// (an `Email/set` with inline `bodyValues`, a `SieveScript/set`) takes the
  /// server to accept. Those keep the short budget, as they always had.
  @visibleForTesting
  static Duration defaultTimeoutFor(List<List<dynamic>> methodCalls) {
    for (final methodCall in methodCalls) {
      if (methodCall.length < 2) continue;
      final args = methodCall[1];
      if (args is! Map) continue;
      if (args['fetchTextBodyValues'] == true ||
          args['fetchHTMLBodyValues'] == true ||
          args['fetchAllBodyValues'] == true ||
          args['calculateTotal'] == true) {
        return slowRequestTimeout;
      }
    }
    return metadataTimeout;
  }

  /// Uploads [data] as a blob and returns the server-assigned `blobId`.
  ///
  /// Used to attach files to outgoing emails before calling `Email/set`.
  Future<String> uploadBlob(Uint8List data, String contentType) async {
    if (_uploadUrl == null) {
      throw JmapException('Server does not advertise an uploadUrl');
    }
    final url = Uri.parse(
      _uploadUrl.replaceAll('{accountId}', Uri.encodeComponent(_accountId)),
    );
    final resp = await _httpClient
        .post(
          url,
          headers: {
            'Authorization': 'Basic $_credentials',
            'Content-Type': contentType,
          },
          body: data,
        )
        .timeout(blobTimeout);
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw JmapException('Blob upload failed (HTTP ${resp.statusCode})');
    }
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final blobId = decoded['blobId'] as String?;
    if (blobId == null) throw JmapException('Blob upload: missing blobId');
    return blobId;
  }

  /// Downloads a blob by [blobId] and returns its raw bytes.
  ///
  /// Uses the `downloadUrl` URI template from the Session object (RFC 8620 §6).
  Future<Uint8List> downloadBlob(
    String blobId, {
    String name = 'attachment',
    String type = 'application/octet-stream',
  }) async {
    if (_downloadUrl == null) {
      throw JmapException('Server does not advertise a downloadUrl');
    }
    final url = Uri.parse(
      _downloadUrl
          .replaceAll('{accountId}', Uri.encodeComponent(_accountId))
          .replaceAll('{blobId}', Uri.encodeComponent(blobId))
          .replaceAll('{name}', Uri.encodeComponent(name))
          .replaceAll('{type}', Uri.encodeComponent(type)),
    );
    final resp = await _httpClient.get(
      url,
      headers: {
        'Authorization': 'Basic $_credentials',
      },
    ).timeout(blobTimeout);
    if (resp.statusCode != 200) {
      throw JmapException('Blob download failed (HTTP ${resp.statusCode})');
    }
    return resp.bodyBytes;
  }

  static Uri _extractApiUrl(Map<String, dynamic> session, Uri sessionUri) {
    final raw = session['apiUrl'] as String?;
    if (raw == null || raw.isEmpty) {
      throw JmapException('Session missing apiUrl');
    }
    // apiUrl may be relative (RFC 8620 §2 allows it)
    return sessionUri.resolve(raw);
  }

  static Set<String> _extractCapabilities(Map<String, dynamic> session) {
    final caps = session['capabilities'] as Map<String, dynamic>?;
    return caps?.keys.toSet() ?? {};
  }

  static String _extractAccountId(Map<String, dynamic> session) {
    final primaryAccounts = session['primaryAccounts'] as Map<String, dynamic>?;
    final id = primaryAccounts?['urn:ietf:params:jmap:mail'] as String? ??
        primaryAccounts?['urn:ietf:params:jmap:core'] as String?;
    if (id != null) return id;

    // Fall back to first account in the accounts map
    final accounts = session['accounts'] as Map<String, dynamic>?;
    if (accounts != null && accounts.isNotEmpty) {
      return accounts.keys.first;
    }
    throw JmapException('Session has no usable accountId');
  }
}

class JmapException implements Exception {
  JmapException(this.message);
  final String message;

  @override
  String toString() => 'JmapException: $message';
}

/// Thrown when an individual email update or destroy inside an `Email/set`
/// is rejected by the server (RFC 8620 §5.3 `notUpdated` / `notDestroyed`).
///
/// This is a permanent per-item error (e.g. `notFound`, `forbidden`) rather
/// than a transient transport failure, so the pending change should be
/// discarded rather than retried indefinitely.
class JmapSetItemException implements Exception {
  JmapSetItemException(this.type, this.description);
  final String type;
  final String? description;

  @override
  String toString() =>
      'JmapSetItemException: $type${description != null ? ' — $description' : ''}';
}
