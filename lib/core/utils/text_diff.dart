// A minimal line-based text diff used to show *why* two cached message bodies
// differ without dumping the whole body. The output is a short "context diff":
// only the changed lines plus a few lines of surrounding context, with long
// runs of identical lines collapsed.

/// Kind of a single line in a [computeContextDiff] result.
enum DiffLineKind {
  /// Line present on both sides (surrounding context).
  context,

  /// Line present only on side A (removed, shown with `-`).
  removed,

  /// Line present only on side B (added, shown with `+`).
  added,

  /// A collapsed run of identical lines, rendered as a `…` separator.
  gap,
}

/// One rendered line of a context diff.
class DiffLine {
  const DiffLine(this.kind, this.text);

  final DiffLineKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is DiffLine && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'DiffLine(${kind.name}, "$text")';
}

/// Computes a short context diff between [a] and [b].
///
/// [context] is the number of unchanged lines kept around each change; runs of
/// identical lines longer than `2 * context` are collapsed to a single
/// [DiffLineKind.gap] marker. At most [maxLines] entries are returned; if the
/// diff is longer it is truncated and a final [DiffLineKind.gap] line notes how
/// many entries were dropped.
///
/// Returns an empty list when the two inputs are identical.
List<DiffLine> computeContextDiff(
  String a,
  String b, {
  int context = 2,
  int maxLines = 200,
}) {
  if (a == b) return const [];

  final linesA = _splitLines(a);
  final linesB = _splitLines(b);
  final ops = _diffLines(linesA, linesB);

  // Mark which ops to keep: every change, plus [context] equal lines on each
  // side of a change.
  final keep = List<bool>.filled(ops.length, false);
  for (int i = 0; i < ops.length; i++) {
    if (ops[i].kind != DiffLineKind.context) {
      final from = (i - context).clamp(0, ops.length - 1);
      final to = (i + context).clamp(0, ops.length - 1);
      for (int j = from; j <= to; j++) {
        keep[j] = true;
      }
    }
  }

  final out = <DiffLine>[];
  bool pendingGap = false;
  for (int i = 0; i < ops.length; i++) {
    if (!keep[i]) {
      pendingGap = true;
      continue;
    }
    if (pendingGap && out.isNotEmpty) {
      out.add(const DiffLine(DiffLineKind.gap, '…'));
    }
    pendingGap = false;
    out.add(ops[i]);
  }

  if (out.length > maxLines) {
    final dropped = out.length - maxLines;
    final trimmed = out.sublist(0, maxLines);
    trimmed.add(DiffLine(DiffLineKind.gap, '… $dropped more line(s)'));
    return trimmed;
  }
  return out;
}

List<String> _splitLines(String s) {
  // Normalise CRLF so a pure line-ending difference doesn't dominate the diff.
  final normalised = s.replaceAll('\r\n', '\n');
  return normalised.split('\n');
}

/// Classic Myers-style LCS diff over lines, emitted in source order.
List<DiffLine> _diffLines(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;

  // LCS length table.
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      if (a[i] == b[j]) {
        lcs[i][j] = lcs[i + 1][j + 1] + 1;
      } else {
        lcs[i][j] =
            lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1];
      }
    }
  }

  final ops = <DiffLine>[];
  int i = 0;
  int j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      ops.add(DiffLine(DiffLineKind.context, a[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      ops.add(DiffLine(DiffLineKind.removed, a[i]));
      i++;
    } else {
      ops.add(DiffLine(DiffLineKind.added, b[j]));
      j++;
    }
  }
  while (i < n) {
    ops.add(DiffLine(DiffLineKind.removed, a[i]));
    i++;
  }
  while (j < m) {
    ops.add(DiffLine(DiffLineKind.added, b[j]));
    j++;
  }
  return ops;
}
