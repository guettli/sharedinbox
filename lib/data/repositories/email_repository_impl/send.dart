part of '../email_repository_impl.dart';

// Sending: SMTP and JMAP submission, the outbox flush and the Sent copy
// upload.

/// Folder to APPEND the Sent copy to when the account has no `role = 'sent'`
/// mailbox at all — a fresh account whose folder list has never synced, or a
/// server that advertises no SPECIAL-USE flags. Only in that case do we fall
/// back to the RFC 6154 conventional name and create it.
const _fallbackSentFolder = 'Sent';

extension _Send on EmailRepositoryImpl {
  Future<void> _sendEmail(String accountId, model.EmailDraft draft) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    switch (account.type) {
      case account_model.AccountType.imap:
        // Direct (non-queued) send: nothing waited in the outbox, so timing is
        // collected only to satisfy the phase instrumentation and discarded.
        await _sendEmailImap(
          account,
          password,
          draft,
          SendTiming(queuedFor: Duration.zero),
        );
      case account_model.AccountType.jmap:
        await _sendEmailJmap(account, password, draft);
    }
  }

  Future<int> _enqueueSend(String accountId, model.EmailDraft draft) async {
    // Stamp a deterministic Message-ID so a self-send's local inbox note and
    // the real message that arrives later share the same id (#545). enough_mail
    // would otherwise generate a random one at send time.
    final host = draft.from.email.contains('@')
        ? draft.from.email.split('@').last
        : 'localhost';
    final stampedDraft = draft.messageId != null
        ? draft
        : draft.copyWith(messageId: imap.MessageBuilder.createMessageId(host));
    // The self-send inbox note (#545) is NOT created here: until SMTP accepts
    // the message it may still be rejected (unknown recipient, 5xx) or be
    // discarded from the Sent Queue, and a note in the inbox would then look
    // like mail that arrived although nothing was delivered. It is created by
    // the outbox sender once the send has succeeded (see [_flushOutbox]).
    return _outbox.enqueue(accountId, stampedDraft);
  }

  /// Shared flush machinery for [flushOutbox] (background sync loop) and
  /// [sendNow] (UI-initiated). [extraObserver], when supplied, is notified of
  /// every row outcome alongside the app-log observer, letting a caller capture
  /// the fate of a specific row without duplicating the sender/timing wiring.
  /// [warnings], when supplied, receives a row's [_sendEmailJmap] warning
  /// (keyed by row id) before its `onOk` fires.
  Future<int> _flushOutbox(
    String accountId,
    String password, {
    OutboxFlushObserver? extraObserver,
    Map<int, String>? warnings,
    bool skipIfBusy = false,
  }) async {
    final account = (await _accounts.getAccount(accountId))!;
    // Per-row timing breakdowns, keyed by outbox row id, so the log observer
    // can report *why* each send took as long as it did (#801). Scoped to this
    // flush call rather than an instance field so concurrent per-account
    // flushes never clobber each other's numbers.
    final timings = <int, SendTiming>{};
    return _outbox.flush(
      accountId,
      (job) async {
        // Re-validate any attachment file paths before touching the network so
        // an obviously-broken queue entry is failed-out fast.
        for (final filePath in job.draft.attachmentFilePaths) {
          if (!await File(filePath).exists()) {
            throw PermanentSendException(
              'Attachment file no longer exists: $filePath',
            );
          }
        }
        final timing = SendTiming(
          queuedFor: DateTime.now().difference(job.createdAt),
        );
        timings[job.id] = timing;
        final stopwatch = Stopwatch()..start();
        try {
          switch (account.type) {
            case account_model.AccountType.imap:
              await _sendEmailImap(account, password, job.draft, timing);
            case account_model.AccountType.jmap:
              final warning =
                  await _sendEmailJmap(account, password, job.draft);
              if (warning != null) warnings?[job.id] = warning;
          }
          // Accepted by the server: only now may a mail to one of our own
          // accounts show up in that inbox (#545). Best-effort, like the Sent
          // copy — rethrowing would re-send an already-sent message.
          try {
            await _createLocalSelfMessages(job.draft);
          } catch (e, stack) {
            unawaited(
              _appLogger?.warn(
                'outbox.send.self_note_failed',
                'Message sent, but adding the local inbox copy failed: $e',
                accountId: accountId,
                error: e,
                stack: stack,
              ),
            );
          }
        } on SmtpRecipientsRejectedException catch (e) {
          // Nothing was sent. A permanently refused address fails the
          // row so the user can fix it via Edit; an all-4xx refusal retries.
          if (e.isPermanent) throw PermanentSendException(e.toString());
          rethrow;
        } on imap.SmtpException catch (e) {
          // Permanent SMTP rejections come back as 5xx response codes — those
          // will fail the same way on every retry, so fail the row out.
          if (_isPermanentSmtpError(e)) {
            throw PermanentSendException('SMTP rejected: ${e.message}');
          }
          rethrow;
        } on JmapException catch (e) {
          // EmailSubmission errors that won't recover on retry (invalid
          // recipient, forbidden identity, missing mailbox).
          if (_isPermanentJmapError(e)) {
            throw PermanentSendException('JMAP rejected: ${e.message}');
          }
          rethrow;
        } finally {
          timing.total = stopwatch.elapsed;
        }
      },
      observer: _combineObservers(
        extraObserver,
        _outboxLogObserver(accountId, timings),
      ),
      skipIfBusy: skipIfBusy,
    );
  }

  Future<SendNowResult> _sendNow(String accountId, {int? outboxRowId}) async {
    final password = await _accounts.getPassword(accountId);
    // Capture the target row's outcome as the guarded flush processes it, so we
    // can report the concrete result to the user (#755). Runs alongside the
    // app-log observer via [_combineObservers].
    SendNowResult? captured;
    final warnings = <int, String>{};
    final observer = outboxRowId == null
        ? null
        : OutboxFlushObserver(
            onOk: (job) {
              if (job.id == outboxRowId) {
                captured = SendNowResult(
                  SendNowOutcome.sent,
                  warning: warnings[job.id],
                );
              }
            },
            onTransient: (job, error, stack, nextAttemptAt) {
              if (job.id == outboxRowId) {
                captured = SendNowResult(
                  SendNowOutcome.transientFailed,
                  message: error.toString(),
                );
              }
            },
            onPermanent: (job, error) {
              if (job.id == outboxRowId) {
                captured = SendNowResult(
                  SendNowOutcome.permanentlyFailed,
                  message: error.message,
                );
              }
            },
          );
    final sentCount = await _flushOutbox(
      accountId,
      password,
      extraObserver: observer,
      warnings: warnings,
    );
    if (captured != null) return captured!;
    if (outboxRowId == null) {
      // No row targeted, so report what the flush actually did, per the
      // interface contract ("otherwise it reports whether anything was sent").
      // Claiming `sent` unconditionally would report delivery even when the
      // queue was empty or every row failed.
      return SendNowResult(
        sentCount > 0 ? SendNowOutcome.sent : SendNowOutcome.queued,
      );
    }
    // The row was not processed by this flush — either a concurrent flush had
    // already sent it (the per-account lock serialises the two, so it was gone
    // by the time we ran) or it is not eligible yet. Derive the outcome from
    // its current persisted state.
    final row = await (_db.select(_db.outbox)
          ..where((t) => t.id.equals(outboxRowId))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) {
      // Gone from the queue. Usually that means a concurrent flush delivered it,
      // and reporting `sent` is right. It is NOT proof of delivery though: the
      // Discard action stays enabled while a retry is in flight, so a user who
      // discards mid-send also lands here. Distinguishing the two needs a
      // durable per-row terminal state, which is the dedup follow-up's job.
      return const SendNowResult(SendNowOutcome.sent);
    }
    if (row.status == 'failed') {
      return SendNowResult(
        SendNowOutcome.permanentlyFailed,
        message: row.lastError,
      );
    }
    return SendNowResult(SendNowOutcome.queued, message: row.lastError);
  }

  /// Fans a single flush's row-outcome callbacks out to two observers. Each
  /// side is best-effort — the outbox's own `_safeNotify` already guards the
  /// combined callback — and [first] runs before [second] so a capturing
  /// observer records its result even if the log observer later throws.
  OutboxFlushObserver? _combineObservers(
    OutboxFlushObserver? first,
    OutboxFlushObserver? second,
  ) {
    if (first == null) return second;
    if (second == null) return first;
    return OutboxFlushObserver(
      onAttempt: (job) {
        first.onAttempt?.call(job);
        second.onAttempt?.call(job);
      },
      onOk: (job) {
        first.onOk?.call(job);
        second.onOk?.call(job);
      },
      onTransient: (job, error, stack, nextAttemptAt) {
        first.onTransient?.call(job, error, stack, nextAttemptAt);
        second.onTransient?.call(job, error, stack, nextAttemptAt);
      },
      onPermanent: (job, error) {
        first.onPermanent?.call(job, error);
        second.onPermanent?.call(job, error);
      },
    );
  }

  // Mirrors every outbox row outcome into the application log so a user who
  // hits Retry on a queued message actually sees why it did or did not send
  // (previously the failure was only stored in `outbox.lastError` and the
  // log stayed silent — see #323).
  OutboxFlushObserver? _outboxLogObserver(
    String accountId,
    Map<int, SendTiming> timings,
  ) {
    final logger = _appLogger;
    if (logger == null) return null;
    String describe(OutboxJob job) {
      final subject = job.draft.subject.isEmpty
          ? '(no subject)'
          : (job.draft.subject.length > 60
              ? '${job.draft.subject.substring(0, 60)}…'
              : job.draft.subject);
      final recipients = job.draft.allRecipients.length;
      return '"$subject" ($recipients recipient${recipients == 1 ? '' : 's'})';
    }

    return OutboxFlushObserver(
      onAttempt: (job) {
        unawaited(
          // `info`, not `debug`: the default app-log filter hides debug, so a
          // send in progress used to leave no visible trace at all (#501). One
          // entry per eligible row per cycle, and backoff spaces retries out,
          // so this stays quiet in steady state.
          logger.info(
            'outbox.send.attempt',
            'Sending queued message ${describe(job)} (attempt ${job.attempts + 1})',
            accountId: accountId,
            emailId: 'outbox:${job.id}',
            data: {
              'outboxRowId': job.id,
              'attempts': job.attempts,
              'subject': job.draft.subject,
              'to': job.draft.to.map((a) => a.email).toList(),
            },
          ),
        );
      },
      onOk: (job) {
        // Attach the timing breakdown so a user asking "why did sending take so
        // long?" can read the answer straight off the log entry (#801): how
        // long the message waited in the queue vs. how long each network leg
        // took.
        final timing = timings.remove(job.id);
        unawaited(
          logger.info(
            'outbox.send.ok',
            'Queued message ${describe(job)} sent'
                '${timing == null ? '' : ' — ${timing.summary}'}',
            accountId: accountId,
            emailId: 'outbox:${job.id}',
            data: {
              'outboxRowId': job.id,
              'attempts': job.attempts + 1,
              if (timing != null) ...timing.toLogData(),
            },
          ),
        );
      },
      onTransient: (job, error, stack, nextAttemptAt) {
        // Report the timing even on failure — a phase that timed out is exactly
        // the slow leg the user is hunting for.
        final timing = timings.remove(job.id);
        unawaited(
          logger.warn(
            'outbox.send.transient_error',
            'Send failed for ${describe(job)}; retrying at '
                '${nextAttemptAt.toIso8601String()}',
            accountId: accountId,
            emailId: 'outbox:${job.id}',
            data: {
              'outboxRowId': job.id,
              'attempts': job.attempts + 1,
              'nextAttemptAt': nextAttemptAt.toIso8601String(),
              if (timing != null) ...timing.toLogData(),
            },
            error: error,
            stack: stack,
          ),
        );
      },
      onPermanent: (job, error) {
        final timing = timings.remove(job.id);
        unawaited(
          logger.error(
            'outbox.send.permanent_error',
            'Send permanently failed for ${describe(job)}: ${error.message}',
            accountId: accountId,
            emailId: 'outbox:${job.id}',
            data: {
              'outboxRowId': job.id,
              'attempts': job.attempts + 1,
              if (timing != null) ...timing.toLogData(),
            },
            error: error,
          ),
        );
      },
    );
  }

  bool _isPermanentSmtpError(imap.SmtpException e) {
    final code = e.response.code ?? 0;
    return code >= 500 && code < 600;
  }

  bool _isPermanentJmapError(JmapException e) {
    final m = e.message.toLowerCase();
    return m.contains('forbidden') ||
        m.contains('invalidemail') ||
        m.contains('noidentity') ||
        m.contains('no jmap identity') ||
        m.contains('cannotsend');
  }

  Future<void> _sendEmailImap(
    account_model.Account account,
    String password,
    model.EmailDraft draft,
    SendTiming timing,
  ) async {
    final builder = imap.MessageBuilder()
      ..from = [HeaderMailAddress(draft.from.name, draft.from.email)]
      ..to = draft.to.map((a) => HeaderMailAddress(a.name, a.email)).toList()
      ..cc = draft.cc.map((a) => HeaderMailAddress(a.name, a.email)).toList()
      ..subject = encodeUnstructuredHeader(draft.subject)
      ..subjectEncoding = imap.HeaderEncoding.none
      ..messageId = draft.messageId
      ..text = draft.body;
    addReplyHeaders(builder, draft);
    for (final filePath in draft.attachmentFilePaths) {
      final file = File(filePath);
      final mediaType = imap.MediaType.guessFromFileName(filePath);
      await builder.addFile(file, mediaType);
    }
    // Built without Bcc, so the transmitted message cannot carry it: Bcc
    // recipients only go into the SMTP envelope (RCPT TO) below (#1126).
    // enough_mail would strip a Bcc header itself, but only its first line,
    // so a long, folded one would leak its continuation lines.
    final mimeMessage = builder.buildMimeMessage();
    final envelopeRecipients = [
      for (final a in draft.allRecipients) HeaderMailAddress(a.name, a.email),
    ];
    final smtpEndpoint = '${account.smtpHost}:${account.smtpPort}';
    final imapEndpoint = '${account.imapHost}:${account.imapPort}';
    final smtpClient = await _withPhase(
      'SMTP connect/auth',
      smtpEndpoint,
      () => _smtpConnect(
        account,
        _effectiveUsername(account),
        password,
      ).timeout(_sendOperationTimeout),
      timing: timing,
    );
    try {
      await _withPhase(
        'SMTP send message',
        smtpEndpoint,
        () => smtpClient
            .sendMessage(mimeMessage, recipients: envelopeRecipients)
            .timeout(_sendOperationTimeout),
        timing: timing,
      );
    } finally {
      // Quit is a one-liner over the wire — bound it tightly so a wedged
      // server doesn't keep the caller hanging after the message is sent.
      try {
        await smtpClient.quit().timeout(const Duration(seconds: 10));
      } on TimeoutException {
        // Best-effort: the message is already sent.
      }
    }
    // The SMTP send above is the commit point (#755): once sendMessage returns,
    // the message is on its way and must never be re-sent. Saving a copy to the
    // IMAP Sent folder is best-effort from here on — swallow and log any failure
    // rather than rethrow. If it rethrew, the outbox would treat this
    // already-sent row as a transient failure and re-send it on the next retry,
    // delivering the message twice and leaving the row lingering in the Sent
    // Queue until a later attempt finally completed the append.
    try {
      // The Sent copy is the sender's own record, so it keeps Bcc, as other
      // clients' copies do.
      if (draft.bcc.isNotEmpty) {
        mimeMessage.setHeader(
          'Bcc',
          draft.bcc
              .map((a) => HeaderMailAddress(a.name, a.email).encode())
              .join(
                ', ',
              ),
        );
      }
      final appended = await _appendSentCopy(
        account,
        password,
        mimeMessage,
        imapEndpoint,
        timing,
      );
      // UIDPLUS (RFC 4315) tells us the UID the copy got, which is all we need
      // to write the very row a later sync of that folder would write. Without
      // it we insert a virtual row instead, so Sent is never empty right after
      // sending (#918).
      final uidList =
          appended.result.responseCodeAppendUid?.targetSequence.toList();
      final appendUid =
          (uidList != null && uidList.isNotEmpty) ? uidList.first : null;
      // The draft's own id first: it is what `enqueueSend` stamped and what the
      // self-send inbox note (#545), created once this send returns, is keyed
      // on, so both rows agree. The
      // header is only a fallback for a direct send that never went through the
      // outbox, and MessageBuilder can hand it back double-bracketed (#859),
      // which `normaliseMessageId` only half-strips.
      final sentMessageId = normaliseMessageId(
        draft.messageId ?? mimeMessage.getHeaderValue('message-id'),
      );
      await _storeSentCopyLocally(
        accountId: account.id,
        mailboxPath: appended.path,
        draft: draft,
        messageId: sentMessageId,
        uid: appendUid,
      );
    } catch (e, stack) {
      final logger = _appLogger;
      if (logger != null) {
        unawaited(
          logger.warn(
            'outbox.send.sent_copy_failed',
            'Message sent, but saving a copy to the Sent folder failed: $e',
            accountId: account.id,
            error: e,
            stack: stack,
          ),
        );
      }
    }
  }

  /// The mailbox the server itself designates as its Sent folder, as recorded
  /// by the mailbox sync from the SPECIAL-USE / XLIST flags. Null when the
  /// account has no sent-role mailbox.
  Future<MailboxRow?> _sentMailboxRow(String accountId) =>
      (_db.select(_db.mailboxes)
            ..where(
              (t) => t.accountId.equals(accountId) & t.role.equals('sent'),
            )
            ..limit(1))
          .getSingleOrNull();

  /// Connects over IMAP and APPENDs [mimeMessage] to the Sent folder, creating
  /// the folder first when the server does not pre-create it. Extracted from
  /// [_sendEmailImap] so the caller can treat the whole Sent-copy step as one
  /// best-effort unit that never undoes an already-completed SMTP send (#755).
  ///
  /// Returns the folder the copy went into plus the server's APPEND result, so
  /// the caller can mirror it into the local DB.
  Future<({String path, imap.GenericImapResult result})> _appendSentCopy(
    account_model.Account account,
    String password,
    imap.MimeMessage mimeMessage,
    String imapEndpoint,
    SendTiming timing,
  ) async {
    // Append to the folder this server actually calls Sent. The path used to be
    // the literal 'Sent', which on every server that names it something else
    // (INBOX.Sent, Sent Items, Sent Messages, [Gmail]/Sent Mail, or anything
    // under a namespace prefix) CREATEd a second, top-level folder and filed
    // the copy there — so the Sent folder the app displays, resolved by
    // `role = 'sent'`, stayed empty (#918).
    final sentRow = await _sentMailboxRow(account.id);
    final sentPath = sentRow?.path ?? _fallbackSentFolder;
    final imapClient = await _withPhase(
      'IMAP connect/login (to append Sent copy)',
      imapEndpoint,
      () => _imapConnect(
        account,
        _effectiveUsername(account),
        password,
      ).timeout(_sendOperationTimeout),
      timing: timing,
    );
    try {
      // Only create when we are guessing the name: a folder the server already
      // listed needs no CREATE, and issuing one just to swallow the inevitable
      // "already exists" would keep hiding real errors on every single send.
      if (sentRow == null) {
        final createStopwatch = Stopwatch()..start();
        try {
          await imapClient
              .createMailbox(sentPath)
              .timeout(_sendOperationTimeout);
        } on TimeoutException catch (e) {
          throw _wrapPhaseError(
            'IMAP create Sent folder',
            imapEndpoint,
            e,
          );
        } catch (_) {
          // Already exists — that's fine.
        } finally {
          timing.record('IMAP create Sent folder', createStopwatch.elapsed);
        }
      }
      final result = await _withPhase(
        'IMAP append to Sent folder',
        imapEndpoint,
        () => imapClient.appendMessage(
          mimeMessage,
          targetMailboxPath: sentPath,
          flags: [r'\Seen'],
          responseTimeout: _sendOperationTimeout,
        ),
        timing: timing,
      );
      return (path: sentPath, result: result);
    } finally {
      // Best-effort and bounded: the message is already appended to Sent, so
      // a lost connection or wedged server must not fail (and re-queue) the
      // send.
      await closeImapClient(imapClient);
    }
  }

  /// Runs [action] and, if it throws a [TimeoutException], rewraps the error
  /// so the message carries the phase name and endpoint. This turns opaque
  /// entries like "TimeoutException after 0:00:50.000000: null" into
  /// user-legible ones like "SMTP connect/auth timed out after 50s (host:
  /// smtp.example.com:587)" — the difference between the sent-queue row
  /// showing "nothing" and showing the actual root cause the user asked for
  /// in #323.
  Future<T> _withPhase<T>(
    String phase,
    String endpoint,
    Future<T> Function() action, {
    SendTiming? timing,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await action();
    } on TimeoutException catch (e) {
      throw _wrapPhaseError(phase, endpoint, e);
    } finally {
      // Record even on timeout/error: a phase that hung is the slow leg the
      // user is looking for (#801).
      timing?.record(phase, stopwatch.elapsed);
    }
  }

  Exception _wrapPhaseError(
    String phase,
    String endpoint,
    TimeoutException e,
  ) {
    final seconds = (e.duration ?? _sendOperationTimeout).inSeconds;
    return TimeoutException(
      '$phase timed out after ${seconds}s (host: $endpoint)',
      e.duration,
    );
  }

  /// Returns a warning for the user when the message went out but the server
  /// refused some of its recipients, otherwise null.
  Future<String?> _sendEmailJmap(
    account_model.Account account,
    String password,
    model.EmailDraft draft,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('JMAP account ${account.id} has no jmapUrl');
    }
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    // Upload any file attachments and collect their blobIds.
    final attachments = <Map<String, dynamic>>[];
    for (final filePath in draft.attachmentFilePaths) {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final contentType = imap.MediaType.guessFromFileName(filePath).text;
      final blobId = await jmap.uploadBlob(bytes, contentType);
      attachments.add({
        'blobId': blobId,
        'type': contentType,
        'name': p.basename(filePath),
        'size': bytes.length,
        'disposition': 'attachment',
      });
    }

    // Look up the Sent mailbox JMAP ID from the local DB. For JMAP accounts a
    // mailbox row's `path` *is* its JMAP id.
    final sentMailbox = await _sentMailboxRow(account.id);
    final sentJmapId = sentMailbox?.path;
    if (sentJmapId == null) {
      // Without it the create below omits `mailboxIds`, which strict servers
      // reject and lenient ones file into no folder at all — either way the
      // message never shows up in Sent (#918). Nothing we can do but say so.
      unawaited(
        _appLogger?.warn(
          'outbox.send.sent_mailbox_unknown',
          'No sent-role mailbox known for this account; the sent copy may not '
              'be filed into Sent. Sync the folder list and try again.',
          accountId: account.id,
        ),
      );
    }

    // Build the email body.
    const bodyPartId = '1';
    final emailCreate = {
      'from': [
        {'name': draft.from.name, 'email': draft.from.email},
      ],
      'to': draft.to.map((a) => {'name': a.name, 'email': a.email}).toList(),
      if (draft.cc.isNotEmpty)
        'cc': draft.cc.map((a) => {'name': a.name, 'email': a.email}).toList(),
      // This Email is also the Sent copy, so it keeps Bcc. RFC 8621 §7.5:
      // "The server MUST remove any Bcc header field present on the message
      // during delivery." The Bcc recipients get the message through the
      // envelope's rcptTo below (#1126).
      if (draft.bcc.isNotEmpty)
        'bcc':
            draft.bcc.map((a) => {'name': a.name, 'email': a.email}).toList(),
      'subject': draft.subject,
      // JMAP messageId is an array of bracket-less ids (RFC 8621 §4.1.2.3).
      if (draft.messageId != null)
        'messageId': [normaliseMessageId(draft.messageId)],
      // Same bracket-less array form for the reply headers (RFC 8621 §4.1.2.3).
      if (normaliseMessageId(draft.inReplyTo) case final inReplyTo?)
        'inReplyTo': [inReplyTo],
      if (normaliseDraftReferences(draft.references) case final refs
          when refs.isNotEmpty)
        'references': refs,
      'bodyValues': {
        bodyPartId: {
          'value': draft.body,
          'isEncodingProblem': false,
          'isTruncated': false,
        },
      },
      'textBody': [
        {'partId': bodyPartId, 'type': 'text/plain'},
      ],
      if (attachments.isNotEmpty) 'attachments': attachments,
      'keywords': {r'$seen': true},
      if (sentJmapId != null) 'mailboxIds': {sentJmapId: true},
    };

    // Build the recipient envelope for EmailSubmission.
    final allRecipients = [
      for (final a in draft.allRecipients) {'email': a.email},
    ];

    // Fail fast if the server can't submit mail at all, rather than issuing an
    // Identity/get that would only come back as `unknownMethod`.
    if (!jmap.supportsSubmission) {
      throw JmapException('JMAP server does not support message submission');
    }

    // Fetch identities to get the required identityId for EmailSubmission.
    // Identity/get belongs to the submission capability (RFC 8621 §6), so the
    // request must declare it via withSubmission or a strict server rejects the
    // call with `unknownMethod`.
    final identityResponses = await jmap.call(
      [
        [
          'Identity/get',
          {'accountId': jmap.accountId, 'ids': null},
          'i',
        ],
      ],
      withSubmission: true,
    );
    final identityResult = _responseArgs(identityResponses, 0, 'Identity/get');
    final identityList = identityResult['list'] as List<dynamic>?;
    if (identityList == null || identityList.isEmpty) {
      throw JmapException('No identities found for JMAP account');
    }
    // Pick the identity whose address matches the draft's From, not whatever
    // Identity/get happens to list first: a mailbox with aliases returns one
    // identity per address, and a server that enforces RFC 8621 §7.5 rejects
    // the submission with `forbiddenFrom` when the envelope mailFrom is not an
    // address the chosen identity may send from (see #564).
    final wantFrom = draft.from.email.toLowerCase();
    final identities = identityList.cast<Map<String, dynamic>>();
    final identity = identities.firstWhere(
      (i) => (i['email'] as String?)?.toLowerCase() == wantFrom,
      // Don't silently guess: an identity that can't send as the From address
      // would just fail with forbiddenFrom, so surface the mismatch instead.
      orElse: () => throw JmapException(
        'No JMAP identity matches sender ${draft.from.email}; '
        'available identities: '
        '${identities.map((i) => i['email'] ?? '?').join(', ')}',
      ),
    );
    final identityId = identity['id'] as String;
    final identityEmail = identity['email'] as String?;

    // Create the email first.
    final createResponses = await jmap.call([
      [
        'Email/set',
        {
          'accountId': jmap.accountId,
          'create': {'em1': emailCreate},
        },
        '0',
      ],
    ]);

    // Check Email/set for creation errors.
    final setResult = _responseArgs(createResponses, 0, 'Email/set');
    final notCreated = setResult['notCreated'] as Map<String, dynamic>?;
    if (notCreated != null && notCreated.containsKey('em1')) {
      final err = notCreated['em1'] as Map<String, dynamic>;
      throw JmapException('Email/set create failed: ${err['type']}');
    }

    final created = setResult['created'] as Map<String, dynamic>?;
    final createdEmail = created?['em1'] as Map<String, dynamic>?;
    final emailId = createdEmail?['id'] as String?;
    if (emailId == null || emailId.isEmpty) {
      throw JmapException('Email/set create failed: missing created email id');
    }

    // Then submit the created email. If submission fails for any reason, the
    // email was already created in the Sent mailbox above; destroy it so a
    // message that was never actually sent doesn't linger in Sent and make the
    // user think it went out.
    String? warning;
    try {
      final submissionResponses = await jmap.call(
        [
          [
            'EmailSubmission/set',
            {
              'accountId': jmap.accountId,
              'create': {
                'sub1': {
                  'emailId': emailId,
                  'identityId': identityId,
                  'envelope': {
                    'mailFrom': {'email': draft.from.email},
                    'rcptTo': allRecipients,
                  },
                },
              },
            },
            '1',
          ],
        ],
        withSubmission: true,
      );

      // Check EmailSubmission/set for submission errors.
      final subResult = _responseArgs(
        submissionResponses,
        0,
        'EmailSubmission/set',
      );
      final notSubmitted = subResult['notCreated'] as Map<String, dynamic>?;
      if (notSubmitted != null && notSubmitted.containsKey('sub1')) {
        final err = notSubmitted['sub1'] as Map<String, dynamic>;
        throw JmapException(
          'EmailSubmission/set failed: ${err['type']} '
          '${err['description'] ?? ''} '
          '${err['properties'] ?? ''} '
          '(envelope mailFrom: ${draft.from.email}, '
          'identity email: ${identityEmail ?? 'unknown'})',
        );
      }
      // A created submission is no proof of delivery: Stalwart creates it even
      // when it refused every recipient, and reports the refusals only in the
      // submission's deliveryStatus.
      final submissionId =
          ((subResult['created'] as Map<String, dynamic>?)?['sub1']
              as Map<String, dynamic>?)?['id'] as String?;
      final rejected = submissionId == null
          ? const <RejectedRecipient>[]
          : await _jmapRejectedRecipients(jmap, submissionId);
      if (rejected.isNotEmpty) {
        final description = describeRejectedRecipients(rejected);
        final refused = {for (final r in rejected) r.email.toLowerCase()};
        if (draft.allRecipients
            .every((a) => refused.contains(a.email.toLowerCase()))) {
          // Nobody gets it: fail the row (and drop the Sent copy below), so
          // the user can fix the address via Edit.
          throw PermanentSendException(description);
        }
        // The others already have it and a submission cannot be recalled, so
        // failing the row would only re-send it to them. Say who missed out,
        // to the user (via the caller) and in the app log.
        warning = 'Not delivered to ${rejected.join('; ')}';
        unawaited(
          _appLogger?.error(
            'outbox.send.recipient_rejected',
            'Message sent, but not to everyone. $description',
            accountId: account.id,
            data: {
              'rejected': [for (final r in rejected) r.email],
            },
          ),
        );
      }
    } catch (_) {
      await _destroyJmapEmail(jmap, emailId);
      rethrow;
    }

    // The message is away and the server already filed it into Sent above —
    // mirror it locally so Sent shows it now rather than after the next sync
    // of that folder (#918). Best-effort in its own right: a DB hiccup here
    // must not look like a failed send and get the message delivered twice.
    if (sentMailbox == null) return warning;
    try {
      await _storeSentCopyLocally(
        accountId: account.id,
        mailboxPath: sentMailbox.path,
        draft: draft,
        messageId: draft.messageId,
        jmapId: emailId,
      );
    } catch (e, stack) {
      unawaited(
        _appLogger?.warn(
          'outbox.send.sent_copy_failed',
          'Message sent, but recording the Sent copy locally failed: $e',
          accountId: account.id,
          error: e,
          stack: stack,
        ),
      );
    }
    return warning;
  }

  /// The recipients [jmap] already reports as undeliverable
  /// (`delivered: "no"`, RFC 8621 §7) for the submission [submissionId].
  /// Best-effort: a failed lookup must not turn a sent message into a failed
  /// send, so it reports nobody.
  Future<List<RejectedRecipient>> _jmapRejectedRecipients(
    JmapClient jmap,
    String submissionId,
  ) async {
    try {
      final responses = await jmap.call(
        [
          [
            'EmailSubmission/get',
            {
              'accountId': jmap.accountId,
              'ids': [submissionId],
              'properties': ['deliveryStatus'],
            },
            'g',
          ],
        ],
        withSubmission: true,
      );
      final list = _responseArgs(responses, 0, 'EmailSubmission/get')['list']
          as List<dynamic>?;
      final status = (list == null || list.isEmpty)
          ? null
          : (list.first as Map<String, dynamic>)['deliveryStatus']
              as Map<String, dynamic>?;
      return [
        for (final MapEntry(key: email, value: s) in (status ?? {}).entries)
          if (s is Map<String, dynamic> && s['delivered'] == 'no')
            RejectedRecipient.fromReply(email, s['smtpReply']?.toString()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Best-effort removal of a locally-created JMAP email (e.g. the Sent copy
  /// created before a failed submission). Swallows errors: the original send
  /// failure is what matters to the caller, and a failed cleanup must not mask
  /// it.
  Future<void> _destroyJmapEmail(JmapClient jmap, String emailId) async {
    try {
      await jmap.call([
        [
          'Email/set',
          {
            'accountId': jmap.accountId,
            'destroy': [emailId],
          },
          '0',
        ],
      ]);
    } catch (_) {
      // Ignore — the send already failed and that error is being rethrown.
    }
  }
}
