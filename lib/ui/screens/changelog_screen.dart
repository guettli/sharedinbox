import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/di.dart';
import 'package:url_launcher/url_launcher.dart';

class ChangeLogScreen extends ConsumerWidget {
  const ChangeLogScreen({super.key});

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _formatInstallDate(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final month = _months[dt.month - 1];
    return '$h:$m, ${dt.day} $month ${dt.year}';
  }

  static const _repoUrl = 'https://codeberg.org/guettli/sharedinbox';

  static final _issueRefPattern = RegExp(r'#(\d+)');

  static String _linkifyIssueRefs(String text) {
    return text.replaceAllMapped(
      _issueRefPattern,
      (m) => '[#${m[1]}]($_repoUrl/issues/${m[1]})',
    );
  }

  // Changelog lines have the form:
  //   * 2026-06-05 [abc1234](https://...): subject
  // This pattern captures the short hash inside the markdown link.
  static final _hashPattern = RegExp(r'\[([0-9a-f]{6,12})\]\(');

  static String _injectInstallMarkers(
    String changelog,
    Map<String, DateTime> versions,
  ) {
    if (versions.isEmpty) return changelog;
    final lines = changelog.split('\n');
    final buf = StringBuffer();
    for (final line in lines) {
      final match = _hashPattern.firstMatch(line);
      if (match != null) {
        final lineHash = match.group(1)!;
        for (final entry in versions.entries) {
          final stored = entry.key;
          final matches = stored == lineHash ||
              stored.startsWith(lineHash) ||
              lineHash.startsWith(stored);
          if (!matches) continue;
          buf.write(
            '\n---\n\n**Installed: ${_formatInstallDate(entry.value)}**\n\n',
          );
          break;
        }
      }
      buf.writeln(line);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installedVersions = ref.watch(installedVersionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('ChangeLog')),
      body: FutureBuilder<String>(
        future:
            DefaultAssetBundle.of(context).loadString('assets/changelog.txt'),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting ||
              installedVersions.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Error loading changelog: ${snapshot.error}'),
            );
          }
          final raw = snapshot.data ?? 'No changelog entries found.';
          final content = _linkifyIssueRefs(raw);
          final versions = installedVersions.value ?? {};
          final annotated = _injectInstallMarkers(content, versions);
          return Markdown(
            data: annotated,
            onTapLink: (text, href, title) {
              if (href != null) {
                unawaited(
                  launchUrl(
                    Uri.parse(href),
                    mode: LaunchMode.externalApplication,
                  ),
                );
              }
            },
            styleSheet: MarkdownStyleSheet(
              p: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          );
        },
      ),
    );
  }
}
