import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'package:sharedinbox/core/utils/host_utils.dart';
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
    jmapUrl = sessionUrlFor(jmapUrl);
    // The session GET carries `Authorization: Basic`, so refuse to make it over
    // cleartext: https anywhere, http only to a localhost dev server. A
    // relative or scheme-less URL is rejected too — there is nothing for it to
    // inherit from at the entry point (#1018). [fetchSession] enforces this on
    // the first hop and on every redirect (#1104).
    final credentials = base64.encode(utf8.encode('$username:$password'));
    JmapSessionResponse session;
    http.Response resp;
    var rateLimitAttempt = 0;
    var transientAttempt = 0;
    while (true) {
      try {
        session = await fetchSession(
          httpClient: httpClient,
          sessionUrl: jmapUrl,
          credentials: credentials,
        );
        resp = session.response;
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

    // Relative URLs in the session resolve against the URL the redirects
    // ended at, not the one the client started from (#1104).
    final finalUrl = session.url;
    final contentType = resp.headers['content-type'] ?? '';
    if (contentType.isNotEmpty && !contentType.contains('json')) {
      throw JmapException(
        'Expected JSON session but got $contentType — is the JMAP URL correct? ($finalUrl)',
      );
    }

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final apiUrl = _extractApiUrl(json, finalUrl);
    final accountId = _extractAccountId(json);

    final capabilities = _extractCapabilities(json);
    final uploadUrl = resolveSessionUrl(json['uploadUrl'] as String?, finalUrl);
    final downloadUrl =
        resolveSessionUrl(json['downloadUrl'] as String?, finalUrl);
    final eventSourceUrl =
        resolveSessionUrl(json['eventSourceUrl'] as String?, finalUrl);
    // These session-advertised URLs also carry the credentials (blob transfer,
    // SSE push), so a server must not be able to downgrade them to http for a
    // remote host. Validated by their real parsed host; the blob send sites
    // re-check the expanded URL, and eventSourceUrl (consumed by the push lane
    // outside this class) is guarded here.
    _requireSecureSessionUrl(uploadUrl, 'uploadUrl');
    _requireSecureSessionUrl(downloadUrl, 'downloadUrl');
    _requireSecureSessionUrl(eventSourceUrl, 'eventSourceUrl');

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
    // Validate the fully-parsed URL that will actually carry the credential:
    // Uri.host correctly separates userinfo from host, which string scanning
    // of the template cannot (http://127.0.0.1:x@evil.com/ has host evil.com).
    _requireSecureRequestUrl(url, 'uploadUrl');
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
    _requireSecureRequestUrl(url, 'downloadUrl');
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
    // apiUrl may be relative (RFC 8620 §2 allows it); a relative one inherits
    // the session's already-validated scheme.
    final resolved = sessionUri.resolve(raw);
    // Every call() request goes here with the credentials, so a server that
    // returns an absolute http:// apiUrl must not be able to downgrade the
    // whole session after an https session fetch.
    if (!isSecureUrl(resolved)) {
      throw JmapException(
        'Session apiUrl is not https ($resolved) — refusing to send '
        'credentials over cleartext.',
      );
    }
    return resolved;
  }

  /// Most redirect hops [fetchSession] follows before giving up.
  static const maxSessionRedirects = 5;

  /// Upper bound for one whole [fetchSession], all hops together. Each hop
  /// alone is bounded by its `timeout`; without this, hops × per-hop timeout
  /// (× the retries in [connect]) could stall a sync cycle for minutes.
  static const sessionFetchDeadline = Duration(seconds: 30);

  /// GETs the JMAP Session object at [sessionUrl] with Basic [credentials],
  /// following redirects by hand (#1104).
  ///
  /// RFC 8620 §2.2 expects `/.well-known/jmap` to redirect (Stalwart answers
  /// `307 → /jmap/session`), so this is the common path, not an edge case.
  /// Following by hand is defence in depth: the credential rule no longer
  /// depends on the SDK's redirect policy (current dart:io drops
  /// `Authorization` on cross-origin redirects, but older SDKs that pubspec
  /// still allows matched only host/subdomain, ignoring the scheme), and the
  /// URL the redirects end at is known, so relative URLs in the session can be
  /// resolved against it.
  ///
  /// The rules: every hop, the first included, must pass [isSecureUrl]; a
  /// redirect is followed — with the credentials — only to the same origin
  /// (scheme, host and port) as the current URL. A cross-origin `Location`
  /// (another host, a protocol-relative `//host/…`, an https→http downgrade
  /// even to localhost) fails with a [JmapException] naming the target, so
  /// the user can enter it as the JMAP URL deliberately. A relative `Location`
  /// resolves against the current URL; at most [maxSessionRedirects] hops are
  /// followed.
  ///
  /// Returns the last response (any status; a 3xx without `Location` is
  /// returned as is) and the URL it came from. [timeout] bounds each hop,
  /// including reading its body, and [deadline] the whole fetch; both throw
  /// [TimeoutException].
  ///
  /// Shared by [connect] and ConnectionTestService, the two callers that send
  /// credentials to the session URL.
  static Future<JmapSessionResponse> fetchSession({
    required http.Client httpClient,
    required Uri sessionUrl,
    required String credentials,
    Duration timeout = metadataTimeout,
    Duration deadline = sessionFetchDeadline,
  }) async {
    if (!isSecureUrl(sessionUrl)) {
      throw JmapException(
        'JMAP URL must use https ($sessionUrl) — refusing to send credentials '
        'over cleartext. http is allowed only for a localhost dev server.',
      );
    }
    final elapsed = Stopwatch()..start();
    var url = sessionUrl;
    for (var redirects = 0;; redirects++) {
      final remaining = deadline - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'JMAP session fetch from $sessionUrl took longer than $deadline',
          deadline,
        );
      }
      final request = http.Request('GET', url)
        ..followRedirects = false
        ..headers['Authorization'] = 'Basic $credentials';
      final resp = await Future(
        () async => http.Response.fromStream(await httpClient.send(request)),
      ).timeout(remaining < timeout ? remaining : timeout);
      final location = resp.headers['location'];
      if (!_isRedirect(resp.statusCode) || location == null) {
        return JmapSessionResponse(response: resp, url: url);
      }
      if (redirects >= maxSessionRedirects) {
        throw JmapException(
          'Too many redirects fetching the JMAP session from $sessionUrl '
          '(more than $maxSessionRedirects).',
        );
      }
      final Uri next;
      try {
        next = url.resolve(location);
      } on FormatException {
        throw JmapException(
          'JMAP session URL $url redirects to an invalid location '
          '("$location").',
        );
      }
      if (!_isSameOrigin(url, next)) {
        throw JmapException(
          'The server redirects the JMAP session from $url to $next — '
          'refusing to send credentials to another origin. If that is the '
          'right server, enter $next as the JMAP URL.',
        );
      }
      url = next;
    }
  }

  static bool _isSameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  /// Resolves a session-advertised URL or URI template [raw] (`uploadUrl`,
  /// `downloadUrl`, `eventSourceUrl`) against the session's final [base] URL
  /// when it is relative. The `{…}` placeholders are masked while resolving so
  /// URI normalization cannot percent-encode them. Absolute, empty and null
  /// values come back unchanged.
  @visibleForTesting
  static String? resolveSessionUrl(String? raw, Uri base) {
    if (raw == null || raw.isEmpty) return raw;
    final placeholders = <String>[];
    final masked = raw.replaceAllMapped(RegExp(r'\{[^}]*\}'), (m) {
      placeholders.add(m[0]!);
      return 'jmapph${placeholders.length - 1}x';
    });
    final parsed = Uri.tryParse(masked);
    if (parsed == null || parsed.hasScheme) return raw;
    var resolved = base.resolveUri(parsed).toString();
    for (var i = 0; i < placeholders.length; i++) {
      resolved = resolved.replaceFirst('jmapph${i}x', placeholders[i]);
    }
    return resolved;
  }

  /// The JMAP session URL for what the user typed as "JMAP API URL".
  ///
  /// A bare server address ("https://mail.example.com") gets the standard
  /// discovery path `/.well-known/jmap` (RFC 8620 §2.2). Used as is, it
  /// fetched the server's home page and failed with "Not a JMAP server",
  /// although the server was fine. Any other path is taken as the session
  /// URL itself.
  static Uri sessionUrlFor(Uri url) => url.path.isEmpty || url.path == '/'
      ? url.replace(path: '/.well-known/jmap')
      : url;

  /// Whether [url] may carry credentials: it must have a host, and be https to
  /// any host or http only to a localhost (or test-registered dev) host. The
  /// host check uses [Uri.host], which correctly separates userinfo from host
  /// — never string-scan an authority for this (`http://127.0.0.1:x@evil.com/`
  /// has host `evil.com`, not `127.0.0.1`). A scheme-less/host-less URL is not
  /// secure on its own. The plaintext carve-out ([isPlaintextAllowedHost]) is
  /// shared with ManageSieveClient and inert in release builds.
  ///
  /// Public so the other credential-bearing JMAP path (ConnectionTestService,
  /// which does not go through [connect]) enforces the identical rule.
  static bool isSecureUrl(Uri url) {
    if (url.host.isEmpty) return false;
    if (url.scheme == 'https') return true;
    return url.scheme == 'http' && isPlaintextAllowedHost(url.host);
  }

  /// Throws unless [url] — the fully-parsed URL a request is about to send the
  /// credential to — is secure. Used at every credential-bearing send site.
  static void _requireSecureRequestUrl(Uri url, String label) {
    if (isSecureUrl(url)) return;
    throw JmapException(
      '$label ($url) is not https — refusing to send credentials over '
      'cleartext. Use https (or localhost for development).',
    );
  }

  /// Connect-time guard for a session-advertised URL [raw] (RFC 8620/8887 URI
  /// templates like `uploadUrl`/`eventSourceUrl`). Substitutes the `{…}`
  /// placeholders with a dummy so the value parses, then validates the REAL
  /// parsed host via [isSecureUrl] — fails early and clearly rather than at
  /// first blob/push use. (The send sites re-check the expanded URL too.)
  static void _requireSecureSessionUrl(String? raw, String label) {
    if (raw == null || raw.isEmpty) return;
    final uri = Uri.tryParse(raw.replaceAll(RegExp(r'\{[^}]*\}'), 'x'));
    if (uri != null && isSecureUrl(uri)) return;
    throw JmapException(
      '$label ($raw) is not an https URL — refusing to send credentials over '
      'cleartext. Use https (or localhost for development).',
    );
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

/// The result of [JmapClient.fetchSession]: the final [response] and the [url]
/// it was fetched from after following redirects.
class JmapSessionResponse {
  JmapSessionResponse({required this.response, required this.url});

  final http.Response response;
  final Uri url;
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
