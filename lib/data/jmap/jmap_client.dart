import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

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

  /// SSE push URL advertised by the server, or null if push is unsupported.
  String? get eventSourceUrl => _eventSourceUrl;

  /// Fetches the JMAP Session object from [jmapUrl] and returns a connected
  /// client. Throws [JmapException] on HTTP errors or missing capabilities.
  static Future<JmapClient> connect({
    required http.Client httpClient,
    required Uri jmapUrl,
    required String username,
    required String password,
  }) async {
    final credentials = base64.encode(utf8.encode('$username:$password'));
    final resp = await _retryOn429(
      () => httpClient.get(
        jmapUrl,
        headers: {
          'Authorization': 'Basic $credentials',
        },
      ).timeout(const Duration(seconds: 10)),
    );

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
  /// Throws [JmapException] on HTTP errors or a top-level JMAP error response.
  Future<List<dynamic>> call(
    List<List<dynamic>> methodCalls, {
    bool withSubmission = false,
    bool withSieve = false,
  }) async {
    final using = [
      ..._coreUsing,
      if (withSubmission) _submissionCapability,
      if (withSieve) _sieveCapability,
    ];
    final body = jsonEncode({'using': using, 'methodCalls': methodCalls});

    final resp = await _retryOn429(
      () => _httpClient
          .post(
            _apiUrl,
            headers: {
              'Authorization': 'Basic $_credentials',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10)),
    );

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
    final resp = await _retryOn429(
      () => _httpClient
          .post(
            url,
            headers: {
              'Authorization': 'Basic $_credentials',
              'Content-Type': contentType,
            },
            body: data,
          )
          .timeout(const Duration(seconds: 10)),
    );
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
    final resp = await _retryOn429(
      () => _httpClient.get(
        url,
        headers: {
          'Authorization': 'Basic $_credentials',
        },
      ).timeout(const Duration(seconds: 30)),
    );
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

  // Retries a JMAP request when the server returns 429 (Too Many Requests) OR
  // when the connection drops mid-request (Broken pipe, Connection reset,
  // SocketException — all surfaced as http.ClientException). Stalwart under
  // heavy test load produces both: it returns 429 from one request and
  // silently closes a kept-alive socket on the next.
  //
  // Honours the Retry-After header on 429; otherwise backs off exponentially
  // starting at 200 ms (max ~12 s total across 6 retries).
  static Future<http.Response> _retryOn429(
    Future<http.Response> Function() send, {
    int maxAttempts = 6,
  }) async {
    var attempt = 0;
    while (true) {
      http.Response? resp;
      http.ClientException? transportError;
      Duration? retryAfter;
      try {
        resp = await send();
        if (resp.statusCode != 429) return resp;
        retryAfter = _parseRetryAfter(resp.headers['retry-after']);
      } on http.ClientException catch (e) {
        transportError = e;
      }
      if (attempt >= maxAttempts) {
        if (transportError != null) throw transportError;
        return resp!;
      }
      attempt++;
      final backoff =
          retryAfter ?? Duration(milliseconds: 200 * (1 << (attempt - 1)));
      await Future<void>.delayed(backoff);
    }
  }

  // Parses a Retry-After header (RFC 9110 §10.2.3). Supports the delta-seconds
  // form; HTTP-date form is treated as unparseable (we fall back to backoff).
  static Duration? _parseRetryAfter(String? header) {
    if (header == null) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds == null || seconds < 0) return null;
    // Cap to keep a misbehaving server from hanging the sync loop.
    return Duration(seconds: seconds.clamp(0, 10));
  }
}

class JmapException implements Exception {
  JmapException(this.message);
  final String message;

  @override
  String toString() => 'JmapException: $message';
}

/// Thrown when the server rejects an `Email/set` because our `ifInState`
/// token no longer matches the server's current state (RFC 8620 §5.3).
class JmapStateMismatchException implements Exception {
  const JmapStateMismatchException();

  @override
  String toString() => 'JmapStateMismatchException: state token is stale';
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
