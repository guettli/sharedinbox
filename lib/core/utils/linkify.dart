/// A URL found inside a plain-text string, with the byte offsets of the match.
class UrlMatch {
  const UrlMatch({required this.start, required this.end, required this.url});
  final int start;
  final int end;
  final String url;
}

// Matches http:// and https:// URLs. Consumes anything that is not whitespace
// or one of a few characters that never appear inside a URL in practice; the
// caller then trims trailing punctuation.
final _urlPattern = RegExp(r'https?://[^\s<>"' "'" r']+', caseSensitive: false);

// Characters that commonly follow a URL as part of the surrounding sentence
// (e.g. "See https://example.com.") and should not be included in the link.
const _trailingPunctuation = '.,;:!?';

/// Finds all http(s) URLs inside [text], returning their positions and text.
///
/// Trailing sentence punctuation is stripped, and unbalanced trailing
/// parentheses or brackets are excluded so URLs wrapped in `(...)` or `[...]`
/// come out clean.
List<UrlMatch> findUrls(String text) {
  final matches = <UrlMatch>[];
  for (final m in _urlPattern.allMatches(text)) {
    final start = m.start;
    var end = m.end;

    while (end > start) {
      final ch = text[end - 1];
      if (_trailingPunctuation.contains(ch)) {
        end--;
        continue;
      }
      if (ch == ')' && !_balanced(text, start, end, '(', ')')) {
        end--;
        continue;
      }
      if (ch == ']' && !_balanced(text, start, end, '[', ']')) {
        end--;
        continue;
      }
      break;
    }

    if (end > start) {
      matches.add(
        UrlMatch(start: start, end: end, url: text.substring(start, end)),
      );
    }
  }
  return matches;
}

bool _balanced(String text, int start, int end, String open, String close) {
  var opens = 0;
  var closes = 0;
  for (var i = start; i < end; i++) {
    if (text[i] == open) opens++;
    if (text[i] == close) closes++;
  }
  return closes <= opens;
}
