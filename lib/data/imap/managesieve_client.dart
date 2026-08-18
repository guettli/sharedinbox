import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sharedinbox/data/imap/imap_client_factory.dart'
    show verboseLogKey;
import 'package:sharedinbox/data/imap/tls_error.dart';

/// Minimal ManageSieve (RFC 5804) client used by [SieveRepository] to
/// list / fetch / upload / activate / delete server-side Sieve scripts on
/// IMAP-style mail servers (e.g. Stalwart, Dovecot, Cyrus).
///
/// Only the small subset needed by the app is implemented:
/// STARTTLS, AUTHENTICATE PLAIN, LISTSCRIPTS, GETSCRIPT, PUTSCRIPT,
/// SETACTIVE, DELETESCRIPT, LOGOUT.
class ManageSieveClient {
  ManageSieveClient._(this._socket, this._source);

  final Socket _socket;
  final _ByteSource _source;
  bool _closed = false;

  /// Connects to [host]:[port] in plaintext, reads the capability greeting,
  /// and — when [useTls] is true — upgrades the connection with STARTTLS per
  /// RFC 5804 §1.7 before returning. Implicit-TLS ManageSieve is non-standard
  /// and not supported here; if [useTls] is true the server must advertise
  /// the `STARTTLS` capability.
  static Future<ManageSieveClient> connect({
    required String host,
    required int port,
    required bool useTls,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    // ignore: close_sinks  // Stored in client and closed in logout().
    Socket socket = await Socket.connect(host, port, timeout: timeout);
    var source = _ByteSource();
    var sub = _attach(socket, source);
    try {
      final greeting = await _readResponseFromSource(source);
      if (greeting.status != _Status.ok) {
        throw ManageSieveException(
          'Capability greeting failed: ${greeting.message}',
        );
      }
      if (!useTls) {
        return ManageSieveClient._(socket, source);
      }
      if (!_advertisesStartTls(greeting.dataLines)) {
        throw const ManageSieveException(
          'Server does not advertise STARTTLS — disable SSL for ManageSieve '
          'in account settings, or use a server that supports STARTTLS.',
        );
      }
      await _writeLineTo(socket, 'STARTTLS');
      final ok = await _readResponseFromSource(source);
      if (ok.status != _Status.ok) {
        throw ManageSieveException('STARTTLS rejected: ${ok.message}');
      }
      // Detach plaintext listener before handing the socket to TLS.
      await sub.cancel();
      try {
        socket = await SecureSocket.secure(socket, host: host);
      } catch (e, st) {
        // Surface the server's STARTTLS reply in the wrapped error — it
        // sometimes reveals why the upgrade aborted (e.g. an OK message
        // pointing at a missing cert, or a partial reply that explains a
        // truncated TLS negotiation).
        final hint = ok.message.isEmpty
            ? 'STARTTLS reply: OK'
            : 'STARTTLS reply: OK ${ok.message}';
        rethrowAsTlsHint(e, st, host, port, hint: hint);
      }
      source = _ByteSource();
      sub = _attach(socket, source);
      // RFC 5804 §1.7: server re-sends capability listing on the secured
      // connection. Read and discard it so the response stream stays aligned.
      final reCap = await _readResponseFromSource(source);
      if (reCap.status != _Status.ok) {
        throw ManageSieveException(
          'Post-STARTTLS capability failed: ${reCap.message}',
        );
      }
      return ManageSieveClient._(socket, source);
    } catch (_) {
      await sub.cancel();
      try {
        await socket.close();
      } catch (_) {
        /* best-effort */
      }
      rethrow;
    }
  }

  static StreamSubscription<List<int>> _attach(
    Socket socket,
    _ByteSource source,
  ) {
    return socket.listen(
      source._add,
      onDone: () => source._close(),
      onError: (Object e, StackTrace _) => source._close(e),
      cancelOnError: true,
    );
  }

  static bool _advertisesStartTls(List<String> capLines) {
    for (final line in capLines) {
      // Capability tokens are quoted-strings, e.g. `"STARTTLS"`. Match the
      // first token on each line, case-insensitively.
      final m = RegExp(r'^\s*"?([A-Za-z0-9-]+)"?').firstMatch(line);
      if (m != null && m.group(1)!.toUpperCase() == 'STARTTLS') return true;
    }
    return false;
  }

  static Future<void> _writeLineTo(Socket socket, String line) async {
    final log = Zone.current[verboseLogKey] as StringSink?;
    if (log != null) log.writeln('SIEVE → $line');
    socket.add(utf8.encode(line));
    socket.add(_crlf);
    await socket.flush();
  }

  /// Authenticates with SASL PLAIN. Throws [ManageSieveException] on failure.
  Future<void> authenticatePlain(String username, String password) async {
    // SASL PLAIN: "\0username\0password" base64-encoded (RFC 4616).
    final payload = <int>[
      0,
      ...utf8.encode(username),
      0,
      ...utf8.encode(password),
    ];
    final initial = base64.encode(payload);
    await _writeLine('AUTHENTICATE "PLAIN" "$initial"');
    final resp = await _readResponse();
    if (resp.status != _Status.ok) {
      throw ManageSieveException('Authentication failed: ${resp.message}');
    }
  }

  /// Returns all scripts on the server, marking which one (if any) is active.
  Future<List<ManageSieveScript>> listScripts() async {
    await _writeLine('LISTSCRIPTS');
    final resp = await _readResponse();
    if (resp.status != _Status.ok) {
      throw ManageSieveException('LISTSCRIPTS failed: ${resp.message}');
    }
    return resp.dataLines.map(_parseListScriptLine).toList();
  }

  /// Returns the raw text of the script named [scriptName].
  Future<String> getScript(String scriptName) async {
    await _writeLine('GETSCRIPT "${_quote(scriptName)}"');
    final resp = await _readResponse();
    if (resp.status != _Status.ok) {
      throw ManageSieveException('GETSCRIPT failed: ${resp.message}');
    }
    if (resp.dataLines.isEmpty) return '';
    // Server returns the script body as a single literal data line.
    return resp.dataLines.first;
  }

  /// Uploads or replaces a script with [scriptName] and the given [content].
  Future<void> putScript(String scriptName, String content) async {
    final bytes = utf8.encode(content);
    await _writeLine(
      'PUTSCRIPT "${_quote(scriptName)}" {${bytes.length}+}',
      then: () async {
        _socket.add(bytes);
        _socket.add(_crlf);
        await _socket.flush();
      },
    );
    final resp = await _readResponse();
    if (resp.status != _Status.ok) {
      throw ManageSieveException('PUTSCRIPT failed: ${resp.message}');
    }
  }

  /// Marks [scriptName] as the active script. Pass an empty string to
  /// deactivate all scripts (RFC 5804 §2.8).
  Future<void> setActive(String scriptName) async {
    await _writeLine('SETACTIVE "${_quote(scriptName)}"');
    final resp = await _readResponse();
    if (resp.status != _Status.ok) {
      throw ManageSieveException('SETACTIVE failed: ${resp.message}');
    }
  }

  Future<void> deleteScript(String scriptName) async {
    await _writeLine('DELETESCRIPT "${_quote(scriptName)}"');
    final resp = await _readResponse();
    if (resp.status != _Status.ok) {
      throw ManageSieveException('DELETESCRIPT failed: ${resp.message}');
    }
  }

  Future<void> logout() async {
    if (_closed) return;
    _closed = true;
    try {
      await _writeLine('LOGOUT');
      // Server may respond with OK then close — read once, ignore failures.
      await _readResponse().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Best-effort.
    } finally {
      await _socket.close();
    }
  }

  // ── internals ───────────────────────────────────────────────────────────

  static const List<int> _crlf = [0x0D, 0x0A];

  Future<void> _writeLine(String line, {Future<void> Function()? then}) async {
    final log = Zone.current[verboseLogKey] as StringSink?;
    if (log != null) {
      // Redact AUTHENTICATE PLAIN payload — contains base64-encoded password.
      log.writeln(
        line.startsWith('AUTHENTICATE')
            ? 'SIEVE → AUTHENTICATE "PLAIN" <redacted>'
            : 'SIEVE → $line',
      );
    }
    _socket.add(utf8.encode(line));
    _socket.add(_crlf);
    await _socket.flush();
    if (then != null) {
      await then();
    }
  }

  Future<_Response> _readResponse() => _readResponseFromSource(_source);

  static Future<_Response> _readResponseFromSource(_ByteSource source) async {
    final dataLines = <String>[];
    final log = Zone.current[verboseLogKey] as StringSink?;
    while (true) {
      final lineBytes = await source.takeLine();
      var line = utf8.decode(lineBytes);
      // Detect a trailing literal: line ends with `{NNN}` or `{NNN+}`.
      final lit = RegExp(r'\{(\d+)\+?\}\s*$').firstMatch(line);
      if (lit != null) {
        final n = int.parse(lit.group(1)!);
        final body = await source.takeBytes(n);
        // After the literal, the server emits the rest of the line — typically
        // empty plus CRLF. Consume it so the next iteration is line-aligned.
        await source.takeLine();
        line = utf8.decode(body);
        if (log != null) {
          log.writeln('SIEVE ← <literal $n bytes>');
        }
        dataLines.add(line);
        continue;
      }
      if (log != null) {
        log.writeln('SIEVE ← $line');
      }
      final upper = line.toUpperCase();
      if (upper.startsWith('OK')) {
        return _Response(
          _Status.ok,
          line.length > 2 ? line.substring(2).trim() : '',
          dataLines,
        );
      }
      if (upper.startsWith('NO')) {
        return _Response(
          _Status.no,
          line.length > 2 ? line.substring(2).trim() : '',
          dataLines,
        );
      }
      if (upper.startsWith('BYE')) {
        return _Response(
          _Status.bye,
          line.length > 3 ? line.substring(3).trim() : '',
          dataLines,
        );
      }
      dataLines.add(line);
    }
  }

  /// Escapes `\` and `"` for embedding inside an RFC 5804 quoted string.
  static String _quote(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

class ManageSieveScript {
  ManageSieveScript({required this.name, required this.isActive});
  final String name;
  final bool isActive;
}

ManageSieveScript _parseListScriptLine(String line) {
  // LISTSCRIPTS response per RFC 5804 §2.7:
  //   "name" [ACTIVE]
  // The name is a quoted-string (or literal — already inlined by the parser).
  var rest = line.trim();
  String name;
  if (rest.startsWith('"')) {
    final end = _findClosingQuote(rest, 1);
    name = _unquote(rest.substring(1, end));
    rest = rest.substring(end + 1).trim();
  } else {
    // Bare token (literal already inlined as the whole "line").
    name = rest;
    rest = '';
  }
  final isActive = rest.toUpperCase() == 'ACTIVE';
  return ManageSieveScript(name: name, isActive: isActive);
}

int _findClosingQuote(String s, int from) {
  for (var i = from; i < s.length; i++) {
    if (s[i] == r'\' && i + 1 < s.length) {
      i++;
      continue;
    }
    if (s[i] == '"') return i;
  }
  return s.length;
}

String _unquote(String s) => s.replaceAll(r'\\', '\\').replaceAll(r'\"', '"');

enum _Status { ok, no, bye }

class _Response {
  _Response(this.status, this.message, this.dataLines);
  final _Status status;
  final String message;
  final List<String> dataLines;
}

class ManageSieveException implements Exception {
  const ManageSieveException(this.message);
  final String message;
  @override
  String toString() => 'ManageSieveException: $message';
}

class _ByteSource {
  final List<int> _buffer = [];
  Completer<void>? _waiter;
  bool _closed = false;
  Object? _error;

  void _add(List<int> data) {
    _buffer.addAll(data);
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  void _close([Object? error]) {
    _closed = true;
    _error = error;
    final w = _waiter;
    _waiter = null;
    if (w == null) return;
    if (error != null) {
      w.completeError(error);
    } else {
      w.complete();
    }
  }

  Future<List<int>> takeLine() async {
    while (true) {
      for (var i = 0; i + 1 < _buffer.length; i++) {
        if (_buffer[i] == 13 && _buffer[i + 1] == 10) {
          final line = _buffer.sublist(0, i);
          _buffer.removeRange(0, i + 2);
          return line;
        }
      }
      if (_closed) {
        if (_error != null) {
          throw _error!;
        }
        throw const ManageSieveException('Connection closed unexpectedly');
      }
      _waiter = Completer<void>();
      await _waiter!.future;
    }
  }

  Future<List<int>> takeBytes(int n) async {
    while (_buffer.length < n) {
      if (_closed) {
        if (_error != null) throw _error!;
        throw const ManageSieveException(
          'Connection closed before literal completed',
        );
      }
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final out = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return out;
  }
}
