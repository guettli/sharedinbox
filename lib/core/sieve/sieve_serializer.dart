import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/sieve/sieve_actions.dart';

/// Serialises a [FilterGroup] + list of [SieveAction]s to a Sieve script
/// (RFC 5228 subset).
class SieveSerializer {
  String serialize(FilterGroup filter, List<SieveAction> actions) {
    final buf = StringBuffer();
    final requires = _collectRequires(actions);
    if (requires.isNotEmpty) {
      buf.writeln(
        'require [${requires.map((r) => '"$r"').join(', ')}];',
      );
    }
    if (filter.isEmpty) {
      for (final a in actions) {
        buf.writeln(_serializeAction(a));
      }
      return buf.toString();
    }
    buf.write('if ');
    buf.write(_serializeNode(filter));
    buf.writeln(' {');
    for (final a in actions) {
      buf.writeln('    ${_serializeAction(a)}');
    }
    buf.writeln('}');
    return buf.toString();
  }

  List<String> _collectRequires(List<SieveAction> actions) {
    final req = <String>[];
    for (final a in actions) {
      if (a is FileIntoAction && !req.contains('fileinto')) req.add('fileinto');
      final usesFlags =
          a is FlagAction || a is MarkAsSeenAction || a is StarMessageAction;
      if (usesFlags && !req.contains('imap4flags')) {
        req.add('imap4flags');
      }
    }
    return req;
  }

  String _serializeNode(FilterNode node) => switch (node) {
        final FilterLeaf leaf => _serializeLeaf(leaf),
        final FilterGroup group => _serializeGroup(group),
      };

  String _serializeGroup(FilterGroup group) {
    if (group.isEmpty) return 'true';
    if (group.children.length == 1) return _serializeNode(group.children.first);
    final op = group.operator == FilterOperator.and_ ? 'allof' : 'anyof';
    final parts = group.children.map(_serializeNode).join(',\n    ');
    return '$op(\n    $parts\n)';
  }

  String _serializeLeaf(FilterLeaf leaf) => switch (leaf.field) {
        FilterField.from_ ||
        FilterField.to ||
        FilterField.cc =>
          _serializeAddressLeaf(leaf),
        FilterField.subject => _serializeHeaderLeaf(leaf, 'subject'),
        FilterField.header => _serializeHeaderLeaf(leaf, leaf.headerName ?? ''),
        FilterField.size => _serializeSizeLeaf(leaf),
        // Folder is a search-only field; Sieve runs at delivery time before
        // the message is filed. The UI hides this field in the Sieve editor.
        FilterField.folder =>
          throw StateError('folder filter is not supported in Sieve'),
      };

  String _serializeAddressLeaf(FilterLeaf leaf) {
    final header = switch (leaf.field) {
      FilterField.from_ => 'from',
      FilterField.to => 'to',
      FilterField.cc => 'cc',
      _ => throw StateError('not an address field'),
    };
    return 'address ${_matchType(leaf.comparison)} "$header" "${_esc(leaf.value.trim())}"';
  }

  String _serializeHeaderLeaf(FilterLeaf leaf, String headerName) =>
      'header ${_matchType(leaf.comparison)}'
      ' "${_esc(headerName.trim())}" "${_esc(leaf.value.trim())}"';

  String _serializeSizeLeaf(FilterLeaf leaf) {
    final comp = leaf.comparison == FilterComparison.over ? ':over' : ':under';
    return 'size $comp ${leaf.value}';
  }

  String _matchType(FilterComparison comp) => switch (comp) {
        FilterComparison.contains => ':contains',
        FilterComparison.is_ => ':is',
        FilterComparison.matches => ':matches',
        _ => ':contains',
      };

  String _serializeAction(SieveAction action) => switch (action) {
        final FileIntoAction a => 'fileinto "${_esc(a.folder.trim())}";',
        KeepAction() => 'keep;',
        DiscardAction() => 'discard;',
        MarkAsSeenAction() => r'setflag "\\Seen";',
        StarMessageAction() => r'setflag "\\Flagged";',
        final FlagAction a =>
          'addflag [${a.flags.map((f) => '"${_esc(f)}"').join(', ')}];',
      };

  String _esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}
