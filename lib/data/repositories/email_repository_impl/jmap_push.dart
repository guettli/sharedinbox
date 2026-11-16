part of '../email_repository_impl.dart';

// JMAP push (EventSource) watching.

// ── JMAP push ────────────────────────────────────────────────────────────

/// Expands the RFC 8620 §7.3 `eventSourceUrl` URI template.
///
/// Servers advertise a template such as
/// `.../eventsource/?types={types}&closeafter={closeafter}&ping={ping}`.
/// Sending it verbatim — with the literal `{…}` placeholders still in the
/// query string — makes servers reject the request with HTTP 400, which
/// silently drops the account back to the 30 s poll. We subscribe to all
/// types, keep the stream open, and ask for a 30 s keep-alive ping to
/// survive NAT/proxy idle timeouts (and so that silence means a dead
/// connection — see [_sseSilenceTimeout]).
String _expandEventSourceUrl(String template) {
  return template
      .replaceAll('{types}', '*')
      .replaceAll('{closeafter}', 'no')
      .replaceAll('{ping}', '30');
}

/// How long the SSE stream may stay silent before it counts as dead. It is
/// an inactivity timeout (reset by every chunk, pings included), not a cap
/// on the stream's lifetime. A blackholed connection (open, but no bytes
/// flow) never reports its loss, so this is what ends it; it used to be 25
/// minutes, during which the account saw no push. Ten missed 30 s pings
/// leaves room for a server that stretches the interval we ask for.
const _sseSilenceTimeout = Duration(minutes: 5);

/// Strips any embedded `user:pass@` userinfo from [url] so it is safe to
/// persist in the app log. JMAP SSE auth travels in the `Authorization`
/// header rather than the URL, so this is belt-and-braces.
String _redactUrl(String url) {
  try {
    final uri = Uri.parse(url);
    if (uri.userInfo.isEmpty) return url;
    return uri.replace(userInfo: '').toString();
  } catch (_) {
    return url;
  }
}

/// Drains a failed SSE [response] body into a short string for logging.
/// Truncated so a chatty HTML error page can't bloat the app log.
Future<String> _readSseErrorBody(
  http.StreamedResponse response,
) async {
  try {
    final body = (await response.stream.bytesToString()).trim();
    return body.length > 500 ? '${body.substring(0, 500)}…' : body;
  } catch (_) {
    return '';
  }
}

extension _JmapPush on EmailRepositoryImpl {
  /// Records the outcome of a `watchJmapPush` subscription as a
  /// `sync.jmap.push` app-log row. The `status` value is stable and used by
  /// the sync-state view to render a human-readable "Push" row — see
  /// `push_status.dart` for the enum of accepted values.
  Future<void> _logPushStatus(
    String accountId,
    String status,
    String message, {
    AppLogLevel level = AppLogLevel.info,
    Map<String, Object?>? data,
  }) async {
    final logger = _appLogger;
    if (logger == null) return;
    await logger.log(
      level: level,
      event: 'sync.jmap.push',
      message: message,
      accountId: accountId,
      data: {'push_status': status, ...?data},
    );
  }

  Stream<void> _watchJmapPush(String accountId, String password) {
    final controller = StreamController<void>();
    StreamSubscription<String>? innerSub;

    controller.onCancel = () => innerSub?.cancel();

    unawaited(() async {
      try {
        final account = await _accounts.getAccount(accountId);
        if (account == null || account.type != account_model.AccountType.jmap) {
          await controller.close();
          return;
        }

        final jmapUrl = account.jmapUrl;
        if (jmapUrl == null || jmapUrl.isEmpty) {
          unawaited(
            _logPushStatus(
              accountId,
              JmapPushStatus.unsupported.wireName,
              'JMAP push disabled: account has no JMAP URL',
            ),
          );
          await controller.close();
          return;
        }

        final JmapClient jmap;
        try {
          jmap = await JmapClient.connect(
            httpClient: _httpClient,
            jmapUrl: Uri.parse(jmapUrl),
            username: _effectiveUsername(account),
            password: password,
          );
        } catch (e) {
          log('JMAP push: connect failed: $e');
          unawaited(
            _logPushStatus(
              accountId,
              JmapPushStatus.connectFailed.wireName,
              'JMAP push: session connect failed: $e',
              level: AppLogLevel.warn,
              data: {'error': e.toString()},
            ),
          );
          await controller.close();
          return;
        }

        final sseUrl = jmap.eventSourceUrl;
        if (sseUrl == null) {
          unawaited(
            _logPushStatus(
              accountId,
              JmapPushStatus.unsupported.wireName,
              'JMAP push unavailable: server does not advertise '
              'an eventSourceUrl (falling back to poll)',
            ),
          );
          await controller.close();
          return;
        }

        // The advertised URL is an RFC 8620 §7.3 URI template — expand the
        // `{types}`/`{closeafter}`/`{ping}` placeholders before requesting it,
        // or the server rejects the literal `{…}` query with HTTP 400.
        final resolvedSseUrl = _expandEventSourceUrl(sseUrl);
        final redactedSseUrl = _redactUrl(resolvedSseUrl);

        final credentials = base64.encode(
          utf8.encode('${_effectiveUsername(account)}:$password'),
        );

        http.StreamedResponse response;
        try {
          final request = http.Request('GET', Uri.parse(resolvedSseUrl));
          request.headers['Accept'] = 'text/event-stream';
          request.headers['Authorization'] = 'Basic $credentials';
          response = await _httpClient
              .send(request)
              .timeout(const Duration(seconds: 10));
          if (response.statusCode != 200) {
            final body = await _readSseErrorBody(response);
            unawaited(
              _logPushStatus(
                accountId,
                '${JmapPushStatus.sseStatusPrefix.wireName}'
                    '${response.statusCode}',
                'JMAP push: SSE endpoint returned HTTP '
                    '${response.statusCode}',
                level: AppLogLevel.warn,
                data: {
                  'httpStatus': response.statusCode,
                  'sseUrl': redactedSseUrl,
                  if (body.isNotEmpty) 'responseBody': body,
                },
              ),
            );
            await controller.close();
            return;
          }
        } catch (e) {
          log('JMAP push: SSE request failed: $e');
          unawaited(
            _logPushStatus(
              accountId,
              JmapPushStatus.sseFailed.wireName,
              'JMAP push: SSE request failed: $e',
              level: AppLogLevel.warn,
              data: {'error': e.toString(), 'sseUrl': redactedSseUrl},
            ),
          );
          await controller.close();
          return;
        }

        unawaited(
          _logPushStatus(
            accountId,
            JmapPushStatus.connected.wireName,
            'JMAP push connected — waiting for StateChange events',
            data: {'sseUrl': redactedSseUrl},
          ),
        );

        var buffer = '';
        innerSub = response.stream
            .transform(utf8.decoder)
            .timeout(_sseSilenceTimeout)
            .listen(
          (chunk) {
            buffer += chunk;
            final lines = buffer.split('\n');
            buffer = lines.removeLast();
            for (final line in lines) {
              if (!line.startsWith('data:')) continue;
              final data = line.substring(5).trim();
              try {
                final decoded = jsonDecode(data) as Map<String, dynamic>;
                if (decoded['@type'] == 'StateChange') {
                  controller.add(null);
                }
              } catch (_) {
                // Malformed JSON — ignore line
              }
            }
          },
          onDone: () {
            unawaited(
              _logPushStatus(
                accountId,
                JmapPushStatus.closed.wireName,
                'JMAP push stream ended (server closed connection)',
              ),
            );
            unawaited(controller.close());
          },
          onError: (Object e) {
            unawaited(
              _logPushStatus(
                accountId,
                JmapPushStatus.errored.wireName,
                'JMAP push stream errored: $e',
                level: AppLogLevel.warn,
                data: {'error': e.toString()},
              ),
            );
            unawaited(controller.close());
          },
          cancelOnError: true,
        );
      } catch (e) {
        log('JMAP push: unexpected error: $e');
        unawaited(
          _logPushStatus(
            accountId,
            JmapPushStatus.errored.wireName,
            'JMAP push: unexpected error: $e',
            level: AppLogLevel.warn,
            data: {'error': e.toString()},
          ),
        );
        await controller.close();
      }
    }());

    return controller.stream;
  }
}
