part of '../email_repository_impl.dart';

// Bodies, attachments and raw messages: fetch (pooled IMAP body client,
// JMAP), cache, MIME tree and body healing.

/// Recursively converts an [imap.MimePart] into a JSON-serialisable map.
Map<String, dynamic> _mimePartToJson(imap.MimePart part) {
  final ct = part.getHeaderContentType();
  final disposition = part.getHeaderContentDisposition();
  final rawEncoding =
      part.getHeader('content-transfer-encoding')?.firstOrNull?.value;
  final encoding = rawEncoding?.split(';').first.trim().toLowerCase();
  return {
    'contentType': ct?.mediaType.text ?? 'application/octet-stream',
    'filename': mimePartFileName(disposition, ct),
    'size': disposition?.size,
    'encoding': encoding,
    'children': (part.parts ?? []).map(_mimePartToJson).toList(),
  };
}

/// Builds a JSON string representing the MIME tree of [msg].
String _buildMimeTreeJson(imap.MimeMessage msg) =>
    jsonEncode(_mimePartToJson(msg));

/// Converts a JMAP `bodyStructure` object into the same JSON format used by
/// [_mimePartToJson], so [_Bodies._parseMimeTree] can deserialise it uniformly.
Map<String, dynamic> _jmapBodyStructureToJson(Map<String, dynamic> m) => {
      'contentType': m['type'] as String? ?? 'application/octet-stream',
      'filename': m['name'],
      'size': m['size'],
      'encoding': null,
      'children': ((m['subParts'] as List<dynamic>?) ?? [])
          .cast<Map<String, dynamic>>()
          .map(_jmapBodyStructureToJson)
          .toList(),
    };

// ── Body (on-demand) ───────────────────────────────────────────────────────

const _bodyCacheTtl = Duration(days: 7);

// ── Pooled IMAP connection for body fetches (#679) ───────────────────────
//
// getEmailBody used to connect and log in once per message. Gmail throttles
// rapid logins, so anything that walks a mailbox — the background prefetch in
// BodyCacheService, the "open the next message" prefetch, the read-only Gmail
// probe — eventually stalls inside LOGIN until the 20s response timeout
// fires. Keeping one connection open between fetches removes the login (and
// the TLS handshake) from every message but the first.
//
// Only one fetch may hold the pooled client at a time: an ImapClient cannot
// interleave commands. A fetch that arrives while it is busy opens its own
// connection rather than queueing, so opening a message never waits behind a
// background prefetch.

/// How long the pooled connection is kept open after the last body fetch.
const _bodyClientIdle = Duration(seconds: 30);

/// Resolves the decoded value of the first [bodyParts] entry, but only when
/// its MIME `type` equals [expectedType]. Returns null otherwise, so a
/// cross-typed fallback part (HTML listed under `textBody`, or plain text
/// listed under `htmlBody`) is not stored as if it were the other kind.
String? _jmapBodyValueOfType(
  List<dynamic> bodyParts,
  Map<String, dynamic> bodyValues,
  String expectedType,
) {
  if (bodyParts.isEmpty) return null;
  final part = bodyParts.first as Map<String, dynamic>;
  final type = (part['type'] as String?)?.toLowerCase();
  if (type != expectedType) return null;
  final partId = part['partId'] as String?;
  if (partId == null) return null;
  return (bodyValues[partId] as Map<String, dynamic>?)?['value'] as String?;
}

extension _Bodies on EmailRepositoryImpl {
  /// [prefetch] marks a background prefetch (the opportunistic next-message
  /// load on open, or the [BodyCacheService] cache warmer) so its App Log
  /// entry is distinguishable from the foreground open the user triggered
  /// (#642). It is deliberately absent from the [EmailRepository] interface —
  /// only the concrete implementation needs it.
  Future<model.EmailBody> _getEmailBody(
    String emailId, {
    bool forceRefresh = false,
    bool prefetch = false,
  }) async {
    final startedAt = DateTime.now();
    final cached = await (_db.select(
      _db.emailBodies,
    )..where((t) => t.emailId.equals(emailId)))
        .getSingleOrNull();
    if (cached != null && !forceRefresh) {
      // Re-fetch if cachedAt is null (legacy row) or older than the TTL.
      final age = cached.cachedAt == null
          ? _bodyCacheTtl + const Duration(seconds: 1)
          : DateTime.now().difference(cached.cachedAt!);
      // Also re-fetch when mimeTreeJson/headersJson are missing: such rows
      // were cached before the structure fetch existed (or before the server
      // returned bodyStructure). Without this, "Show Mail Structure" stays
      // empty for up to 7 days even after we start asking for it.
      final isMissingExtras =
          cached.mimeTreeJson == null || cached.headersJson == null;
      if (age <= _bodyCacheTtl && !isMissingExtras) {
        _logBodyLoaded(
          emailId: emailId,
          source: 'cache',
          network: false,
          prefetch: prefetch,
          cacheAgeSeconds: age.inSeconds,
        );
        final body = _bodyRowToModel(cached);
        await _backfillAddressHeaders(emailId, body.headers);
        return body;
      }
    }

    final emailRow = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    // Local self-sent "virtual" messages have no server copy to fetch — always
    // serve the cached body we wrote when the message was composed (#545).
    if (emailRow.isLocal) {
      _logBodyLoaded(
        emailId: emailId,
        accountId: emailRow.accountId,
        mailboxPath: emailRow.mailboxPath,
        source: 'local',
        network: false,
        prefetch: prefetch,
      );
      return cached != null
          ? _bodyRowToModel(cached)
          : const model.EmailBody(emailId: '', attachments: []);
    }
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);

    if (account.type == account_model.AccountType.jmap) {
      return _getEmailBodyJmap(
        emailId,
        _requireJmapId(emailRow),
        account,
        password,
        prefetch: prefetch,
        startedAt: startedAt,
      );
    }

    return _withBodyImapClient(
      account,
      _effectiveUsername(account),
      password,
      (client) async {
        // Where the server has it, not where it is shown: behind a queued
        // move the row already shows the destination.
        await client.selectUnicodeMailboxByPath(emailRow.imapServerPath);
        final fetch = await client.uidFetchMessage(
          emailRow.imapServerUid,
          '(BODY.PEEK[])',
        );
        final msg = fetch.messages.firstOrNull;
        if (msg == null) {
          throw StateError(
            'IMAP server returned no message for UID '
            '${emailRow.imapServerUid}.',
          );
        }

        // Guard against caching another message's body under this row (#616). An
        // optimistic snooze/unsnooze/move flips mailbox_path to the destination
        // but keeps the source UID until the server MOVE is remapped (see
        // [_remapEmailAfterImapMove]). If that remap never lands and the stale
        // source UID happens to also exist in the destination mailbox, this
        // (mailboxPath, uid) pair now points at an unrelated message — the fetch
        // above would silently return it. Never trust a body whose Message-ID
        // contradicts the row's; try to re-resolve the real UID instead.
        final expectedMessageId = normaliseMessageId(emailRow.messageId);
        final fetchedMessageId =
            normaliseMessageId(msg.getHeaderValue('Message-ID'));
        if (expectedMessageId != null &&
            fetchedMessageId != null &&
            expectedMessageId != fetchedMessageId) {
          // The pooled client is held until this future completes, so the
          // re-resolve search below still runs on an open connection.
          return _healMismatchedImapBody(
            client: client,
            emailId: emailId,
            emailRow: emailRow,
            cached: cached,
            expectedMessageId: expectedMessageId,
            fetchedMessageId: fetchedMessageId,
          );
        }
        // Decoding a malformed MIME message can make enough_mail throw — e.g. a
        // `RangeError (end)` on an off-by-a-few-bytes part boundary (#579), the
        // same class of bug already guarded against on the prefetch path (#232).
        // Decode each piece defensively so one bad part can't blank the whole
        // message: salvage what we can, flag the body as partial, and log so the
        // failure is discoverable in the per-message "Show Logs" view.
        var decodeFailed = false;
        Object? decodeError;
        StackTrace? decodeStack;
        T? tryDecode<T>(T Function() decode) {
          try {
            return decode();
          } catch (e, stack) {
            decodeFailed = true;
            decodeError ??= e;
            decodeStack ??= stack;
            return null;
          }
        }

        // Use the QP-recovering wrappers (#588): enough_mail throws a RangeError
        // on a quoted-printable part that ends with a dangling `=`, which would
        // otherwise drop the whole part; the wrappers salvage the content when
        // they can and only rethrow — letting tryDecode flag the body as
        // partial — when the part is genuinely unrecoverable.
        final textBody = tryDecode(() => decodeTextPlainPartSafe(msg));
        final rawHtml = tryDecode(() => decodeTextHtmlPartSafe(msg));
        final htmlBody = rawHtml == null
            ? null
            : tryDecode(() => injectInlineImages(rawHtml, msg));
        final contentInfos =
            tryDecode(msg.findContentInfo) ?? const <imap.ContentInfo>[];

        final attachmentsJson = tryDecode(
              () => jsonEncode(
                contentInfos
                    .map(
                      (a) => {
                        'filename': mimePartFileName(
                              a.contentDisposition,
                              a.contentType,
                            ) ??
                            '',
                        'contentType': a.contentType?.mediaType.text ?? '',
                        // ContentInfo.fetchId is empty for parts that aren't
                        // addressable (e.g. a non-multipart message whose
                        // top-level part is itself marked as an attachment).
                        // MimeMessage.getPart() throws on an empty fetchId, so
                        // guard before calling it.
                        'size': a.size ??
                            (a.fetchId.isNotEmpty
                                ? msg
                                    .getPart(a.fetchId)
                                    ?.decodeContentBinary()
                                    ?.length
                                : null) ??
                            0,
                        'fetchPartId': a.fetchId,
                      },
                    )
                    .toList(),
              ),
            ) ??
            '[]';

        final headersJson = tryDecode(
              () => jsonEncode(
                (msg.headers ?? [])
                    .map((h) => {'name': h.name, 'value': h.value})
                    .toList(),
              ),
            ) ??
            '[]';

        final mimeTreeJson = tryDecode(() => _buildMimeTreeJson(msg));

        if (decodeFailed) {
          unawaited(
            _appLogger?.error(
              'email.body.decode_failed',
              'Could not fully decode message body — showing what was salvaged',
              accountId: emailRow.accountId,
              mailboxPath: emailRow.mailboxPath,
              emailId: emailId,
              error: decodeError,
              stack: decodeStack,
            ),
          );
        }

        await _cacheFetchedBody(
          emailId: emailId,
          textBody: textBody,
          htmlBody: htmlBody,
          attachmentsJson: attachmentsJson,
          headersJson: headersJson,
          mimeTreeJson: mimeTreeJson,
        );

        // Opportunistic backfill for rows synced before we started writing
        // previews on the IMAP sync path. Costs no extra IMAP round trip.
        if ((emailRow.preview ?? '').isEmpty) {
          final backfill = previewFromBody(textBody, rawHtml);
          if (backfill != null && backfill.isNotEmpty) {
            await (_db.update(_db.emails)..where((t) => t.id.equals(emailId)))
                .write(EmailsCompanion(preview: Value(backfill)));
            await _updateThread(
              emailRow.accountId,
              emailRow.mailboxPath,
              emailRow.threadId ?? emailRow.id,
            );
          }
        }

        // Same opportunistic backfill for the List-Unsubscribe header (#698).
        // The full message fetched above carries every header, so a row synced
        // before we captured this field — or one where sync missed it — gets its
        // Unsubscribe button as soon as the user opens the mail, without a full
        // account resync. Costs no extra IMAP round trip.
        if ((emailRow.listUnsubscribeHeader ?? '').isEmpty) {
          final listUnsubscribe =
              msg.getHeaderValue('List-Unsubscribe')?.trim();
          if (listUnsubscribe != null && listUnsubscribe.isNotEmpty) {
            await (_db.update(_db.emails)..where((t) => t.id.equals(emailId)))
                .write(
              EmailsCompanion(listUnsubscribeHeader: Value(listUnsubscribe)),
            );
          }
        }

        // Same opportunistic backfill for Reply-To and Bcc.
        await _backfillAddressHeaders(
          emailId,
          _parseHeaders(headersJson),
          row: emailRow,
        );

        _logBodyLoaded(
          emailId: emailId,
          accountId: emailRow.accountId,
          mailboxPath: emailRow.mailboxPath,
          source: 'imap',
          network: true,
          prefetch: prefetch,
          bytes: _bodySize(textBody, htmlBody),
          durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        );

        return model.EmailBody(
          emailId: emailId,
          textBody: textBody,
          htmlBody: htmlBody,
          attachments: _parseAttachments(attachmentsJson),
          headers: _parseHeaders(headersJson),
          mimeTree: _parseMimeTree(mimeTreeJson),
          decodeFailed: decodeFailed,
        );
      },
    );
  }

  /// Runs [action] against an IMAP connection for [account], reusing the pooled
  /// one when it is free and belongs to the same account.
  Future<T> _withBodyImapClient<T>(
    account_model.Account account,
    String username,
    String password,
    Future<T> Function(imap.ImapClient client) action,
  ) async {
    if (_bodyClientBusy) {
      final client = await _imapConnect(account, username, password);
      try {
        return await action(client);
      } finally {
        await _logoutQuietly(client);
      }
    }

    _bodyClientBusy = true;
    _bodyClientIdleTimer?.cancel();
    try {
      final reused = _bodyClient != null && _bodyClientAccountId == account.id;
      if (!reused) {
        await _closePooledBodyClient();
        _bodyClient = await _imapConnect(account, username, password);
        _bodyClientAccountId = account.id;
      }
      try {
        return await action(_bodyClient!);
      } catch (e) {
        if (!reused) rethrow;
        // A pooled connection can have been dropped while it sat idle. Retry
        // once on a fresh one: the reuse is an optimisation and must never turn
        // a working fetch into a failure.
        log('IMAP: pooled body connection failed ($e) — reconnecting');
        await _closePooledBodyClient();
        _bodyClient = await _imapConnect(account, username, password);
        _bodyClientAccountId = account.id;
        return await action(_bodyClient!);
      }
    } finally {
      _bodyClientBusy = false;
      _armBodyClientIdleTimer();
    }
  }

  void _armBodyClientIdleTimer() {
    _bodyClientIdleTimer?.cancel();
    _bodyClientIdleTimer = null;
    if (_bodyClient == null) return;
    _bodyClientIdleTimer = Timer(
      _bodyClientIdle,
      () => unawaited(_closePooledBodyClient()),
    );
  }

  Future<void> _closePooledBodyClient() async {
    _bodyClientIdleTimer?.cancel();
    _bodyClientIdleTimer = null;
    final client = _bodyClient;
    _bodyClient = null;
    _bodyClientAccountId = null;
    if (client != null) await _logoutQuietly(client);
  }

  Future<void> _logoutQuietly(imap.ImapClient client) =>
      closeImapClient(client);

  /// Handles the case where a body fetch returned a message whose Message-ID
  /// contradicts the local row's (#616): the row's (mailboxPath, uid) no longer
  /// identifies the intended message. Tries to re-resolve the true UID by
  /// Message-ID in the same mailbox; on success it records that UID on the row
  /// and re-fetches under the corrected server location. When the message
  /// can't be found the stale (mailbox, uid) identity is invalid — we never cache the wrong body and
  /// return whatever we can without corrupting the cache.
  Future<model.EmailBody> _healMismatchedImapBody({
    required imap.ImapClient client,
    required String emailId,
    required Email emailRow,
    required EmailBody? cached,
    required String expectedMessageId,
    required String fetchedMessageId,
  }) async {
    final serverPath = emailRow.imapServerPath;
    final resolvedUid = await _searchUidByMessageId(
      client,
      serverPath,
      emailRow.messageId,
    );
    if (resolvedUid != null && resolvedUid != emailRow.imapServerUid) {
      await _relocateEmailRow(
        id: emailId,
        newUid: resolvedUid,
        newMailboxPath: serverPath,
        // Behind a queued move the row keeps showing the mail where the
        // user put it; only its server location is corrected.
        keepShownWhileMovedOn: true,
      );
      log(
        'getEmailBody: mis-bound row $emailId is at UID $resolvedUid in '
        '$serverPath after Message-ID mismatch '
        '(expected=$expectedMessageId, fetched=$fetchedMessageId)',
      );
      // forceRefresh bypasses the (possibly stale) cache and re-verifies
      // identity under the corrected UID.
      return getEmailBody(emailId, forceRefresh: true);
    }

    unawaited(
      _appLogger?.error(
        'email.body.identity_mismatch',
        'Skipped caching a body whose Message-ID did not match this message '
            '(expected $expectedMessageId, server returned $fetchedMessageId '
            'for UID ${emailRow.imapServerUid} in $serverPath). The message '
            'is not at that UID; the correct copy will be re-fetched on sync.',
        accountId: emailRow.accountId,
        mailboxPath: emailRow.mailboxPath,
        emailId: emailId,
      ),
    );
    // The row's (mailbox, uid) no longer identifies this message, so we have no
    // trustworthy body to show. Flag the load failure so the detail screen can
    // tell the user instead of leaving a silently blank body (#837): serve the
    // cache only when it belongs to this same message, otherwise an empty body.
    const loadError =
        'This message is no longer at its previous location. It will be '
        're-fetched on the next sync.';
    if (cached != null) {
      return _bodyRowToModel(cached).copyWith(loadError: loadError);
    }
    return model.EmailBody(
      emailId: emailId,
      attachments: const [],
      loadError: loadError,
    );
  }

  /// Caches a body just fetched from the server. The fetch can outlast the
  /// email row (a sync pruned it, the user deleted it); its body is then
  /// still shown once, but there is nothing left to cache it for.
  Future<void> _cacheFetchedBody({
    required String emailId,
    required String? textBody,
    required String? htmlBody,
    required String attachmentsJson,
    required String? headersJson,
    required String? mimeTreeJson,
  }) async {
    try {
      await _db.into(_db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: Value(textBody),
              htmlBody: Value(htmlBody),
              attachmentsJson: Value(attachmentsJson),
              headersJson: Value(headersJson),
              mimeTreeJson: Value(mimeTreeJson),
              cachedAt: Value(DateTime.now()),
              bodySize: Value(_bodySize(textBody, htmlBody)),
            ),
          );
    } catch (e) {
      if (!isForeignKeyViolation(e)) rethrow;
    }
  }

  Future<model.EmailBody> _getEmailBodyJmap(
    String emailId,
    String jmapEmailId,
    account_model.Account account,
    String password, {
    bool prefetch = false,
    DateTime? startedAt,
  }) async {
    final jmapUrl = account.jmapUrl!;
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final responses = await jmap.call([
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          'ids': [jmapEmailId],
          'properties': [
            'id',
            'headers',
            'textBody',
            'htmlBody',
            'bodyValues',
            'attachments',
            'bodyStructure',
          ],
          'fetchHTMLBodyValues': true,
          'fetchTextBodyValues': true,
          // `blobId` is required to download attachments: it is the id passed
          // to the JMAP downloadUrl. A spec-compliant server returns only the
          // body properties listed here (RFC 8621 §4.1.4), so omitting it left
          // every attachment with an empty part id and the download failed with
          // "missing part ID" (#762).
          'bodyProperties': [
            'partId',
            'blobId',
            'type',
            'name',
            'size',
            'subParts',
          ],
        },
        '0',
      ],
    ]);

    final result = _responseArgs(responses, 0, 'Email/get');
    final emailData =
        (result['list'] as List<dynamic>).first as Map<String, dynamic>;

    // Decode each piece defensively so a single malformed part can't blank the
    // whole message, mirroring the IMAP path (#579).
    var decodeFailed = false;
    Object? decodeError;
    StackTrace? decodeStack;
    T? tryDecode<T>(T Function() decode) {
      try {
        return decode();
      } catch (e, stack) {
        decodeFailed = true;
        decodeError ??= e;
        decodeStack ??= stack;
        return null;
      }
    }

    final (textBody, htmlBody, attachmentsJson) =
        tryDecode(() => _parseJmapBody(emailData)) ?? (null, null, '[]');

    final headersJson = tryDecode(
          () {
            final rawHeaders = emailData['headers'] as List<dynamic>? ?? [];
            return jsonEncode(
              rawHeaders.map((h) {
                final map = h as Map<String, dynamic>;
                return {
                  'name': map['name'] ?? '',
                  'value': map['value'] ?? '',
                };
              }).toList(),
            );
          },
        ) ??
        '[]';

    final mimeTreeJson = tryDecode(() {
      final rawBodyStructure =
          emailData['bodyStructure'] as Map<String, dynamic>?;
      return rawBodyStructure != null
          ? jsonEncode(_jmapBodyStructureToJson(rawBodyStructure))
          : null;
    });

    if (decodeFailed) {
      unawaited(
        _appLogger?.error(
          'email.body.decode_failed',
          'Could not fully decode message body — showing what was salvaged',
          accountId: account.id,
          emailId: emailId,
          error: decodeError,
          stack: decodeStack,
        ),
      );
    }

    await _cacheFetchedBody(
      emailId: emailId,
      textBody: textBody,
      htmlBody: htmlBody,
      attachmentsJson: attachmentsJson,
      headersJson: headersJson,
      mimeTreeJson: mimeTreeJson,
    );

    await _backfillAddressHeaders(emailId, _parseHeaders(headersJson));

    _logBodyLoaded(
      emailId: emailId,
      accountId: account.id,
      source: 'jmap',
      network: true,
      prefetch: prefetch,
      bytes: _bodySize(textBody, htmlBody),
      durationMs: startedAt == null
          ? null
          : DateTime.now().difference(startedAt).inMilliseconds,
    );

    return model.EmailBody(
      emailId: emailId,
      textBody: textBody,
      htmlBody: htmlBody,
      attachments: _parseAttachments(attachmentsJson),
      headers: _parseHeaders(headersJson),
      mimeTree: _parseMimeTree(mimeTreeJson),
      decodeFailed: decodeFailed,
    );
  }

  /// Extracts text body, HTML body, and attachments JSON from a JMAP Email object
  /// that was fetched with fetchHTMLBodyValues/fetchTextBodyValues.
  (String? textBody, String? htmlBody, String attachmentsJson) _parseJmapBody(
    Map<String, dynamic> m,
  ) {
    final bodyValues = m['bodyValues'] as Map<String, dynamic>? ?? {};
    final textBodyParts = m['textBody'] as List<dynamic>? ?? [];
    final htmlBodyParts = m['htmlBody'] as List<dynamic>? ?? [];
    final jmapAttachments = m['attachments'] as List<dynamic>? ?? [];

    // JMAP's `textBody`/`htmlBody` fall back to the other representation when
    // the message has only one part: an HTML-only mail lists its `text/html`
    // part in `textBody`, and a plain-only mail lists its `text/plain` part in
    // `htmlBody` (RFC 8621 §4.1.4). Storing those cross-typed parts would put
    // raw HTML into `textBody` (and vice versa), which the IMAP path never does
    // — `decodeTextPlainPart()`/`decodeTextHtmlPart()` are type-specific and
    // return null when the matching part is absent. Guard on the part's `type`
    // so both sync paths agree (#514).
    final textBody = _jmapBodyValueOfType(
      textBodyParts,
      bodyValues,
      'text/plain',
    );
    final htmlBody = _jmapBodyValueOfType(
      htmlBodyParts,
      bodyValues,
      'text/html',
    );

    final attachmentsJson = jsonEncode(
      jmapAttachments.map((a) {
        final att = a as Map<String, dynamic>;
        return {
          'filename': att['name'] ?? '',
          'contentType': att['type'] ?? '',
          'size': att['size'] ?? 0,
          'fetchPartId': att['blobId'] ?? '',
        };
      }).toList(),
    );

    return (textBody, htmlBody, attachmentsJson);
  }

  (String? textBody, String? htmlBody, String attachmentsJson)
      _parseJmapBodyForTest(Map<String, dynamic> m) => _parseJmapBody(m);

  Future<String> _downloadAttachment(
    String emailId,
    model.EmailAttachment attachment,
  ) async {
    final emailDir = await _attachmentDirOf(emailId);
    final name = safeFileName(attachment.filename);
    // One folder per part, so two parts with the same file name stay apart
    // and each keeps its real name. Without a part id only the old layout
    // (`<email>/<name>`) can hold it.
    final partDir = 'part-${safeFileName(attachment.fetchPartId)}';
    final file = File(
      attachment.fetchPartId.isEmpty
          ? p.join(emailDir, name)
          : p.join(emailDir, partDir, name),
    );
    if (await file.exists()) {
      await _recordAttachmentFile(emailId, attachment.filename, file);
      return file.path;
    }

    if (attachment.fetchPartId.isEmpty) {
      throw StateError(
        'Cannot download ${attachment.filename}: missing part ID. '
        'Open the email again to refresh.',
      );
    }

    final emailRow = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);

    if (account.type == account_model.AccountType.jmap) {
      final jmap = await JmapClient.connect(
        httpClient: _httpClient,
        jmapUrl: Uri.parse(account.jmapUrl!),
        username: _effectiveUsername(account),
        password: password,
      );
      final bytes = await jmap.downloadBlob(
        attachment.fetchPartId,
        name: attachment.filename,
        type: attachment.contentType,
      );
      await _writeCachedAttachment(file, bytes);
      await _recordAttachmentFile(emailId, attachment.filename, file);
      return file.path;
    }

    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectUnicodeMailboxByPath(emailRow.imapServerPath);
      // Fetch the full message so enough_mail has MIME headers (including
      // Content-Transfer-Encoding) and getPart() can decode the part correctly.
      // A partial BODY.PEEK[n] fetch omits those headers, causing
      // decodeContentBinary() to return raw base64 instead of decoded bytes.
      final fetch = await client.uidFetchMessage(
        emailRow.imapServerUid,
        'BODY.PEEK[]',
      );
      final msg = fetch.messages.firstOrNull;
      if (msg == null) {
        throw StateError(
          'IMAP server returned no message for UID '
          '${emailRow.imapServerUid}.',
        );
      }
      // Resolve the specific MIME part. Never fall back to `msg` itself: if the
      // stored fetchPartId no longer resolves, decoding the whole multipart
      // message and presenting its raw bytes as the attachment yields garbage
      // (e.g. an "image" that renders as colour-noise, #830). Surface an error
      // so the caller can offer a Retry / download instead.
      final part = msg.getPart(attachment.fetchPartId);
      if (part == null) {
        throw StateError(
          'Could not locate part ${attachment.fetchPartId} for '
          '${attachment.filename}. Open the email again to refresh.',
        );
      }
      final bytes = part.decodeContentBinary();
      if (bytes == null) {
        throw StateError('Failed to decode attachment ${attachment.filename}.');
      }
      await _writeCachedAttachment(file, bytes);
      await _recordAttachmentFile(emailId, attachment.filename, file);
      return file.path;
    } finally {
      await closeImapClient(client);
    }
  }

  /// Writes [bytes] to [file] through a temp file renamed into place, so an
  /// interrupted download never leaves a truncated file that later counts
  /// as cached.
  Future<void> _writeCachedAttachment(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.download');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  /// Upserts an [AttachmentFiles] row after the attachment has been flushed
  /// to disk. Used by the Sync state screen to bucket mails as fully / partly
  /// offline without stat()ing every attachment on every render.
  Future<void> _recordAttachmentFile(
    String emailId,
    String filename,
    File file,
  ) async {
    final size = await file.length();
    try {
      await _db.into(_db.attachmentFiles).insertOnConflictUpdate(
            AttachmentFilesCompanion.insert(
              emailId: emailId,
              filename: filename,
              size: size,
              downloadedAt: DateTime.now(),
            ),
          );
    } catch (e) {
      // The email was deleted while the download ran.
      if (!isForeignKeyViolation(e)) rethrow;
    }
  }

  Future<String> _fetchRawRfc822(String emailId) async {
    final emailRow = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);

    if (account.type == account_model.AccountType.jmap) {
      final jmap = await JmapClient.connect(
        httpClient: _httpClient,
        jmapUrl: Uri.parse(account.jmapUrl!),
        username: _effectiveUsername(account),
        password: password,
      );
      final jmapEmailId = _requireJmapId(emailRow);
      final responses = await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': [jmapEmailId],
            'properties': ['id', 'blobId'],
          },
          '0',
        ],
      ]);
      final result = _responseArgs(responses, 0, 'Email/get');
      final list = result['list'] as List<dynamic>;
      final emailData = list.firstOrNull as Map<String, dynamic>?;
      if (emailData == null) {
        throw StateError(
          'JMAP server returned no message for id $jmapEmailId.',
        );
      }
      final blobId = emailData['blobId'] as String?;
      if (blobId == null || blobId.isEmpty) {
        throw StateError(
          'JMAP server returned no blobId for id $jmapEmailId.',
        );
      }
      final bytes = await jmap.downloadBlob(
        blobId,
        name: 'email.eml',
        type: 'message/rfc822',
      );
      return utf8.decode(bytes, allowMalformed: true);
    }

    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectUnicodeMailboxByPath(emailRow.imapServerPath);
      final fetch = await client.uidFetchMessage(
        emailRow.imapServerUid,
        'BODY.PEEK[]',
      );
      final msg = fetch.messages.firstOrNull;
      if (msg == null) {
        throw StateError(
          'IMAP server returned no message for UID '
          '${emailRow.imapServerUid}.',
        );
      }
      return msg.renderMessage();
    } finally {
      await closeImapClient(client);
    }
  }

  model.EmailBody _bodyRowToModel(EmailBody row) => model.EmailBody(
        emailId: row.emailId,
        textBody: row.textBody,
        htmlBody: row.htmlBody,
        attachments: _parseAttachments(row.attachmentsJson),
        headers: _parseHeaders(row.headersJson),
        mimeTree: _parseMimeTree(row.mimeTreeJson),
      );

  model.MimePart? _parseMimeTree(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return null;
    try {
      return _mimePartFromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  model.MimePart _mimePartFromJson(Map<String, dynamic> m) => model.MimePart(
        contentType: m['contentType'] as String? ?? 'application/octet-stream',
        filename: m['filename'] as String?,
        size: m['size'] as int?,
        encoding: m['encoding'] as String?,
        children: ((m['children'] as List<dynamic>?) ?? [])
            .cast<Map<String, dynamic>>()
            .map(_mimePartFromJson)
            .toList(),
      );

  /// Rough on-disk size of a cached body in characters — sum of textBody +
  /// htmlBody length. Reported by the Sync state screen; not the wire size.
  int _bodySize(String? textBody, String? htmlBody) =>
      (textBody?.length ?? 0) + (htmlBody?.length ?? 0);

  /// Records how a message body was loaded so the per-message "Show Logs" view
  /// answers "did opening this mail need the Internet?" (#642). [source] is one
  /// of `cache`, `local`, `imap` or `jmap`; [network] says whether the load hit
  /// the server. Best-effort and fire-and-forget — logging must never affect or
  /// slow down the body load.
  void _logBodyLoaded({
    required String emailId,
    required String source,
    required bool network,
    required bool prefetch,
    String? accountId,
    String? mailboxPath,
    int? cacheAgeSeconds,
    int? bytes,
    int? durationMs,
  }) {
    final where = network
        ? 'over the Internet (${source.toUpperCase()})'
        : source == 'local'
            ? 'from this device (locally-composed message) — no Internet needed'
            : 'from the local cache — no Internet needed';
    final how = prefetch ? 'Prefetched' : 'Loaded';
    unawaited(
      _appLogger?.info(
        'email.body.loaded',
        '$how message body $where',
        data: {
          'source': source,
          'internet': network,
          'trigger': prefetch ? 'prefetch' : 'open',
          if (cacheAgeSeconds != null) 'cacheAgeSeconds': cacheAgeSeconds,
          if (bytes != null) 'bytes': bytes,
          if (durationMs != null) 'durationMs': durationMs,
        },
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
      ),
    );
  }

  List<model.EmailAttachment> _parseAttachments(String json) {
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map(
          (e) => model.EmailAttachment(
            filename: (e as Map<String, dynamic>)['filename'] as String,
            contentType: e['contentType'] as String,
            size: e['size'] as int,
            fetchPartId: (e['fetchPartId'] as String?) ?? '',
          ),
        )
        .toList();
  }
}
