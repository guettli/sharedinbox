/// The Markdown of an Anki field or rendered template (#1383) and what was
/// left out of it.
class AnkiMarkdown {
  const AnkiMarkdown(
    this.text, {
    this.missingImages = const [],
    this.droppedSounds = 0,
  });

  final String text;

  /// The `src` of the images [ankiHtmlToMarkdown] could not resolve.
  final List<String> missingImages;

  /// The `[sound:…]` references dropped.
  final int droppedSounds;
}

/// The blob itemId of the image [fileName] of the `.apkg`, or null when the
/// file is not in it.
typedef ResolveImage = String? Function(String fileName);

/// Converts Anki [html] into the Markdown of a card: `<br>`, `<div>` and
/// `<p>` become line breaks, `<b>`/`<strong>` `**`, `<i>`/`<em>` `*`,
/// `<img src>` `![](si-img:<id>)` through [resolveImage] (an image that is
/// not in the file becomes the text `[image missing: name]`), `[sound:…]` is
/// dropped, entities are decoded and every other tag is stripped
/// (`<script>` and `<style>` with their content).
AnkiMarkdown ankiHtmlToMarkdown(String html, ResolveImage resolveImage) {
  final missing = <String>[];
  var sounds = 0;
  var s = html
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(
        RegExp(r'<(script|style)\b[\s\S]*?</\1\s*>', caseSensitive: false),
        '',
      )
      .replaceAllMapped(RegExp(r'\[sound:[^\]]*\]'), (_) {
    sounds++;
    return '';
  });
  // Source line breaks are not breaks in HTML.
  s = s.replaceAll(RegExp(r'[\r\n]+'), ' ');
  s = s.replaceAllMapped(RegExp(r'<\s*(/?)\s*([a-zA-Z0-9]+)([^>]*)>'), (m) {
    final closing = m.group(1)!.isNotEmpty;
    final attrs = m.group(3)!;
    switch (m.group(2)!.toLowerCase()) {
      case 'br':
        return '\n';
      case 'p':
        return '\n\n';
      case 'div' || 'li' || 'tr' || 'hr' || 'h1' || 'h2' || 'h3' || 'h4':
        return _block;
      case 'b' || 'strong':
        return '**';
      case 'i' || 'em':
        return '*';
      case 'img':
        if (closing) return '';
        final src = imageSource(attrs);
        if (src == null) return '';
        final id = resolveImage(src);
        if (id == null) {
          missing.add(src);
          return '[image missing: $src]';
        }
        return '![](si-img:$id)';
      default:
        return '';
    }
  });
  // The end of one block and the start of the next are one line break.
  s = s.replaceAll(RegExp('$_block+'), '\n');
  s = decodeHtmlEntities(s)
      .replaceAll(' ', ' ')
      .split('\n')
      .map((l) => l.trimRight())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return AnkiMarkdown(s, missingImages: missing, droppedSounds: sounds);
}

/// Marks a block boundary (`<div>`, `</div>`, …) until they are merged.
const _block = '\u0001';

/// The `src` of the attributes [attrs] of an `<img>`, entities decoded.
String? imageSource(String attrs) {
  final m = RegExp(
    r'''\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  ).firstMatch(attrs);
  if (m == null) return null;
  final src = decodeHtmlEntities(m.group(1) ?? m.group(2) ?? m.group(3)!);
  return src.isEmpty ? null : src;
}

const _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'shy': '',
  'ndash': '–',
  'mdash': '—',
  'hellip': '…',
  'laquo': '«',
  'raquo': '»',
  'auml': 'ä',
  'ouml': 'ö',
  'uuml': 'ü',
  'Auml': 'Ä',
  'Ouml': 'Ö',
  'Uuml': 'Ü',
  'szlig': 'ß',
  'eacute': 'é',
  'egrave': 'è',
  'agrave': 'à',
  'ccedil': 'ç',
  'copy': '©',
  'euro': '€',
};

/// [s] with HTML entities (named ones of [_namedEntities], `&#NN;` and
/// `&#xHH;`) decoded; unknown ones stay.
String decodeHtmlEntities(String s) => s.replaceAllMapped(
      RegExp('&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'),
      (m) {
        final e = m.group(1)!;
        if (!e.startsWith('#')) return _namedEntities[e] ?? m.group(0)!;
        final hex = e.length > 1 && (e[1] == 'x' || e[1] == 'X');
        final code = int.tryParse(e.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
        if (code == null || code > 0x10FFFF) return m.group(0)!;
        return String.fromCharCode(code);
      },
    );
