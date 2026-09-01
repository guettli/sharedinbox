import 'package:sharedinbox/core/filter/filter_expression.dart';

/// A single mail address as seen by the matcher.
class MatchAddress {
  const MatchAddress({this.name = '', this.email = ''});

  final String name;
  final String email;
}

/// The subset of a message's metadata a [FilterGroup] can match against at
/// notification time. Built from envelope + headers only — no body fetch — so
/// matching stays cheap and works offline.
class MatchableMessage {
  const MatchableMessage({
    this.from = const [],
    this.to = const [],
    this.cc = const [],
    this.subject = '',
    this.size = 0,
    this.folder = '',
    this.headers = const {},
  });

  final List<MatchAddress> from;
  final List<MatchAddress> to;
  final List<MatchAddress> cc;
  final String subject;
  final int size;
  final String folder;

  /// Raw headers keyed by lower-cased header name. May be empty when only the
  /// envelope is available — a [FilterField.header] leaf then does not match.
  final Map<String, String> headers;
}

/// Evaluates [node] against [message].
///
/// Group semantics: an AND group matches when every child matches; an OR group
/// matches when any child matches. An **empty** group matches nothing — a rule
/// with no conditions should never fire a notification.
bool matchesFilter(FilterNode node, MatchableMessage message) {
  switch (node) {
    case FilterGroup():
      if (node.children.isEmpty) return false;
      return switch (node.operator) {
        FilterOperator.and_ =>
          node.children.every((c) => matchesFilter(c, message)),
        FilterOperator.or_ =>
          node.children.any((c) => matchesFilter(c, message)),
      };
    case FilterLeaf():
      return _matchesLeaf(node, message);
  }
}

bool _matchesLeaf(FilterLeaf leaf, MatchableMessage message) {
  switch (leaf.field) {
    case FilterField.from_:
      return _matchesAddresses(leaf, message.from);
    case FilterField.to:
      return _matchesAddresses(leaf, message.to);
    case FilterField.cc:
      return _matchesAddresses(leaf, message.cc);
    case FilterField.subject:
      return _matchesText(leaf, message.subject);
    case FilterField.header:
      final name = leaf.headerName?.toLowerCase();
      if (name == null) return false;
      final value = message.headers[name];
      if (value == null) return false;
      return _matchesText(leaf, value);
    case FilterField.folder:
      return _matchesText(leaf, message.folder);
    case FilterField.size:
      final size = int.tryParse(leaf.value.trim());
      if (size == null) return false;
      return switch (leaf.comparison) {
        FilterComparison.over => message.size > size,
        FilterComparison.under => message.size < size,
        _ => false,
      };
  }
}

bool _matchesAddresses(FilterLeaf leaf, List<MatchAddress> addresses) {
  final needle = leaf.value.trim().toLowerCase();
  if (needle.isEmpty) return false;
  for (final a in addresses) {
    final email = a.email.toLowerCase();
    final name = a.name.toLowerCase();
    switch (leaf.comparison) {
      case FilterComparison.is_:
        if (email == needle) return true;
      case FilterComparison.contains:
        if (email.contains(needle) || name.contains(needle)) return true;
      case FilterComparison.matches:
        final re = _tryRegExp(leaf.value);
        if (re != null && (re.hasMatch(a.email) || re.hasMatch(a.name))) {
          return true;
        }
      case FilterComparison.over:
      case FilterComparison.under:
        return false;
    }
  }
  return false;
}

bool _matchesText(FilterLeaf leaf, String haystack) {
  switch (leaf.comparison) {
    case FilterComparison.contains:
      return haystack.toLowerCase().contains(leaf.value.trim().toLowerCase());
    case FilterComparison.is_:
      return haystack.trim().toLowerCase() == leaf.value.trim().toLowerCase();
    case FilterComparison.matches:
      final re = _tryRegExp(leaf.value);
      return re != null && re.hasMatch(haystack);
    case FilterComparison.over:
    case FilterComparison.under:
      return false;
  }
}

RegExp? _tryRegExp(String pattern) {
  try {
    return RegExp(pattern, caseSensitive: false);
  } catch (_) {
    return null;
  }
}
