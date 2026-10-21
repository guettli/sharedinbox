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
    // A comment, or one cut off by truncation (marketing mail opens with
    // <!--[if mso]> blocks): one pattern, so an unclosed one ends the scan
    // instead of being retried from every later "<!--".
    .replaceAll(RegExp(r'<!--(?:.*?-->|.*$)', dotAll: true), '')
    // Word's downlevel conditionals (<![if !supportLists]>) and processing
    // instructions (<?xml:namespace … />), which carry no tag name.
    .replaceAll(RegExp(r'<!\[[^\]<>]*\]>|<\?[^<>]*>'), '')
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
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
    .replaceAll(RegExp(r'</?[a-zA-Z][^<>]*$'), '')
    .replaceAll(RegExp(r'[ \t]+\n'), '\n')
    .replaceAll(RegExp(r'\n\n\n+'), '\n\n')
    .trim();

/// An HTML tag: `<`, an optional `/`, a name starting with a letter, then
/// attributes or the end. Text that merely sits in angle brackets is not a
/// tag and survives: since entities are decoded first, the stricter `<[^>]+>`
/// used to delete "Prices &lt;50%&gt; off" down to "Prices  off" and the
/// "&lt;john@example.com&gt;" of a quoted "From:" line.
///
/// Attributes may not contain `<`: real tags never do, and stopping there
/// keeps a body full of unclosed "<a " from being rescanned to its end from
/// every one of them.
final RegExp _tag = RegExp(
  r'<!?/?[a-zA-Z][a-zA-Z0-9:-]*(?:[\s/][^<>]*)?>',
);

/// Named HTML entities [_decodeEntities] decodes: all of Latin-1
/// (`&auml;`, `&eacute;`, `&szlig;`, …), the Windows-1252 extras mail tools
/// emit (`&bdquo;`, `&euro;`, `&bull;`, …) and the markup ones. Names are
/// case-sensitive (`&Auml;` is not `&auml;`). `&nbsp;` becomes a plain
/// space: the result is plain text, not layout.
const Map<String, int> _namedEntities = {
  'nbsp': 0x20,
  'iexcl': 0xA1,
  'cent': 0xA2,
  'pound': 0xA3,
  'curren': 0xA4,
  'yen': 0xA5,
  'brvbar': 0xA6,
  'sect': 0xA7,
  'uml': 0xA8,
  'copy': 0xA9,
  'ordf': 0xAA,
  'laquo': 0xAB,
  'not': 0xAC,
  'shy': 0xAD,
  'reg': 0xAE,
  'macr': 0xAF,
  'deg': 0xB0,
  'plusmn': 0xB1,
  'sup2': 0xB2,
  'sup3': 0xB3,
  'acute': 0xB4,
  'micro': 0xB5,
  'para': 0xB6,
  'middot': 0xB7,
  'cedil': 0xB8,
  'sup1': 0xB9,
  'ordm': 0xBA,
  'raquo': 0xBB,
  'frac14': 0xBC,
  'frac12': 0xBD,
  'frac34': 0xBE,
  'iquest': 0xBF,
  'Agrave': 0xC0,
  'Aacute': 0xC1,
  'Acirc': 0xC2,
  'Atilde': 0xC3,
  'Auml': 0xC4,
  'Aring': 0xC5,
  'AElig': 0xC6,
  'Ccedil': 0xC7,
  'Egrave': 0xC8,
  'Eacute': 0xC9,
  'Ecirc': 0xCA,
  'Euml': 0xCB,
  'Igrave': 0xCC,
  'Iacute': 0xCD,
  'Icirc': 0xCE,
  'Iuml': 0xCF,
  'ETH': 0xD0,
  'Ntilde': 0xD1,
  'Ograve': 0xD2,
  'Oacute': 0xD3,
  'Ocirc': 0xD4,
  'Otilde': 0xD5,
  'Ouml': 0xD6,
  'times': 0xD7,
  'Oslash': 0xD8,
  'Ugrave': 0xD9,
  'Uacute': 0xDA,
  'Ucirc': 0xDB,
  'Uuml': 0xDC,
  'Yacute': 0xDD,
  'THORN': 0xDE,
  'szlig': 0xDF,
  'agrave': 0xE0,
  'aacute': 0xE1,
  'acirc': 0xE2,
  'atilde': 0xE3,
  'auml': 0xE4,
  'aring': 0xE5,
  'aelig': 0xE6,
  'ccedil': 0xE7,
  'egrave': 0xE8,
  'eacute': 0xE9,
  'ecirc': 0xEA,
  'euml': 0xEB,
  'igrave': 0xEC,
  'iacute': 0xED,
  'icirc': 0xEE,
  'iuml': 0xEF,
  'eth': 0xF0,
  'ntilde': 0xF1,
  'ograve': 0xF2,
  'oacute': 0xF3,
  'ocirc': 0xF4,
  'otilde': 0xF5,
  'ouml': 0xF6,
  'divide': 0xF7,
  'oslash': 0xF8,
  'ugrave': 0xF9,
  'uacute': 0xFA,
  'ucirc': 0xFB,
  'uuml': 0xFC,
  'yacute': 0xFD,
  'thorn': 0xFE,
  'yuml': 0xFF,
  'lt': 0x3C,
  'gt': 0x3E,
  'amp': 0x26,
  'quot': 0x22,
  'apos': 0x27,
  'OElig': 0x152,
  'oelig': 0x153,
  'Scaron': 0x160,
  'scaron': 0x161,
  'Yuml': 0x178,
  'fnof': 0x192,
  'circ': 0x2C6,
  'tilde': 0x2DC,
  'ensp': 0x2002,
  'emsp': 0x2003,
  'thinsp': 0x2009,
  'zwnj': 0x200C,
  'zwj': 0x200D,
  'lrm': 0x200E,
  'rlm': 0x200F,
  'ndash': 0x2013,
  'mdash': 0x2014,
  'lsquo': 0x2018,
  'rsquo': 0x2019,
  'sbquo': 0x201A,
  'ldquo': 0x201C,
  'rdquo': 0x201D,
  'bdquo': 0x201E,
  'dagger': 0x2020,
  'Dagger': 0x2021,
  'bull': 0x2022,
  'hellip': 0x2026,
  'permil': 0x2030,
  'prime': 0x2032,
  'Prime': 0x2033,
  'lsaquo': 0x2039,
  'rsaquo': 0x203A,
  'oline': 0x203E,
  'euro': 0x20AC,
  'trade': 0x2122,
  'larr': 0x2190,
  'uarr': 0x2191,
  'rarr': 0x2192,
  'darr': 0x2193,
  'zwsp': 0x200B,
};

/// Zero-width / invisible code points marketing mail pads its preheader with;
/// dropped so they don't survive into the preview (issue #682). Covers the
/// zero-width space/joiners (U+200B–U+200D), the BOM (U+FEFF), the combining
/// grapheme joiner (U+034F, the `&#847;` seen in real mail), and the soft
/// hyphen (U+00AD).
final RegExp _zeroWidth = RegExp('[\u200B-\u200D\uFEFF\u034F\u00AD]');

/// Decodes numeric (`&#NNN;` / `&#xHH;`) and named ([_namedEntities])
/// references in one pass, so a decoded `&amp;` is never decoded again
/// (`&amp;lt;` stays "&lt;"), then strips zero-width padding. A malformed,
/// unknown or out-of-range reference is left as written.
String _decodeEntities(String s) => s.replaceAllMapped(_entity, (m) {
      final named = m[3];
      if (named != null) {
        final code = _namedEntities[named];
        return code == null ? m[0]! : String.fromCharCode(code);
      }
      final decimal = m[1];
      return _fromCodePoint(
        decimal != null
            ? int.tryParse(decimal)
            : int.tryParse(m[2]!, radix: 16),
        m[0]!,
      );
    }).replaceAll(_zeroWidth, '');

final RegExp _entity =
    RegExp(r'&(?:#(\d+)|#[xX]([0-9a-fA-F]+)|([a-zA-Z][a-zA-Z0-9]*));');

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
