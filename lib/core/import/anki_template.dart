/// Renders an Anki card template (`qfmt` / `afmt`, #1383) with the fields of
/// a note: `{{Field}}`, `{{filter:Field}}` (`text:` strips the HTML, `type:`
/// shows nothing, other filters show the field), and the sections
/// `{{#Field}}…{{/Field}}` (shown when the field is not empty) and
/// `{{^Field}}…{{/Field}}` (shown when it is). An unknown field, including
/// `{{FrontSide}}`, renders empty. The result is HTML.
String renderAnkiTemplate(String template, Map<String, String> fields) {
  final out = StringBuffer();
  _render(_parse(template), fields, out);
  return out.toString();
}

/// The back of a card: [afmt] without the front (`{{FrontSide}}` and the
/// `<hr id=answer>` after it), as a card here shows both sides anyway.
String renderAnkiBack(String afmt, Map<String, String> fields) {
  final html = renderAnkiTemplate(afmt, fields);
  return html.replaceFirst(
    RegExp(
      r'''^[\s\S]*?<hr\s+id\s*=\s*["']?answer["']?\s*/?>''',
      caseSensitive: false,
    ),
    '',
  );
}

/// Whether Anki counts field [html] as empty: nothing but whitespace, line
/// breaks and empty tags (an image is content).
bool ankiFieldIsEmpty(String html) {
  if (RegExp('<img', caseSensitive: false).hasMatch(html)) return false;
  return html
      .replaceAll(RegExp('<[^>]*>'), '')
      .replaceAll(RegExp('&nbsp;', caseSensitive: false), '')
      .trim()
      .isEmpty;
}

sealed class _Node {}

class _Text extends _Node {
  _Text(this.text);
  final String text;
}

class _Field extends _Node {
  _Field(this.name, this.filters);
  final String name;
  final List<String> filters;
}

class _Section extends _Node {
  _Section(this.name, {required this.inverted, required this.children});
  final String name;
  final bool inverted;
  final List<_Node> children;
}

final _tag = RegExp(r'\{\{([\s\S]*?)\}\}');

List<_Node> _parse(String template) {
  // A stack of open sections; the bottom one is the template itself.
  final stack = <({String name, bool inverted, List<_Node> children})>[
    (name: '', inverted: false, children: []),
  ];
  var pos = 0;
  for (final m in _tag.allMatches(template)) {
    if (m.start > pos) {
      stack.last.children.add(_Text(template.substring(pos, m.start)));
    }
    pos = m.end;
    final tag = m.group(1)!.trim();
    if (tag.startsWith('#') || tag.startsWith('^')) {
      stack.add(
        (name: tag.substring(1).trim(), inverted: tag[0] == '^', children: []),
      );
      continue;
    }
    if (tag.startsWith('/')) {
      // A close without its open is ignored, like an unknown field.
      if (stack.length == 1) continue;
      final open = stack.removeLast();
      stack.last.children.add(
        _Section(open.name, inverted: open.inverted, children: open.children),
      );
      continue;
    }
    final parts = tag.split(':');
    stack.last.children.add(
      _Field(parts.last.trim(), parts.sublist(0, parts.length - 1)),
    );
  }
  if (pos < template.length) {
    stack.last.children.add(_Text(template.substring(pos)));
  }
  // Sections left open run to the end of the template.
  while (stack.length > 1) {
    final open = stack.removeLast();
    stack.last.children.add(
      _Section(open.name, inverted: open.inverted, children: open.children),
    );
  }
  return stack.single.children;
}

void _render(List<_Node> nodes, Map<String, String> fields, StringBuffer out) {
  for (final node in nodes) {
    switch (node) {
      case _Text(:final text):
        out.write(text);
      case _Field(:final name, :final filters):
        out.write(_filtered(fields[name] ?? '', filters));
      case _Section(:final name, :final inverted, :final children):
        final empty = ankiFieldIsEmpty(fields[name] ?? '');
        if (empty == inverted) _render(children, fields, out);
    }
  }
}

String _filtered(String value, List<String> filters) {
  var v = value;
  for (final f in filters.reversed) {
    switch (f.trim()) {
      case 'text':
        v = v.replaceAll(RegExp('<[^>]*>'), '');
      case 'type':
        return '';
    }
  }
  return v;
}
