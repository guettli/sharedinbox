import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'jmap_test_server.dart';

const _base = 'https://jmap.example.com';

/// The JMAP URL of an account on [StatefulFakeJmapServer].
const fakeJmapUrl = '$_base/.well-known/jmap';

/// One email on [StatefulFakeJmapServer].
class FakeJmapEmail {
  FakeJmapEmail(
    this.id,
    this.blobId,
    this.raw,
    this.mailboxIds, {
    this.keywords = const {},
  });

  final String id;
  final String blobId;
  final Uint8List raw;
  final Set<String> mailboxIds;
  final Set<String> keywords;

  /// The unfolded value of header [name] in [raw], or null.
  String? header(String name) {
    final text = latin1.decode(raw);
    final end = text.indexOf('\r\n\r\n');
    final head = (end < 0 ? text : text.substring(0, end))
        .replaceAll(RegExp(r'\r\n[ \t]+'), ' ');
    for (final line in head.split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      if (line.substring(0, colon).toLowerCase() != name.toLowerCase()) {
        continue;
      }
      return line.substring(colon + 1).trim();
    }
    return null;
  }

  /// The Message-ID without angle brackets, or null.
  String? get messageId {
    final value = header('Message-ID');
    if (value == null) return null;
    return value.replaceAll(RegExp('[<>]'), '');
  }
}

/// One change of the email set, for `Email/changes` and
/// `Email/queryChanges`.
typedef _Change = ({int state, String id, bool destroyed, Set<String> boxes});

/// A JMAP server with real state (mailboxes, emails, blobs, change log) for
/// the encrypted-object store (RFC 8620/8621, the subset the store uses).
/// Every request is recorded in [requests].
class StatefulFakeJmapServer {
  StatefulFakeJmapServer({this.maxSizeUpload}) {
    _mailboxes['inbox'] = {
      'id': 'inbox',
      'name': 'Inbox',
      'parentId': null,
      'role': 'inbox',
    };
  }

  static const accountId = 'u1';

  /// The core capability's `maxSizeUpload`; null: not advertised.
  final int? maxSizeUpload;

  final Map<String, Map<String, dynamic>> _mailboxes = {};
  final Map<String, FakeJmapEmail> _emails = {};
  final Map<String, Uint8List> _blobs = {};
  final List<_Change> _changes = [];
  int _state = 1;
  int _nextId = 1;

  /// States before this one cannot be calculated from.
  int _horizon = 0;

  /// The method names of every API request, one list per request.
  final List<List<String>> requests = [];

  /// Full listings (`Email/query` without a `header` filter) so far.
  int listings = 0;

  /// Blob uploads and downloads so far.
  int uploads = 0;
  int downloads = 0;

  /// Answers `Email/queryChanges` and `Email/changes` with this error
  /// type while set.
  String? changesError;

  /// Answers every `Email/import` with `notCreated` of this type while set.
  String? importError;

  /// Answers an `Email/import` of a Message-ID a target mailbox has already
  /// with `alreadyExists` and its `existingId`, as some servers do.
  bool dedupeImports = false;

  /// Refuses the `header` filter (`unsupportedFilter`).
  bool refuseHeaderFilter = false;

  /// Emails a listing (`Email/query` without a `header` filter,
  /// `Email/queryChanges`) does not show yet.
  final Set<String> unlisted = {};

  /// At most this many changes per `Email/changes` answer.
  int changesPage = 1000;

  /// Runs before each method call; may throw.
  void Function(String method)? beforeCall;

  int get importCount =>
      requests.expand((r) => r).where((m) => m == 'Email/import').length;

  /// Every method call so far, in order.
  List<String> get calls => [for (final r in requests) ...r];

  late final http.Client client = MockClient(_handle);

  // ── Inspection and changes made elsewhere ────────────────────────────────

  /// The id of the mailbox at [path] (`SharedInbox/Data`), or null.
  String? mailboxIdOf(String path) {
    String? parent;
    String? id;
    for (final name in path.split('/')) {
      id = _mailboxes.values
          .where((b) => b['parentId'] == parent && b['name'] == name)
          .map((b) => b['id'] as String)
          .firstOrNull;
      if (id == null) return null;
      parent = id;
    }
    return id;
  }

  /// The emails in the mailbox at [path], oldest first.
  List<FakeJmapEmail> messagesIn(String path) {
    final id = mailboxIdOf(path);
    if (id == null) return const [];
    return [
      for (final e in _emails.values)
        if (e.mailboxIds.contains(id)) e,
    ];
  }

  /// The email whose Message-ID is [bare], or null.
  FakeJmapEmail? find(String bare) =>
      _emails.values.where((e) => e.messageId == bare).firstOrNull;

  /// Another client adds [raw] to the mailbox at [path].
  FakeJmapEmail add(String path, Uint8List raw) =>
      _create(raw, {mailboxIdOf(path)!});

  /// Another client destroys the email whose Message-ID is [bare].
  void destroyElsewhere(String bare) => _destroy(find(bare)!.id);

  /// Another client deletes the mailbox at [path] with its emails.
  void deleteMailbox(String path) {
    final id = mailboxIdOf(path)!;
    for (final e in [..._emails.values]) {
      if (e.mailboxIds.contains(id)) _destroy(e.id);
    }
    _mailboxes.remove(id);
  }

  /// The server forgets its change history: older states cannot be
  /// calculated from.
  void forgetHistory() => _horizon = _state;

  // ── Model ─────────────────────────────────────────────────────────────────

  FakeJmapEmail _create(
    Uint8List raw,
    Set<String> boxes, {
    Set<String> keywords = const {},
  }) {
    final id = 'e${_nextId++}';
    final blobId = 'b-$id';
    _blobs[blobId] = raw;
    final email = FakeJmapEmail(id, blobId, raw, boxes, keywords: keywords);
    _emails[id] = email;
    _changes.add((state: ++_state, id: id, destroyed: false, boxes: boxes));
    return email;
  }

  void _destroy(String id) {
    final email = _emails.remove(id);
    if (email == null) return;
    _changes.add(
      (state: ++_state, id: id, destroyed: true, boxes: email.mailboxIds),
    );
  }

  Iterable<_Change> _since(int since) => _changes.where((c) => c.state > since);

  // ── HTTP ──────────────────────────────────────────────────────────────────

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    if (path.contains('well-known')) return _session();
    if (path.startsWith('/upload/')) {
      uploads++;
      final blobId = 'up${_nextId++}';
      _blobs[blobId] = req.bodyBytes;
      return http.Response(
        jsonEncode({
          'accountId': accountId,
          'blobId': blobId,
          'type': req.headers['content-type'],
          'size': req.bodyBytes.length,
        }),
        201,
      );
    }
    if (path.startsWith('/download/')) {
      downloads++;
      final blob = _blobs[Uri.decodeComponent(req.url.pathSegments[2])];
      if (blob == null) return http.Response('', 404);
      return http.Response.bytes(blob, 200);
    }
    final calls = jmapMethodCalls(req);
    requests.add([for (final c in calls) c[0] as String]);
    final responses = <List<dynamic>>[];
    for (final c in calls) {
      final method = c[0] as String;
      final args = c[1] as Map<String, dynamic>;
      beforeCall?.call(method);
      responses.add([..._call(method, args, responses), c[2]]);
    }
    return jmapApiResponse(responses);
  }

  http.Response _session() {
    final body = jmapSessionBody(
      accountId: accountId,
      uploadUrl: '$_base/upload/{accountId}/',
      downloadUrl: '$_base/download/{accountId}/{blobId}/{name}?type={type}',
    );
    if (maxSizeUpload != null) {
      (body['capabilities'] as Map)['urn:ietf:params:jmap:core'] = {
        'maxSizeUpload': maxSizeUpload,
      };
    }
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  List<dynamic> _call(
    String method,
    Map<String, dynamic> args,
    List<List<dynamic>> earlier,
  ) =>
      switch (method) {
        'Mailbox/get' => _mailboxGet(),
        'Mailbox/set' => _mailboxSet(args),
        'Email/get' => _emailGet(args, earlier),
        'Email/query' => _emailQuery(args),
        'Email/queryChanges' => _queryChanges(args),
        'Email/changes' => _emailChanges(args),
        'Email/import' => _import(args),
        'Email/set' => _emailSet(args),
        _ => _error('unknownMethod'),
      };

  static List<dynamic> _error(String type) => [
        'error',
        {'type': type},
      ];

  List<dynamic> _mailboxGet() => [
        'Mailbox/get',
        {
          'accountId': accountId,
          'state': 'm$_state',
          'list': _mailboxes.values.toList(),
          'notFound': <String>[],
        },
      ];

  List<dynamic> _mailboxSet(Map<String, dynamic> args) {
    final created = <String, dynamic>{};
    final notCreated = <String, dynamic>{};
    final create = args['create'] as Map<String, dynamic>? ?? const {};
    for (final MapEntry(:key, :value) in create.entries) {
      final box = value as Map<String, dynamic>;
      final exists = _mailboxes.values.any(
        (b) => b['parentId'] == box['parentId'] && b['name'] == box['name'],
      );
      if (exists) {
        notCreated[key] = {'type': 'alreadyExists'};
        continue;
      }
      final id = 'mb${_nextId++}';
      _mailboxes[id] = {
        'id': id,
        'name': box['name'],
        'parentId': box['parentId'],
        'role': null,
      };
      created[key] = {'id': id};
    }
    return [
      'Mailbox/set',
      {
        'accountId': accountId,
        'created': created,
        if (notCreated.isNotEmpty) 'notCreated': notCreated,
      },
    ];
  }

  List<dynamic> _emailGet(
    Map<String, dynamic> args,
    List<List<dynamic>> earlier,
  ) {
    final ref = args['#ids'] as Map<String, dynamic>?;
    final List<String> ids;
    if (ref != null) {
      final source = earlier.lastWhere((r) => r[2] == ref['resultOf']);
      if (source[0] == 'error') return _error('invalidResultReference');
      ids = List<String>.from((source[1] as Map)['ids'] as List);
    } else {
      ids = List<String>.from(args['ids'] as List);
    }
    final properties = List<String>.from(args['properties'] as List? ?? []);
    return [
      'Email/get',
      {
        'accountId': accountId,
        'state': 's$_state',
        'list': [
          for (final id in ids)
            if (_emails[id] case final e?) _render(e, properties),
        ],
        'notFound': [
          for (final id in ids)
            if (!_emails.containsKey(id)) id,
        ],
      },
    ];
  }

  static Map<String, dynamic> _render(
    FakeJmapEmail e,
    List<String> properties,
  ) =>
      {
        for (final p in properties)
          p: switch (p) {
            'id' => e.id,
            'blobId' => e.blobId,
            'size' => e.raw.length,
            'messageId' => e.messageId == null ? null : [e.messageId],
            'mailboxIds' => {for (final b in e.mailboxIds) b: true},
            _ when p.startsWith('header:') => e.header(p.split(':')[1]),
            _ => null,
          },
      };

  List<dynamic> _emailQuery(Map<String, dynamic> args) {
    final filter = args['filter'] as Map<String, dynamic>? ?? const {};
    final header = filter['header'] as List?;
    if (header != null && refuseHeaderFilter) {
      return _error('unsupportedFilter');
    }
    final box = filter['inMailbox'] as String?;
    if (header == null) listings++;
    final all = [
      for (final e in _emails.values)
        if ((box == null || e.mailboxIds.contains(box)) &&
            (header != null || !unlisted.contains(e.id)) &&
            (header == null ||
                (e.header(header[0] as String) ?? '')
                    .contains(header[1] as String)))
          e.id,
    ];
    final position = args['position'] as int? ?? 0;
    final limit = args['limit'] as int? ?? all.length;
    final start = position.clamp(0, all.length);
    final end = (start + limit).clamp(0, all.length);
    return [
      'Email/query',
      {
        'accountId': accountId,
        'queryState': 'q$_state',
        'position': start,
        'ids': all.sublist(start, end),
        if (args['calculateTotal'] == true) 'total': all.length,
      },
    ];
  }

  int? _stateOf(Object? token, String prefix) {
    final s = token as String? ?? '';
    if (!s.startsWith(prefix)) return null;
    final n = int.tryParse(s.substring(prefix.length));
    if (n == null || n < _horizon) return null;
    return n;
  }

  List<dynamic> _queryChanges(Map<String, dynamic> args) {
    final error = changesError;
    if (error != null) return _error(error);
    final since = _stateOf(args['sinceQueryState'], 'q');
    if (since == null) return _error('cannotCalculateChanges');
    final box = (args['filter'] as Map<String, dynamic>)['inMailbox'];
    final touched = [
      for (final c in _since(since))
        if (c.boxes.contains(box)) c,
    ];
    final added = [
      for (final c in touched)
        if (!c.destroyed &&
            _emails.containsKey(c.id) &&
            !unlisted.contains(c.id))
          c.id,
    ];
    return [
      'Email/queryChanges',
      {
        'accountId': accountId,
        'oldQueryState': args['sinceQueryState'],
        'newQueryState': 'q$_state',
        'removed': [
          for (final c in touched)
            if (c.destroyed) c.id,
        ],
        'added': [
          for (final (i, id) in added.indexed) {'id': id, 'index': i},
        ],
      },
    ];
  }

  List<dynamic> _emailChanges(Map<String, dynamic> args) {
    final error = changesError;
    if (error != null) return _error(error);
    final since = _stateOf(args['sinceState'], 's');
    if (since == null) return _error('cannotCalculateChanges');
    final all = _since(since).toList();
    final page = all.take(changesPage).toList();
    final more = all.length > page.length;
    return [
      'Email/changes',
      {
        'accountId': accountId,
        'oldState': args['sinceState'],
        'newState': more ? 's${page.last.state}' : 's$_state',
        'hasMoreChanges': more,
        'created': [
          for (final c in page)
            if (!c.destroyed) c.id,
        ],
        'updated': <String>[],
        'destroyed': [
          for (final c in page)
            if (c.destroyed) c.id,
        ],
      },
    ];
  }

  List<dynamic> _import(Map<String, dynamic> args) {
    final created = <String, dynamic>{};
    final notCreated = <String, dynamic>{};
    final emails = args['emails'] as Map<String, dynamic>;
    for (final MapEntry(:key, :value) in emails.entries) {
      final spec = value as Map<String, dynamic>;
      final blob = _blobs[spec['blobId']];
      final error = importError;
      if (error != null || blob == null) {
        notCreated[key] = {'type': error ?? 'blobNotFound'};
        continue;
      }
      final boxes = (spec['mailboxIds'] as Map<String, dynamic>).keys.toSet();
      final bare = FakeJmapEmail('', '', blob, const {}).messageId;
      final twin = _emails.values
          .where((e) => e.messageId == bare && e.mailboxIds.any(boxes.contains))
          .firstOrNull;
      if (dedupeImports && twin != null) {
        notCreated[key] = {'type': 'alreadyExists', 'existingId': twin.id};
        continue;
      }
      final keywords = spec['keywords'] as Map<String, dynamic>? ?? const {};
      final email = _create(blob, boxes, keywords: keywords.keys.toSet());
      created[key] = {'id': email.id, 'blobId': email.blobId};
    }
    return [
      'Email/import',
      {
        'accountId': accountId,
        'created': created,
        if (notCreated.isNotEmpty) 'notCreated': notCreated,
      },
    ];
  }

  List<dynamic> _emailSet(Map<String, dynamic> args) {
    final destroyed = <String>[];
    final notDestroyed = <String, dynamic>{};
    for (final id in List<String>.from(args['destroy'] as List? ?? [])) {
      if (!_emails.containsKey(id)) {
        notDestroyed[id] = {'type': 'notFound'};
        continue;
      }
      _destroy(id);
      destroyed.add(id);
    }
    return [
      'Email/set',
      {
        'accountId': accountId,
        'destroyed': destroyed,
        if (notDestroyed.isNotEmpty) 'notDestroyed': notDestroyed,
      },
    ];
  }
}
