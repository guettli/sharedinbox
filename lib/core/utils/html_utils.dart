/// Strips HTML tags and decodes entities to produce plain text.
///
/// Not a full HTML parser — handles the common subset found in email bodies.
///
/// Entities are decoded **before** tags are stripped (issue #682): otherwise
/// markup that was escaped in the source (`&lt;tr&gt;`) reappears as literal
/// text in the output. The trade is that deliberately-escaped markup shown as
/// code (`&lt;script&gt;`) is stripped too — acceptable here because every
/// caller renders plain-text / preview snippets, not source listings.
String htmlToPlain(String html) => _decodeEntities(html)
    // Drop the *content* of these before stripping tags: an email's <style>
    // block would otherwise turn into a preview full of CSS.
    .replaceAll(
      RegExp(
        r'<(style|script|head)\b[^>]*>.*?</\1>',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    )
    // A truncated body (the sync preview only sees the first few KB) can end
    // mid-<style>: drop the unclosed remainder too.
    .replaceAll(
      RegExp(
        r'<(style|script|head)\b[^>]*>.*$',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    )
    .replaceAll(RegExp(r'<br\s*/?>'), '\n')
    .replaceAll(RegExp(r'<p\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'</p>', caseSensitive: false), '')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    // A truncated snippet can end inside a tag — an email whose first
    // kilobytes are one long inline-styled <div> would otherwise show its
    // markup as the preview.
    .replaceAll(RegExp(r'<[^>]*$'), '')
    .trim();

/// Named HTML entities [_decodeEntities] handles. `&amp;` is deliberately not
/// here — it is applied last so an already-escaped entity (`&amp;lt;`) is not
/// double-decoded.
const Map<String, String> _namedEntities = {
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&apos;': "'",
  '&nbsp;': ' ',
  '&zwnj;': '\u200C',
  '&zwj;': '\u200D',
  '&zwsp;': '\u200B',
  '&shy;': '\u00AD',
  '&hellip;': '…',
  '&mdash;': '—',
  '&ndash;': '–',
  '&lsquo;': '‘',
  '&rsquo;': '’',
  '&ldquo;': '“',
  '&rdquo;': '”',
  '&trade;': '™',
  '&reg;': '®',
  '&copy;': '©',
  '&euro;': '€',
  '&pound;': '£',
};

/// Zero-width / invisible code points marketing mail pads its preheader with;
/// dropped so they don't survive into the preview (issue #682). Covers the
/// zero-width space/joiners (U+200B–U+200D), the BOM (U+FEFF), the combining
/// grapheme joiner (U+034F, the `&#847;` seen in real mail), and the soft
/// hyphen (U+00AD).
final RegExp _zeroWidth = RegExp('[\u200B-\u200D\uFEFF\u034F\u00AD]');

/// Decodes numeric (`&#NNN;` / `&#xHH;`) and the common named entities, then
/// strips zero-width padding. A malformed or out-of-range code point is left as
/// written rather than throwing.
String _decodeEntities(String s) {
  var out = s.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) => _fromCodePoint(int.tryParse(m[1]!), m[0]!),
  );
  out = out.replaceAllMapped(
    RegExp(r'&#[xX]([0-9a-fA-F]+);'),
    (m) => _fromCodePoint(int.tryParse(m[1]!, radix: 16), m[0]!),
  );
  _namedEntities.forEach((k, v) => out = out.replaceAll(k, v));
  out = out.replaceAll('&amp;', '&');
  return out.replaceAll(_zeroWidth, '');
}

/// Renders a numeric character reference, or returns [original] when the code
/// point is missing, negative, past U+10FFFF, or a lone surrogate half.
String _fromCodePoint(int? code, String original) {
  if (code == null ||
      code < 0 ||
      code > 0x10FFFF ||
      (code >= 0xD800 && code <= 0xDFFF)) {
    return original;
  }
  return String.fromCharCode(code);
}
