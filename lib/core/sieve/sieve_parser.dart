import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_conditions.dart';
import 'package:sharedinbox/core/sieve/sieve_rule.dart';

/// Parses a Sieve script (RFC 5228 subset) into a flat list of [SieveRule]s.
///
/// Supported commands: require, if, elsif, else, fileinto, keep, discard,
/// flag, setflag, addflag, stop.
/// Supported tests: header, address, size, exists, allof, anyof, not, true.
/// Supported match types: :contains, :is, :matches.
class SieveParser {
  List<SieveRule> parse(String script) {
    final scanner = _Scanner(script);
    final rules = <SieveRule>[];
    _parseStatements(scanner, rules);
    return rules;
  }

  void _parseStatements(_Scanner s, List<SieveRule> out) {
    while (!s.isAtEnd) {
      s.skipWhitespaceAndComments();
      if (s.isAtEnd) break;

      final word = s.peekWord();
      if (word == null) break;

      if (word == 'require') {
        _parseRequire(s);
      } else if (word == 'if') {
        _parseIf(s, out);
      } else if (word == 'elsif' || word == 'else') {
        // Reached by _parseIf, should not appear at top level.
        break;
      } else if (word == '}') {
        break;
      } else {
        final action = _tryParseAction(s);
        if (action != null) {
          out.add(
            SieveRule(
              joinType: 'single',
              conditions: const [],
              actions: [action],
            ),
          );
        } else {
          s.skipToNextSemicolon();
        }
      }
    }
  }

  void _parseRequire(_Scanner s) {
    s.expectWord('require');
    s.skipWhitespaceAndComments();
    _parseStringOrList(s); // discard capability list
    s.skipWhitespaceAndComments();
    s.expectChar(';');
  }

  // Monotonically increasing id shared per parse run, threaded via closure.
  int _groupCounter = 0;

  void _parseIf(_Scanner s, List<SieveRule> out) {
    final groupId = ++_groupCounter;

    s.expectWord('if');
    s.skipWhitespaceAndComments();
    final (joinType, conditions) = _parseTest(s);
    s.skipWhitespaceAndComments();
    final ifActions = _parseBlock(s);

    out.add(
      SieveRule(
        joinType: joinType,
        conditions: conditions,
        actions: ifActions,
        branchGroupId: groupId,
      ),
    );

    // Parse zero or more elsif branches.
    while (true) {
      s.skipWhitespaceAndComments();
      if (s.peekWord() != 'elsif') break;
      s.expectWord('elsif');
      s.skipWhitespaceAndComments();
      final (ej, ec) = _parseTest(s);
      s.skipWhitespaceAndComments();
      final elsifActions = _parseBlock(s);
      out.add(
        SieveRule(
          joinType: ej,
          conditions: ec,
          actions: elsifActions,
          branchGroupId: groupId,
        ),
      );
    }

    // Optional else branch.
    s.skipWhitespaceAndComments();
    if (s.peekWord() == 'else') {
      s.expectWord('else');
      s.skipWhitespaceAndComments();
      final elseActions = _parseBlock(s);
      out.add(
        SieveRule(
          joinType: 'single',
          conditions: const [],
          actions: elseActions,
          branchGroupId: groupId,
          isElseBranch: true,
        ),
      );
    }
  }

  List<SieveAction> _parseBlock(_Scanner s) {
    s.expectChar('{');
    final blockRules = <SieveRule>[];
    _parseStatements(s, blockRules);
    s.skipWhitespaceAndComments();
    s.expectChar('}');
    return blockRules.expand((r) => r.actions).toList();
  }

  /// Returns (joinType, conditions).
  (String, List<SieveCondition>) _parseTest(_Scanner s) {
    s.skipWhitespaceAndComments();
    final word = s.peekWord();

    if (word == 'allof' || word == 'anyof') {
      s.readWord();
      s.skipWhitespaceAndComments();
      s.expectChar('(');
      final conditions = <SieveCondition>[];
      while (true) {
        s.skipWhitespaceAndComments();
        if (s.peek() == ')') break;
        final (_, conds) = _parseTest(s);
        conditions.addAll(conds);
        s.skipWhitespaceAndComments();
        if (s.peek() == ',') {
          s.advance();
        } else {
          break;
        }
      }
      s.skipWhitespaceAndComments();
      s.expectChar(')');
      return (word!, conditions);
    }

    final cond = _parseSingleTest(s);
    return ('single', cond != null ? [cond] : []);
  }

  SieveCondition? _parseSingleTest(_Scanner s) {
    s.skipWhitespaceAndComments();
    final word = s.peekWord()?.toLowerCase();
    if (word == null) return null;

    if (word == 'not') {
      s.readWord();
      s.skipWhitespaceAndComments();
      // Negation is not represented in the flat rule model; the `not` operator is
      // dropped and the inner condition is returned unchanged (best-effort for this subset).
      return _parseSingleTest(s);
    }

    if (word == 'true') {
      s.readWord();
      return null; // no condition = always matches
    }

    if (word == 'header' || word == 'address') {
      s.readWord();
      s.skipWhitespaceAndComments();
      final matchType = _parseMatchType(s);
      s.skipWhitespaceAndComments();
      // Consume optional :comparator "..." tagged argument.
      if (s.peekTaggedArg() == ':comparator') {
        s.readWord();
        s.skipWhitespaceAndComments();
        _parseStringOrList(s); // discard comparator value
        s.skipWhitespaceAndComments();
      }
      final headers = _parseStringOrList(s);
      s.skipWhitespaceAndComments();
      final keys = _parseStringOrList(s);
      return HeaderCondition(headers, matchType, keys);
    }

    if (word == 'exists') {
      s.readWord();
      s.skipWhitespaceAndComments();
      final headers = _parseStringOrList(s);
      // Represent exists as :contains "" so any non-empty value matches.
      return HeaderCondition(headers, ':contains', const ['']);
    }

    if (word == 'size') {
      s.readWord();
      s.skipWhitespaceAndComments();
      final comp = s.readTaggedArg(); // :over or :under
      s.skipWhitespaceAndComments();
      final bytes = _parseSizeNumber(s);
      return SizeCondition(comp, bytes);
    }

    // Unknown test — skip to closing paren or brace.
    s.readWord();
    return null;
  }

  String _parseMatchType(_Scanner s) {
    s.skipWhitespaceAndComments();
    final tag = s.peekTaggedArg();
    if (tag == ':contains' || tag == ':is' || tag == ':matches') {
      s.readWord();
      return tag!;
    }
    // Default per RFC 5228 is :is.
    return ':is';
  }

  List<String> _parseStringOrList(_Scanner s) {
    s.skipWhitespaceAndComments();
    if (s.peek() == '[') {
      s.advance(); // consume '['
      final items = <String>[];
      while (true) {
        s.skipWhitespaceAndComments();
        if (s.peek() == ']') {
          s.advance();
          break;
        }
        items.add(_parseString(s));
        s.skipWhitespaceAndComments();
        if (s.peek() == ',') {
          s.advance();
        }
      }
      return items;
    }
    return [_parseString(s)];
  }

  String _parseString(_Scanner s) {
    s.skipWhitespaceAndComments();
    if (s.peek() == '"') {
      return s.readQuotedString();
    }
    // Multi-line text: text:...\r\n.\r\n  (RFC 5228 §2.4.2)
    if (s.peekWord()?.toLowerCase() == 'text:') {
      return s.readTextBlock();
    }
    throw SieveParseException(
      'Expected string at position ${s.position}: "${s.remaining.substring(0, 20)}"',
    );
  }

  int _parseSizeNumber(_Scanner s) {
    final digits = s.readDigits();
    final value = int.parse(digits);
    final unit = s.peekSizeUnit();
    if (unit != null) {
      s.advance();
      return switch (unit.toUpperCase()) {
        'K' => value * 1024,
        'M' => value * 1024 * 1024,
        'G' => value * 1024 * 1024 * 1024,
        _ => value,
      };
    }
    return value;
  }

  SieveAction? _tryParseAction(_Scanner s) {
    s.skipWhitespaceAndComments();
    final word = s.peekWord()?.toLowerCase();
    if (word == null) return null;

    if (word == 'fileinto') {
      s.readWord();
      s.skipWhitespaceAndComments();
      final folder = _parseString(s);
      s.skipWhitespaceAndComments();
      s.expectChar(';');
      return FileIntoAction(folder);
    }
    if (word == 'keep') {
      s.readWord();
      s.skipWhitespaceAndComments();
      s.expectChar(';');
      return KeepAction();
    }
    if (word == 'discard') {
      s.readWord();
      s.skipWhitespaceAndComments();
      s.expectChar(';');
      return DiscardAction();
    }
    if (word == 'stop') {
      s.readWord();
      s.skipWhitespaceAndComments();
      s.expectChar(';');
      return KeepAction(); // stop with no prior action = implicit keep
    }
    if (word == 'flag' || word == 'setflag' || word == 'addflag') {
      s.readWord();
      s.skipWhitespaceAndComments();
      // Optional variable name (string arg before the flag list).
      final peek = s.peek();
      List<String> flags;
      if (peek == '"') {
        final first = _parseString(s);
        s.skipWhitespaceAndComments();
        if (s.peek() == '[' || s.peek() == '"') {
          // first was the variable name, next is the flag list
          flags = _parseStringOrList(s);
        } else {
          flags = [first];
        }
      } else {
        flags = _parseStringOrList(s);
      }
      s.skipWhitespaceAndComments();
      s.expectChar(';');
      if (flags.any(
        (f) => f.toLowerCase() == r'\seen' || f.toLowerCase() == r'\\seen',
      )) {
        return MarkAsSeenAction();
      }
      if (flags.any(
        (f) =>
            f.toLowerCase() == r'\flagged' ||
            f.toLowerCase() == r'\\flagged',
      )) {
        return StarMessageAction();
      }
      return FlagAction(flags);
    }
    if (word == 'mark') {
      s.readWord();
      s.skipWhitespaceAndComments();
      s.expectChar(';');
      return MarkAsSeenAction();
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Low-level scanner
// ---------------------------------------------------------------------------

class SieveParseException implements Exception {
  SieveParseException(this.message);
  final String message;
  @override
  String toString() => 'SieveParseException: $message';
}

class _Scanner {
  _Scanner(this._src);

  final String _src;
  int _pos = 0;

  int get position => _pos;
  bool get isAtEnd => _pos >= _src.length;
  String get remaining => _pos < _src.length ? _src.substring(_pos) : '';

  String? peek() {
    if (isAtEnd) return null;
    return _src[_pos];
  }

  String advance() {
    if (isAtEnd) throw SieveParseException('Unexpected end of input');
    return _src[_pos++];
  }

  void skipWhitespaceAndComments() {
    while (!isAtEnd) {
      final ch = _src[_pos];
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        _pos++;
      } else if (ch == '#') {
        // Line comment — skip to end of line.
        while (!isAtEnd && _src[_pos] != '\n') {
          _pos++;
        }
      } else if (_pos + 1 < _src.length && ch == '/' && _src[_pos + 1] == '*') {
        // Block comment.
        _pos += 2;
        while (_pos + 1 < _src.length) {
          if (_src[_pos] == '*' && _src[_pos + 1] == '/') {
            _pos += 2;
            break;
          }
          _pos++;
        }
      } else {
        break;
      }
    }
  }

  /// Peeks at the next word-like token (letters/digits/underscores/colons for
  /// tagged args, and special single-char tokens like `{`, `}`, `;`).
  String? peekWord() {
    if (isAtEnd) return null;
    final ch = _src[_pos];
    if ('{}();[],'.contains(ch)) return ch;
    if (ch == ':') {
      // Tagged arg like :contains
      final start = _pos;
      var end = _pos + 1;
      while (end < _src.length && _isWordChar(_src[end])) {
        end++;
      }
      return _src.substring(start, end).toLowerCase();
    }
    if (_isWordChar(ch)) {
      final start = _pos;
      var end = _pos + 1;
      while (
          end < _src.length && (_isWordChar(_src[end]) || _src[end] == ':')) {
        // Include trailing colon for "text:" multiline token.
        if (_src[end] == ':') {
          end++;
          break;
        }
        end++;
      }
      return _src.substring(start, end).toLowerCase();
    }
    return null;
  }

  String readWord() {
    final start = _pos;
    final ch = _src[_pos];
    if ('{}();[],'.contains(ch)) {
      _pos++;
      return ch;
    }
    if (ch == ':') {
      _pos++;
      while (!isAtEnd && _isWordChar(_src[_pos])) {
        _pos++;
      }
    } else {
      while (!isAtEnd && (_isWordChar(_src[_pos]) || _src[_pos] == ':')) {
        if (_src[_pos] == ':') {
          _pos++;
          break;
        }
        _pos++;
      }
    }
    return _src.substring(start, _pos).toLowerCase();
  }

  String? peekTaggedArg() {
    if (!isAtEnd && _src[_pos] == ':') return peekWord();
    return null;
  }

  String readTaggedArg() {
    if (!isAtEnd && _src[_pos] == ':') return readWord();
    throw SieveParseException('Expected tagged argument at position $_pos');
  }

  String? peekSizeUnit() {
    if (isAtEnd) return null;
    final ch = _src[_pos].toUpperCase();
    if (ch == 'K' || ch == 'M' || ch == 'G') return ch;
    return null;
  }

  String readDigits() {
    if (isAtEnd || !_isDigit(_src[_pos])) {
      throw SieveParseException('Expected number at position $_pos');
    }
    final start = _pos;
    while (!isAtEnd && _isDigit(_src[_pos])) {
      _pos++;
    }
    return _src.substring(start, _pos);
  }

  String readQuotedString() {
    if (_src[_pos] != '"') {
      throw SieveParseException('Expected " at position $_pos');
    }
    _pos++; // skip opening quote
    final buf = StringBuffer();
    while (!isAtEnd) {
      final ch = _src[_pos];
      if (ch == '"') {
        _pos++;
        return buf.toString();
      }
      if (ch == '\\' && _pos + 1 < _src.length) {
        _pos++;
        buf.write(_src[_pos]);
        _pos++;
      } else {
        buf.write(ch);
        _pos++;
      }
    }
    throw SieveParseException('Unterminated string');
  }

  /// Parses a `text:` multi-line block (RFC 5228 §2.4.2).
  /// Format: `text:\r\n<lines>\r\n.\r\n`
  String readTextBlock() {
    // Consume "text:"
    while (!isAtEnd && _src[_pos] != ':') {
      _pos++;
    }
    if (!isAtEnd) _pos++; // skip ':'
    // Skip optional whitespace then newline.
    while (!isAtEnd && (_src[_pos] == ' ' || _src[_pos] == '\t')) {
      _pos++;
    }
    if (!isAtEnd && _src[_pos] == '\r') _pos++;
    if (!isAtEnd && _src[_pos] == '\n') _pos++;
    final buf = StringBuffer();
    while (!isAtEnd) {
      // Check for terminator: a lone "." on its own line.
      if (_src[_pos] == '.' &&
          (_pos + 1 >= _src.length ||
              _src[_pos + 1] == '\r' ||
              _src[_pos + 1] == '\n')) {
        _pos++;
        if (!isAtEnd && _src[_pos] == '\r') _pos++;
        if (!isAtEnd && _src[_pos] == '\n') _pos++;
        break;
      }
      buf.write(_src[_pos]);
      _pos++;
    }
    return buf.toString();
  }

  void expectChar(String ch) {
    skipWhitespaceAndComments();
    if (isAtEnd || _src[_pos] != ch) {
      throw SieveParseException(
        'Expected "$ch" at position $_pos, got '
        '"${isAtEnd ? "EOF" : _src[_pos]}"',
      );
    }
    _pos++;
  }

  void expectWord(String word) {
    skipWhitespaceAndComments();
    final got = readWord();
    if (got.toLowerCase() != word.toLowerCase()) {
      throw SieveParseException(
        'Expected "$word" at position $_pos, got "$got"',
      );
    }
  }

  void skipToNextSemicolon() {
    while (!isAtEnd && _src[_pos] != ';') {
      _pos++;
    }
    if (!isAtEnd) _pos++; // skip ';'
  }

  static bool _isWordChar(String ch) {
    final c = ch.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        (c >= 0x30 && c <= 0x39) || // 0-9
        c == 0x5F || // _
        c == 0x2D; // -
  }

  static bool _isDigit(String ch) {
    final c = ch.codeUnitAt(0);
    return c >= 0x30 && c <= 0x39;
  }
}
