import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/di.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  final Future<PackageInfo> _packageInfoFuture = PackageInfo.fromPlatform();
  late final Stream<List<Account>> _accountsStream;

  static const _gitHash = String.fromEnvironment('GIT_HASH');

  @override
  void initState() {
    super.initState();
    _accountsStream = ref.read(accountRepositoryProvider).observeAccounts();
  }

  String _buildMarkdown(
    BuildContext context,
    PackageInfo? pkg,
    int imapCount,
    int jmapCount,
  ) {
    final size = MediaQuery.of(context).size;
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final physW = (size.width * pixelRatio).toInt();
    final physH = (size.height * pixelRatio).toInt();
    final version =
        pkg != null ? '${pkg.version}+${pkg.buildNumber}' : 'unknown';
    final versionDisplay = _gitHash.isNotEmpty
        ? '[$version](https://codeberg.org/guettli/sharedinbox/commit/$_gitHash)'
        : version;
    final osName = _capitalize(Platform.operatingSystem);
    final isDark = MediaQuery.of(context).platformBrightness == Brightness.dark;

    return '## sharedinbox.de\n\n'
        '| Property | Value |\n'
        '|----------|-------|\n'
        '| App Version | $versionDisplay |\n'
        '| Platform | ${Platform.operatingSystem} |\n'
        '| $osName Version | ${Platform.operatingSystemVersion} |\n'
        '| Resolution | ${physW}x$physH px'
        ' (logical: ${size.width.toInt()}x${size.height.toInt()} pt,'
        ' ratio: ${pixelRatio.toStringAsFixed(1)}x) |\n'
        '| Dart Version | ${Platform.version.split(' ').first} |\n'
        '| Processors | ${Platform.numberOfProcessors} |\n'
        '| Dark Mode | ${isDark ? 'yes' : 'no'} |\n'
        '| IMAP Accounts | $imapCount |\n'
        '| JMAP Accounts | $jmapCount |\n';
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  Future<void> _copyToClipboard(
    BuildContext context,
    int imapCount,
    int jmapCount,
  ) async {
    PackageInfo? pkg;
    try {
      pkg = await _packageInfoFuture;
    } catch (_) {}
    if (!context.mounted) return;
    await Clipboard.setData(
      ClipboardData(
        text: _buildMarkdown(context, pkg, imapCount, jmapCount),
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 5),
          content: Text('Copied to clipboard'),
        ),
      );
    }
  }

  Future<void> _createIssue(
    BuildContext context,
    int imapCount,
    int jmapCount,
  ) async {
    PackageInfo? pkg;
    try {
      pkg = await _packageInfoFuture;
    } catch (_) {}
    if (!context.mounted) return;
    final body = Uri.encodeComponent(
      _buildMarkdown(context, pkg, imapCount, jmapCount),
    );
    final url = Uri.parse(
      'https://codeberg.org/guettli/sharedinbox/issues/new?body=$body',
    );
    try {
      final launched =
          await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 5),
            content: Text('Could not open browser.'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            content: Text('Error: $e'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Account>>(
      stream: _accountsStream,
      builder: (context, accountSnapshot) {
        final accounts = accountSnapshot.data ?? [];
        final imapCount =
            accounts.where((a) => a.type == AccountType.imap).length;
        final jmapCount =
            accounts.where((a) => a.type == AccountType.jmap).length;

        return Scaffold(
          appBar: AppBar(title: const Text('About')),
          body: Column(
            children: [
              Expanded(
                child: FutureBuilder<PackageInfo>(
                  future: _packageInfoFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return Markdown(
                      data: _buildMarkdown(
                        context,
                        snapshot.data,
                        imapCount,
                        jmapCount,
                      ),
                      selectable: true,
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
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy to clipboard'),
                        onPressed: () => unawaited(
                          _copyToClipboard(context, imapCount, jmapCount),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.bug_report),
                        label: const Text('Create issue'),
                        onPressed: () => unawaited(
                          _createIssue(context, imapCount, jmapCount),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
