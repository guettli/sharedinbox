import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/services/changelog_status_service.dart';
import 'package:sharedinbox/core/services/update_service.dart';
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

  static String _formatCommitDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.day} ${_months[local.month - 1]} ${local.year}';
  }

  static void _launch(String url) {
    unawaited(launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication));
  }

  static const _repoUrl = 'https://github.com/guettli/sharedinbox';

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
          final matches =
              stored == lineHash ||
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
    return Scaffold(
      appBar: AppBar(title: const Text('ChangeLog')),
      // The GitHub-backed status header sits above the changelog body. The body
      // renders immediately from the bundled asset (no Internet); only the
      // header waits on the network and shows a spinner until it resolves.
      body: Column(
        children: [
          const _StatusHeader(),
          const Divider(height: 1),
          Expanded(child: _buildBody(context, ref)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref) {
    final installedVersions = ref.watch(installedVersionsProvider);
    return FutureBuilder<String>(
      future: DefaultAssetBundle.of(context).loadString('assets/changelog.txt'),
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
            if (href != null) _launch(href);
          },
          styleSheet: MarkdownStyleSheet(
            p: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        );
      },
    );
  }
}

/// Header shown above the changelog: how far the running build is behind
/// `main`, and whether a newer packaged app version is available.
class _StatusHeader extends ConsumerWidget {
  const _StatusHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(repoStatusProvider);
    final update = ref.watch(updateInfoProvider).value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          status.when(
            loading: () => const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Checking GitHub…'),
              ],
            ),
            error: (_, __) =>
                const Text("Couldn't reach GitHub to check for updates"),
            data: (data) => _statusLine(context, data),
          ),
          if (update != null) ...[
            const SizedBox(height: 6),
            _AppLink(
              text: 'A new app version is available (${update.latestVersion})',
              onTap: () => ChangeLogScreen._launch(update.downloadUrl),
            ),
          ],
        ],
      ),
    );
  }

  static const _mainCommitsUrl =
      'https://github.com/guettli/sharedinbox/commits/main';

  Widget _statusLine(BuildContext context, RepoStatus? data) {
    if (data == null) {
      return const Text('Development build — version comparison unavailable');
    }
    switch (data.state) {
      case RepoStatusState.unknown:
        return const Text("Couldn't reach GitHub to check for updates");
      case RepoStatusState.upToDate:
        final date = data.latestCommitDate;
        return Text(
          date != null
              ? 'Up to date with main (latest commit: '
                    '${ChangeLogScreen._formatCommitDate(date)})'
              : 'Up to date with main',
        );
      case RepoStatusState.behind:
        final date = data.latestCommitDate;
        final plural = data.behindCount == 1 ? 'commit' : 'commits';
        final suffix = date != null
            ? ' (latest: ${ChangeLogScreen._formatCommitDate(date)})'
            : '';
        return _AppLink(
          text: '${data.behindCount} $plural behind main$suffix',
          onTap: () => ChangeLogScreen._launch(_mainCommitsUrl),
        );
    }
  }
}

/// A tappable, link-styled line of text.
class _AppLink extends StatelessWidget {
  const _AppLink({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}
