import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class CrashScreen extends StatelessWidget {
  const CrashScreen({
    super.key,
    required this.exception,
    required this.stackTrace,
    this.gitHash = const String.fromEnvironment('GIT_HASH'),
  });

  final Object exception;
  final StackTrace? stackTrace;
  final String gitHash;

  String get _buildMode {
    if (kDebugMode) return 'debug';
    if (kProfileMode) return 'profile';
    return 'release';
  }

  Future<String> _fetchVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<String> _buildReport() async {
    final version = await _fetchVersion();
    final platform =
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    final gitLine = gitHash.isNotEmpty
        ? 'Git Commit: [$gitHash](https://codeberg.org/guettli/sharedinbox/commit/$gitHash)\n'
        : '';
    final timestamp = DateTime.now().toUtc().toIso8601String();
    return 'App Version: $version\n'
        'Build Mode: $_buildMode\n'
        '$gitLine'
        'Platform: $platform\n'
        'Dart: ${Platform.version}\n'
        'Timestamp: $timestamp\n\n'
        'Error:\n```\n$exception\n```\n\n'
        'Stack Trace:\n```\n$stackTrace\n```';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Something went wrong'),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
        body: Builder(
          builder: (ctx) => SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 64),
                const SizedBox(height: 16),
                Text(
                  'sharedinbox.de encountered an unexpected error and needs to be restarted.',
                  style: Theme.of(ctx).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                FutureBuilder<String>(
                  future: _fetchVersion(),
                  builder: (context, snapshot) => Text(
                    'v${snapshot.data ?? '…'}  •  $_buildMode  •  '
                    '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                    textAlign: TextAlign.center,
                  ),
                ),
                if (gitHash.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () async {
                      final url = Uri.parse(
                        'https://codeberg.org/guettli/sharedinbox/commit/$gitHash',
                      );
                      await launchUrl(
                        url,
                        mode: LaunchMode.externalApplication,
                      );
                    },
                    child: Text(
                      'Git Commit: $gitHash',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.blue,
                        decoration: TextDecoration.underline,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                const Text(
                  'Error Details:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    exception.toString(),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                if (stackTrace != null) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Stack Trace:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      stackTrace.toString(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () async {
                    final data = await _buildReport();
                    await Clipboard.setData(ClipboardData(text: data));
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          duration: Duration(seconds: 5),
                          content: Text('Copied to clipboard'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy to Clipboard'),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () async {
                    // URL carries only the title to avoid exceeding browser
                    // URL-length limits — long stack traces caused "create
                    // issue failed" (#146).  Use "Copy to Clipboard" first to
                    // get the full report, then paste it in the issue body.
                    final title = Uri.encodeComponent(
                      'Crash: ${exception.toString().split('\n').first}',
                    );
                    final url = Uri.parse(
                      'https://codeberg.org/guettli/sharedinbox/issues/new?title=$title',
                    );
                    try {
                      final launched = await launchUrl(
                        url,
                        mode: LaunchMode.externalApplication,
                      );
                      if (!launched && ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            duration: Duration(seconds: 5),
                            content: Text('Could not open browser.'),
                          ),
                        );
                      }
                    } catch (e) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(
                            duration: const Duration(seconds: 5),
                            content: Text('Error: $e'),
                          ),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.bug_report),
                  label: const Text('Report Issue on Codeberg'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
