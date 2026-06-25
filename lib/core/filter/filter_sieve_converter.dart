import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/sieve/sieve_actions.dart';

/// Converts a Sieve script (RFC 5228 subset) to a [FilterGroup] + actions,
/// suitable for display in the visual filter editor.
///
/// Returns null if the script uses features outside the supported subset.
class FilterSieveConverter {
  ({FilterGroup group, List<SieveAction> actions})? parse(String script) {
    try {
      final s = _Sc(script);
      s.skip();
      if (s.peekWord() == 'require') {
        s.readWord();
        s.skip();
        _parseStringOrList(s);
        s.skip();
        s.expectChar(';');
        s.skip();
      }
      if (s.peekWord() != 'if') return null;
      s.readWord();
      s.skip();
      final node = _parseTest(s);
      if (node == null) return null;
      s.skip();
      s.expectChar('{');
      s.skip();
      final actions = <SieveAction>[];
      while (s.peek() != '}' && !s.isAtEnd) {
        final action = _parseAction(s);
        if (action == null) return null;
        actions.add(action);
        s.skip();
      }
      s.expectChar('}');
      final group = switch (node) {
        final FilterGroup g => g,
        final FilterLeaf l =>
          FilterGroup(operator: FilterOperator.and_, children: [l]),
      };
      return (group: group, actions: actions);
    } catch (_) {
      return null;
    }
  }

  FilterNode? _parseTest(_Sc s) {
    s.skip();
    final word = s.peekWord()?.toLowerCase();
    if (word == null) return null;
    if (word == 'allof' || word == 'anyof') {
      s.readWord();
      s.skip();
      s.expectChar('(');
      final op = word == 'allof' ? FilterOperator.and_ : FilterOperator.or_;
      final children = <FilterNode>[];
      while (true) {
        s.skip();
        if (s.peek() == ')') break;
        final child = _parseTest(s);
        if (child == null) return null;
        children.add(child);
        s.skip();
        if (s.peek() == ',') s.advance();
      }
      s.expectChar(')');
      return FilterGroup(operator: op, children: children);
    }
    return _parseSingleTest(s);
  }

  FilterLeaf? _parseSingleTest(_Sc s) {
    s.skip();
    final word = s.peekWord()?.toLowerCase();
    if (word == null) return null;

    if (word == 'address') {
      s.readWord();
      s.skip();
      final matchType = s.readTaggedArg();
      s.skip();
      final headers = _parseStringOrList(s);
      s.skip();
      final values = _parseStringOrList(s);
      final field = switch (headers.firstOrNull?.toLowerCase()) {
        'from' => FilterField.from_,
        'to' => FilterField.to,
        'cc' => FilterField.cc,
        _ => null,
      };
      if (field == null) return null;
      final comp = _comp(matchType);
      if (comp == null) return null;
      return FilterLeaf(
        field: field,
        comparison: comp,
        value: values.firstOrNull ?? '',
      );
    }

    if (word == 'header') {
      s.readWord();
      s.skip();
      final matchType = s.readTaggedArg();
      s.skip();
      final headers = _parseStringOrList(s);
      s.skip();
      final values = _parseStringOrList(s);
      if (headers.firstOrNull?.toLowerCase() != 'subject') return null;
      final comp = _comp(matchType);
      if (comp == null) return null;
      return FilterLeaf(
        field: FilterField.subject,
        comparison: comp,
        value: values.firstOrNull ?? '',
      );
    }

    if (word == 'size') {
      s.readWord();
      s.skip();
      final compTag = s.readTaggedArg();
      s.skip();
      final numStr = s.readDigits();
      final comp = switch (compTag.toLowerCase()) {
        ':over' => FilterComparison.over,
        ':under' => FilterComparison.under,
        _ => null,
      };
      if (comp == null) return null;
      return FilterLeaf(
        field: FilterField.size,
        comparison: comp,
        value: numStr,
      );
    }

    return null;
  }

  FilterComparison? _comp(String tag) => switch (tag.toLowerCase()) {
        ':contains' => FilterComparison.contains,
        ':is' => FilterComparison.is_,
        ':matches' => FilterComparison.matches,
        _ => null,
      };

  SieveAction? _parseAction(_Sc s) {
    s.skip();
    final word = s.peekWord()?.toLowerCase();
    if (word == null) return null;
    if (word == 'fileinto') {
      s.readWord();
      s.skip();
      final folder = _parseString(s);
      s.skip();
      s.expectChar(';');
      return FileIntoAction(folder);
    }
    if (word == 'keep') {
      s.readWord();
      s.skip();
      s.expectChar(';');
      return KeepAction();
    }
    if (word == 'discard') {
      s.readWord();
      s.skip();
      s.expectChar(';');
      return DiscardAction();
    }
    if (word == 'setflag' || word == 'addflag') {
      s.readWord();
      s.skip();
      final flags = _parseStringOrList(s);
      s.skip();
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
    return null;
  }

  List<String> _parseStringOrList(_Sc s) {
    s.skip();
    if (s.peek() == '[') {
      s.advance();
      final items = <String>[];
      while (true) {
        s.skip();
        if (s.peek() == ']') {
          s.advance();
          break;
        }
        items.add(_parseString(s));
        s.skip();
        if (s.peek() == ',') s.advance();
      }
      return items;
    }
    return [_parseString(s)];
  }

  String _parseString(_Sc s) {
    s.skip();
    return s.readQuotedString();
  }
}

// Minimal scanner for the supported Sieve subset.
class _Sc {
  _Sc(this._src);
  final String _src;
  int _pos = 0;

  bool get isAtEnd => _pos >= _src.length;
  String? peek() => isAtEnd ? null : _src[_pos];

  String advance() {
    if (isAtEnd) throw _ScanErr('Unexpected end');
    return _src[_pos++];
  }

  void skip() {
    while (!isAtEnd) {
      final ch = _src[_pos];
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        _pos++;
      } else if (ch == '#') {
        while (!isAtEnd && _src[_pos] != '\n') {
          _pos++;
        }
      } else if (_pos + 1 < _src.length && ch == '/' && _src[_pos + 1] == '*') {
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

  String? peekWord() {
    if (isAtEnd) return null;
    final ch = _src[_pos];
    if ('{}();[],'.contains(ch)) return ch;
    if (ch == ':') {
      var end = _pos + 1;
      while (end < _src.length && _wc(_src[end])) {
        end++;
      }
      return _src.substring(_pos, end).toLowerCase();
    }
    if (_wc(ch)) {
      var end = _pos + 1;
      while (end < _src.length && _wc(_src[end])) {
        end++;
      }
      return _src.substring(_pos, end).toLowerCase();
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
      while (!isAtEnd && _wc(_src[_pos])) {
        _pos++;
      }
    } else {
      while (!isAtEnd && _wc(_src[_pos])) {
        _pos++;
      }
    }
    return _src.substring(start, _pos).toLowerCase();
  }

  String readTaggedArg() {
    if (!isAtEnd && _src[_pos] == ':') return readWord();
    throw _ScanErr('Expected tagged arg at $_pos');
  }

  String readDigits() {
    final start = _pos;
    while (!isAtEnd && _dig(_src[_pos])) {
      _pos++;
    }
    if (_pos == start) throw _ScanErr('Expected digits at $_pos');
    return _src.substring(start, _pos);
  }

  String readQuotedString() {
    if (isAtEnd || _src[_pos] != '"') throw _ScanErr('Expected " at $_pos');
    _pos++;
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
    throw _ScanErr('Unterminated string');
  }

  void expectChar(String ch) {
    skip();
    if (isAtEnd || _src[_pos] != ch) {
      throw _ScanErr(
        'Expected "$ch" at $_pos, got ${isAtEnd ? "EOF" : _src[_pos]}',
      );
    }
    _pos++;
  }

  static bool _wc(String ch) {
    final c = ch.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x5F ||
        c == 0x2D;
  }

  static bool _dig(String ch) {
    final c = ch.codeUnitAt(0);
    return c >= 0x30 && c <= 0x39;
  }
}

class _ScanErr implements Exception {
  _ScanErr(this.message);
  final String message;
}
