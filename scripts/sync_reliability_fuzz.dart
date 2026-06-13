import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:enough_mail/enough_mail.dart' as mail;
import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/models/account.dart' as model;

/// Kinds of faults injected by the fuzz layer.
///
/// Kept as a closed enum so [FuzzPolicy] can keep deterministic per-kind
/// counters — the same seed always produces the same sequence of decisions.
enum FuzzFault {
  imapConnectFail,
  imapLatency,
  smtpConnectFail,
  smtpLatency,
  httpConnectFail,
  httpServerError,
  httpLatency,
  httpTruncatedBody,
  httpStateMismatch,
}

/// Deterministic randomised fault policy.
///
/// Given the same [seed] and the same sequence of [shouldFire] calls, the
/// outcome is identical — so a failing fuzz run can be reproduced verbatim by
/// re-running with the printed seed.
class FuzzPolicy {
  FuzzPolicy({required this.seed, required this.probability})
      : assert(probability >= 0.0 && probability <= 1.0),
        _random = Random(seed);

  final int seed;
  final double probability;
  final Random _random;
  final Map<FuzzFault, int> _fireCounts = {
    for (final f in FuzzFault.values) f: 0,
  };

  /// Roll a die against [probability]. Returns true at most once per call.
  bool shouldFire(FuzzFault fault) {
    if (probability <= 0.0) return false;
    final fired = _random.nextDouble() < probability;
    if (fired) _fireCounts[fault] = (_fireCounts[fault] ?? 0) + 1;
    return fired;
  }

  /// Returns an integer in [min, maxExclusive). Useful for randomised latency.
  int nextInt(int min, int maxExclusive) {
    if (maxExclusive <= min) return min;
    return min + _random.nextInt(maxExclusive - min);
  }

  int fireCount(FuzzFault fault) => _fireCounts[fault] ?? 0;

  Map<FuzzFault, int> fireCountsSnapshot() => Map.unmodifiable(_fireCounts);
}

/// Wraps an IMAP connect function so that it occasionally:
///   - throws a [SocketException] before reaching the server, simulating a
///     dropped or refused TCP connection;
///   - delays the connection completing, simulating high latency.
///
/// The sync engine's existing retry / backoff path is expected to recover.
Future<mail.ImapClient> Function(
  model.Account account,
  String username,
  String password,
) wrapImapConnect(
  FuzzPolicy policy,
  Future<mail.ImapClient> Function(
    model.Account account,
    String username,
    String password,
  ) inner,
) {
  return (account, username, password) async {
    if (policy.shouldFire(FuzzFault.imapConnectFail)) {
      throw const SocketException(
        'fuzz: imap connection refused (injected fault)',
      );
    }
    if (policy.shouldFire(FuzzFault.imapLatency)) {
      await Future<void>.delayed(
        Duration(milliseconds: policy.nextInt(100, 800)),
      );
    }
    return inner(account, username, password);
  };
}

/// Wraps an SMTP connect function with the same fault model as
/// [wrapImapConnect].
Future<mail.SmtpClient> Function(
  model.Account account,
  String username,
  String password,
) wrapSmtpConnect(
  FuzzPolicy policy,
  Future<mail.SmtpClient> Function(
    model.Account account,
    String username,
    String password,
  ) inner,
) {
  return (account, username, password) async {
    if (policy.shouldFire(FuzzFault.smtpConnectFail)) {
      throw const SocketException(
        'fuzz: smtp connection refused (injected fault)',
      );
    }
    if (policy.shouldFire(FuzzFault.smtpLatency)) {
      await Future<void>.delayed(
        Duration(milliseconds: policy.nextInt(100, 800)),
      );
    }
    return inner(account, username, password);
  };
}

/// HTTP client that injects randomised faults into JMAP traffic.
///
/// Faults are gated on [FuzzPolicy.shouldFire] so the same seed always
/// reproduces the same sequence. None of the faults are catastrophic — they
/// all map onto error paths the sync engine is expected to recover from
/// (connection error, 5xx, truncated body, JMAP `stateMismatch`).
class FuzzHttpClient extends http.BaseClient {
  FuzzHttpClient(this.policy, this._inner);

  final FuzzPolicy policy;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (policy.shouldFire(FuzzFault.httpConnectFail)) {
      throw http.ClientException(
        'fuzz: http connection reset (injected fault)',
        request.url,
      );
    }

    if (policy.shouldFire(FuzzFault.httpLatency)) {
      await Future<void>.delayed(
        Duration(milliseconds: policy.nextInt(100, 800)),
      );
    }

    if (policy.shouldFire(FuzzFault.httpServerError)) {
      // 503: enough to look like a transient server-side problem.
      final body = utf8.encode('{"error":"fuzz injected 503"}');
      return http.StreamedResponse(
        Stream<List<int>>.value(body),
        503,
        contentLength: body.length,
        request: request,
        headers: const {'content-type': 'application/json'},
        reasonPhrase: 'Service Unavailable (fuzz)',
      );
    }

    // Provoke the JMAP `stateMismatch` recovery path. The sync engine should
    // clear its cached state token and force a re-fetch on the next cycle.
    if (policy.shouldFire(FuzzFault.httpStateMismatch)) {
      final body = utf8.encode(
        jsonEncode({
          'sessionState': 'fuzz-${policy.nextInt(1000, 99999)}',
          'methodResponses': [
            [
              'error',
              {'type': 'stateMismatch', 'description': 'fuzz injected'},
              'c1',
            ],
          ],
        }),
      );
      return http.StreamedResponse(
        Stream<List<int>>.value(body),
        200,
        contentLength: body.length,
        request: request,
        headers: const {'content-type': 'application/json'},
      );
    }

    final response = await _inner.send(request);

    if (policy.shouldFire(FuzzFault.httpTruncatedBody)) {
      // Replace the stream with one that closes after a short prefix — surfaces
      // as a parse error in the engine.
      final truncated = response.stream.asyncExpand<List<int>>(
        (chunk) async* {
          if (chunk.length <= 4) {
            yield chunk;
          } else {
            yield chunk.sublist(0, chunk.length ~/ 2);
          }
        },
      ).take(1);
      return http.StreamedResponse(
        truncated,
        response.statusCode,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    }

    return response;
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
