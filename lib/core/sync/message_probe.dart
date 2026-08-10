import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/message_id_utils.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';

/// Snapshot of a single message fetched from the remote server. Used by the
/// per-message debug screen to compare against the locally-cached copy.
class RemoteMessageSnapshot {
  const RemoteMessageSnapshot({
    required this.mailboxPath,
    this.messageId,
    this.subject,
    this.sentAt,
    this.receivedAt,
    required this.isSeen,
    required this.isFlagged,
    required this.hasAttachment,
    this.uid,
    this.sizeBytes,
    this.from = const [],
    this.to = const [],
    this.cc = const [],
    this.inReplyTo,
    this.references,
    this.listUnsubscribeHeader,
    this.headers = const {},
    this.textBodyBytes,
    this.htmlBodyBytes,
    this.attachments = const [],
  });

  final String mailboxPath;
  final String? messageId;
  final String? subject;
  final DateTime? sentAt;
  final DateTime? receivedAt;
  final bool isSeen;
  final bool isFlagged;
  final bool hasAttachment;
  final int? uid;
  final int? sizeBytes;
  final List<EmailAddress> from;
  final List<EmailAddress> to;
  final List<EmailAddress> cc;
  final String? inReplyTo;
  final String? references;
  final String? listUnsubscribeHeader;

  /// Case-insensitive header map (lowercase keys). Empty when the probe didn't
  /// fetch headers.
  final Map<String, String> headers;
  final int? textBodyBytes;
  final int? htmlBodyBytes;
  final List<EmailAttachment> attachments;
}

/// Result of comparing a locally-cached message row against a
/// [RemoteMessageSnapshot]. An empty [diffs] list means everything matched.
class MessageComparison {
  const MessageComparison({required this.diffs});
  final List<FieldDiff> diffs;
  bool get isMatch => diffs.isEmpty;
}

class FieldDiff {
  const FieldDiff({
    required this.field,
    required this.local,
    required this.remote,
  });
  final String field;
  final String local;
  final String remote;
}

/// Result of a probe call. Wraps either a successful [snapshot], a "not found
/// on server" signal, or an error message.
class ProbeResult {
  const ProbeResult._({this.snapshot, this.error, this.notFound = false});
  const ProbeResult.snapshot(RemoteMessageSnapshot s) : this._(snapshot: s);
  const ProbeResult.notFound() : this._(notFound: true);
  const ProbeResult.error(String message) : this._(error: message);

  final RemoteMessageSnapshot? snapshot;
  final String? error;
  final bool notFound;

  bool get isOk => snapshot != null;
}

/// Fetches a single message from the account's remote server so it can be
/// compared field-by-field against the locally cached copy. See
/// [MessageDebugScreen] for the caller.
abstract class MessageProbe {
  Future<ProbeResult> fetch({
    required Account account,
    required String password,
    required String mailboxPath,
    required String emailId,
    required int uid,
  });
}

class MessageProbeImpl implements MessageProbe {
  MessageProbeImpl({
    ImapConnectFn imapConnect = connectImap,
    http.Client? httpClient,
  })  : _imapConnect = imapConnect,
        _httpClient = httpClient ?? http.Client();

  final ImapConnectFn _imapConnect;
  final http.Client _httpClient;

  @override
  Future<ProbeResult> fetch({
    required Account account,
    required String password,
    required String mailboxPath,
    required String emailId,
    required int uid,
  }) async {
    try {
      switch (account.type) {
        case AccountType.imap:
          return await _fetchImap(
            account: account,
            password: password,
            mailboxPath: mailboxPath,
            uid: uid,
          );
        case AccountType.jmap:
          return await _fetchJmap(
            account: account,
            password: password,
            mailboxPath: mailboxPath,
            emailId: emailId,
          );
      }
    } on SocketException catch (e) {
      return ProbeResult.error('Offline: ${e.message}');
    } catch (e) {
      return ProbeResult.error(e.toString());
    }
  }

  Future<ProbeResult> _fetchImap({
    required Account account,
    required String password,
    required String mailboxPath,
    required int uid,
  }) async {
    final username =
        account.username.isNotEmpty ? account.username : account.email;
    final client = await _imapConnect(account, username, password);
    try {
      await client.selectMailboxByPath(mailboxPath);
      final result = await client.uidFetchMessage(
        uid,
        '(UID FLAGS ENVELOPE BODYSTRUCTURE RFC822.SIZE BODY.PEEK[HEADER])',
      );
      final msg = result.messages.firstOrNull;
      if (msg == null) return const ProbeResult.notFound();

      final envelope = msg.envelope;
      final headers = <String, String>{};
      for (final h in msg.headers ?? const <imap.Header>[]) {
        headers[h.name.toLowerCase()] = h.value ?? '';
      }
      final contentInfos = msg.findContentInfo();
      final attachments = <EmailAttachment>[
        for (final a in contentInfos)
          EmailAttachment(
            filename: a.fileName ?? '',
            contentType: a.contentType?.mediaType.text ?? '',
            size: a.size ?? 0,
            fetchPartId: a.fetchId,
          ),
      ];

      return ProbeResult.snapshot(
        RemoteMessageSnapshot(
          mailboxPath: mailboxPath,
          messageId: normaliseMessageId(envelope?.messageId),
          subject: envelope?.subject,
          sentAt: envelope?.date,
          receivedAt: envelope?.date,
          isSeen: msg.flags?.contains(r'\Seen') ?? false,
          isFlagged: msg.flags?.contains(r'\Flagged') ?? false,
          hasAttachment: msg.hasAttachments(),
          uid: msg.uid ?? uid,
          sizeBytes: msg.size,
          from: _fromImapAddresses(envelope?.from),
          to: _fromImapAddresses(envelope?.to),
          cc: _fromImapAddresses(envelope?.cc),
          inReplyTo: normaliseMessageId(envelope?.inReplyTo),
          references: headers['references']?.trim(),
          listUnsubscribeHeader: headers['list-unsubscribe']?.trim(),
          headers: headers,
          attachments: attachments,
        ),
      );
    } finally {
      await client.logout();
    }
  }

  Future<ProbeResult> _fetchJmap({
    required Account account,
    required String password,
    required String mailboxPath,
    required String emailId,
  }) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      return const ProbeResult.error('Account has no JMAP URL configured');
    }
    final username =
        account.username.isNotEmpty ? account.username : account.email;
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: username,
      password: password,
    );
    final jmapId = emailId.contains(':')
        ? emailId.substring(emailId.indexOf(':') + 1)
        : emailId;

    final responses = await jmap.call([
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          'ids': [jmapId],
          'properties': const [
            'id',
            'blobId',
            'threadId',
            'mailboxIds',
            'keywords',
            'size',
            'receivedAt',
            'messageId',
            'inReplyTo',
            'references',
            'sender',
            'from',
            'to',
            'cc',
            'bcc',
            'replyTo',
            'subject',
            'sentAt',
            'hasAttachment',
            'preview',
            'attachments',
            'headers',
            'textBody',
            'htmlBody',
            'bodyValues',
            'header:List-Unsubscribe:asText',
          ],
          'fetchHTMLBodyValues': true,
          'fetchTextBodyValues': true,
        },
        '0',
      ],
    ]);

    final triple = responses[0] as List<dynamic>;
    if (triple[0] == 'error') {
      final err = triple[1] as Map<String, dynamic>;
      return ProbeResult.error('Email/get error: ${err['type']}');
    }
    final result = triple[1] as Map<String, dynamic>;
    final list = result['list'] as List<dynamic>? ?? const [];
    if (list.isEmpty) return const ProbeResult.notFound();
    final data = list.first as Map<String, dynamic>;

    final mailboxIds =
        (data['mailboxIds'] as Map<String, dynamic>?) ?? const {};
    final resolvedMailboxPath = mailboxIds.containsKey(mailboxPath)
        ? mailboxPath
        : (mailboxIds.keys.isEmpty ? mailboxPath : mailboxIds.keys.first);
    final keywords = (data['keywords'] as Map<String, dynamic>?) ?? const {};

    final headers = <String, String>{};
    for (final h in (data['headers'] as List<dynamic>? ?? const [])) {
      final m = h as Map<String, dynamic>;
      final name = (m['name'] as String? ?? '').toLowerCase();
      final value = m['value'] as String? ?? '';
      // JMAP returns one entry per occurrence — join duplicates.
      headers[name] =
          headers.containsKey(name) ? '${headers[name]}\n$value' : value;
    }

    final attachments = <EmailAttachment>[
      for (final a in (data['attachments'] as List<dynamic>? ?? const []))
        EmailAttachment(
          filename: (a as Map<String, dynamic>)['name'] as String? ?? '',
          contentType: a['type'] as String? ?? '',
          size: (a['size'] as int?) ?? 0,
          fetchPartId: a['blobId'] as String? ?? '',
        ),
    ];

    final bodyValues =
        (data['bodyValues'] as Map<String, dynamic>?) ?? const {};
    int? bytesFor(String key) {
      final parts = data[key] as List<dynamic>? ?? const [];
      if (parts.isEmpty) return null;
      final partId = (parts.first as Map<String, dynamic>)['partId'] as String?;
      if (partId == null) return null;
      final val =
          (bodyValues[partId] as Map<String, dynamic>?)?['value'] as String?;
      return val == null ? null : utf8.encode(val).length;
    }

    return ProbeResult.snapshot(
      RemoteMessageSnapshot(
        mailboxPath: resolvedMailboxPath,
        messageId: _joinJmapStringList(data['messageId'] as List<dynamic>?),
        subject: data['subject'] as String?,
        sentAt: _parseDate(data['sentAt'] as String?),
        receivedAt: _parseDate(data['receivedAt'] as String?),
        isSeen: keywords.containsKey(r'$seen'),
        isFlagged: keywords.containsKey(r'$flagged'),
        hasAttachment: (data['hasAttachment'] as bool?) ?? false,
        sizeBytes: data['size'] as int?,
        from: _fromJmapAddresses(data['from'] as List<dynamic>?),
        to: _fromJmapAddresses(data['to'] as List<dynamic>?),
        cc: _fromJmapAddresses(data['cc'] as List<dynamic>?),
        inReplyTo: _joinJmapStringList(data['inReplyTo'] as List<dynamic>?),
        references: _joinJmapStringList(data['references'] as List<dynamic>?),
        listUnsubscribeHeader:
            (data['header:List-Unsubscribe:asText'] as String?)?.trim(),
        headers: headers,
        textBodyBytes: bytesFor('textBody'),
        htmlBodyBytes: bytesFor('htmlBody'),
        attachments: attachments,
      ),
    );
  }
}

// ── Pure compare helper ─────────────────────────────────────────────────────

/// Snapshot of the local view of a message, assembled by the debug screen so
/// [compareMessage] stays a pure function.
class LocalMessageSnapshot {
  const LocalMessageSnapshot({
    required this.mailboxPath,
    required this.messageId,
    required this.subject,
    required this.sentAt,
    required this.receivedAt,
    required this.isSeen,
    required this.isFlagged,
    required this.hasAttachment,
    required this.uid,
    required this.from,
    required this.to,
    required this.cc,
    required this.inReplyTo,
    required this.references,
    required this.listUnsubscribeHeader,
    required this.attachments,
  });

  final String mailboxPath;
  final String? messageId;
  final String? subject;
  final DateTime? sentAt;
  final DateTime? receivedAt;
  final bool isSeen;
  final bool isFlagged;
  final bool hasAttachment;
  final int uid;
  final List<EmailAddress> from;
  final List<EmailAddress> to;
  final List<EmailAddress> cc;
  final String? inReplyTo;
  final String? references;
  final String? listUnsubscribeHeader;
  final List<EmailAttachment> attachments;
}

/// Compares [local] against [remote] and returns a list of field-level
/// mismatches. The comparison is deterministic so it can be unit-tested.
MessageComparison compareMessage(
  LocalMessageSnapshot local,
  RemoteMessageSnapshot remote,
) {
  final diffs = <FieldDiff>[];

  void diff(String field, String? l, String? r) {
    final lv = l ?? '';
    final rv = r ?? '';
    if (lv != rv) diffs.add(FieldDiff(field: field, local: lv, remote: rv));
  }

  diff('mailboxPath', local.mailboxPath, remote.mailboxPath);
  diff(
    'messageId',
    normaliseMessageId(local.messageId),
    normaliseMessageId(remote.messageId),
  );
  diff('subject', local.subject, remote.subject);
  diff(
    'sentAt',
    local.sentAt?.toUtc().toIso8601String(),
    remote.sentAt?.toUtc().toIso8601String(),
  );
  diff('isSeen', local.isSeen.toString(), remote.isSeen.toString());
  diff('isFlagged', local.isFlagged.toString(), remote.isFlagged.toString());
  diff(
    'hasAttachment',
    local.hasAttachment.toString(),
    remote.hasAttachment.toString(),
  );
  if (remote.uid != null) {
    diff('uid', local.uid.toString(), remote.uid.toString());
  }
  diff('from', _addressesToKey(local.from), _addressesToKey(remote.from));
  diff('to', _addressesToKey(local.to), _addressesToKey(remote.to));
  diff('cc', _addressesToKey(local.cc), _addressesToKey(remote.cc));
  diff(
    'inReplyTo',
    normaliseMessageId(local.inReplyTo),
    normaliseMessageId(remote.inReplyTo),
  );
  diff(
    'references',
    _normaliseReferences(local.references),
    _normaliseReferences(remote.references),
  );
  diff(
    'listUnsubscribeHeader',
    local.listUnsubscribeHeader?.trim(),
    remote.listUnsubscribeHeader?.trim(),
  );
  diff(
    'attachmentCount',
    local.attachments.length.toString(),
    remote.attachments.length.toString(),
  );

  return MessageComparison(diffs: diffs);
}

// ── Helpers ─────────────────────────────────────────────────────────────────

String _addressesToKey(List<EmailAddress> addresses) {
  final parts = addresses.map((a) => a.email.trim().toLowerCase()).toList()
    ..sort();
  return parts.join(',');
}

/// References may arrive from IMAP as one string containing `<a@b><c@d>` with
/// no whitespace between adjacent ids (some clients skip the space), so this
/// helper is more aggressive than [normaliseReferences]: it treats `<` and `>`
/// as token boundaries. Only used by the per-message probe comparison, which
/// needs to reconcile heterogeneous sources.
String? _normaliseReferences(String? raw) {
  if (raw == null) return null;
  final tokens = raw
      .replaceAll('<', ' ')
      .replaceAll('>', ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return null;
  return tokens.join(' ');
}

String? _joinJmapStringList(List<dynamic>? list) {
  if (list == null || list.isEmpty) return null;
  return list
      .whereType<String>()
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .join(' ');
}

DateTime? _parseDate(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

List<EmailAddress> _fromImapAddresses(List<imap.MailAddress>? list) {
  if (list == null) return const [];
  return [
    for (final a in list) EmailAddress(name: a.personalName, email: a.email),
  ];
}

List<EmailAddress> _fromJmapAddresses(List<dynamic>? list) {
  if (list == null) return const [];
  return [
    for (final a in list)
      EmailAddress(
        name: (a as Map<String, dynamic>)['name'] as String?,
        email: a['email'] as String? ?? '',
      ),
  ];
}
