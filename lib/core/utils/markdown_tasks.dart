/// Markdown task lists (`- [ ]` / `- [x]`) in an entry body (#1376).
///
/// Tasks are numbered in document order, the same order in which
/// `flutter_markdown_plus` renders their checkboxes; lines inside fenced code
/// blocks are skipped.
library;

// Marker (bullet or number, optionally inside block quotes), then `[`, the
// state character, `]` and a space or tab (as the GFM parser requires).
final _task =
    RegExp(r'^(\s*(?:>\s*)*(?:[-*+]|\d{1,9}[.)])[ \t]+\[)([ xX])\][ \t]');
final _fence = RegExp(r'^\s*(?:>\s*)*(`{3,}|~{3,})');

/// Offsets of the state character of every task in [md], in order.
List<int> _taskOffsets(String md) {
  final offsets = <int>[];
  String? fence;
  var start = 0;
  while (start <= md.length) {
    var end = md.indexOf('\n', start);
    if (end < 0) end = md.length;
    final line = md.substring(start, end);
    final f = _fence.firstMatch(line);
    if (f != null) {
      final marker = f.group(1)!;
      if (fence == null) {
        fence = marker;
      } else if (marker[0] == fence[0] && marker.length >= fence.length) {
        fence = null;
      }
    } else if (fence == null) {
      final m = _task.firstMatch(line);
      if (m != null) offsets.add(start + m.group(1)!.length);
    }
    start = end + 1;
  }
  return offsets;
}

/// Number of task-list items in [md].
int countTasks(String md) => _taskOffsets(md).length;

/// Ticks or unticks the task at [index]; only that one character changes.
/// An [index] out of range returns [md] unchanged.
String toggleTask(String md, int index) {
  final offsets = _taskOffsets(md);
  if (index < 0 || index >= offsets.length) return md;
  final at = offsets[index];
  final next = md[at] == ' ' ? 'x' : ' ';
  return md.replaceRange(at, at + 1, next);
}
