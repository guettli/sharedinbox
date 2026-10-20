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
    .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
    .replaceAll(RegExp(r'<br\s*/?>'), '\n')
    .replaceAll(RegExp(r'<p\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'</p>', caseSensitive: false), '')
    // Block ends start a new line and table cells are set apart, so a
    // layout table does not run together ("ItemPriceMug5 €").
    .replaceAll(
      RegExp(
        r'</(?:div|tr|li|h[1-6]|table|ul|ol|blockquote)\s*>',
        caseSensitive: false,
      ),
      '\n',
    )
    .replaceAll(RegExp(r'</t[dh]\s*>', caseSensitive: false), ' ')
    .replaceAll(_tag, '')
    // A truncated snippet can end inside a tag — an email whose first
    // kilobytes are one long inline-styled <div> would otherwise show its
    // markup as the preview.
    .replaceAll(RegExp(r'</?[a-zA-Z][^>]*$'), '')
    .replaceAll(RegExp(r'\n[ \t]*\n(?:[ \t]*\n)+'), '\n\n')
    .trim();

/// An HTML tag: `<`, an optional `/`, a name starting with a letter, then
/// attributes or the end. Text that merely sits in angle brackets is not a
/// tag and survives: since entities are decoded first, the stricter `<[^>]+>`
/// used to delete "Prices &lt;50%&gt; off" down to "Prices  off" and the
/// "&lt;john@example.com&gt;" of a quoted "From:" line.
final RegExp _tag = RegExp(
  r'<!?/?[a-zA-Z][a-zA-Z0-9:-]*(?:\s[^>]*)?/?>',
);

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

/// An optional attribute/CSS quote: a literal `"`/`'` or its named, decimal or
/// hex entity form, as found inside `style="..."`.
const String _q = r'''(?:["']|&quot;|&apos;|&#0*3[49];|&#x0*2[27];)?\s*''';

/// The start of a URL fetched over the network: `http:`, `https:` or
/// protocol-relative `//`.
const String _remote = r'(?:https?:|//)';

/// Any spot where the email WebView would fetch a remote image:
/// - `src=`, `background=`, `poster=` and CSS `url(...)` pointing at [_remote];
/// - SVG `<image>`/`<feImage>` with `href=` or `xlink:href=`;
/// - a remote candidate anywhere in `srcset` (not only the first);
/// - a remote candidate anywhere in CSS `image-set(...)`, which accepts bare
///   strings without `url()`.
final RegExp _remoteResource = RegExp(
  '(?:${[
    r'\b(?:src|background|poster)\s*=\s*' + _q,
    r'url\(\s*' + _q,
    r'<(?:image|feimage)\b[^>]*?\b(?:xlink:)?href\s*=\s*' + _q,
    r'''\bsrcset\s*=\s*["']?[^"'>]*?''',
    r'image-set\([^}>]*?',
  ].join('|')})$_remote',
  caseSensitive: false,
);

/// Whether [html] references any resource the email WebView would fetch from
/// the network once remote images are allowed (`<img src>`, `srcset`, legacy
/// `background=`, CSS `url(...)`/`image-set(...)`, SVG `<image href>`).
///
/// Used to hide the "Load remote images" button on mail that has nothing to
/// load. Inline `cid:` and `data:` images never match. Not a full parser: it
/// errs on the side of matching, so a false positive only shows the button
/// (e.g. a lazy-load `data-src=` also matches).
bool htmlHasRemoteResources(String html) => _remoteResource.hasMatch(html);
