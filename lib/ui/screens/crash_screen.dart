import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class CrashScreen extends StatelessWidget {
  const CrashScreen({
    super.key,
    required this.exception,
    required this.stackTrace,
  });

  final Object exception;
  final StackTrace? stackTrace;

  Future<String> _buildReport() async {
    String version = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    final platform =
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    return 'App Version: $version\n'
        'Platform: $platform\n\n'
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
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 64),
              const SizedBox(height: 16),
              Text(
                'sharedinbox.de encountered an unexpected error and needs to be restarted.',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
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
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
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
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
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
                  final report = await _buildReport();
                  final title = Uri.encodeComponent(
                    'Crash: ${exception.toString().split('\n').first}',
                  );
                  final body = Uri.encodeComponent(report);
                  final url = Uri.parse(
                    'https://codeberg.org/guettli/sharedinbox/issues/new?title=$title&body=$body',
                  );
                  try {
                    final launched = await launchUrl(
                      url,
                      mode: LaunchMode.externalApplication,
                    );
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
                },
                icon: const Icon(Icons.bug_report),
                label: const Text('Report Issue on Codeberg'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
