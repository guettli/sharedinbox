import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  final Future<PackageInfo> _packageInfoFuture = PackageInfo.fromPlatform();

  String _buildMarkdown(BuildContext context, PackageInfo? pkg) {
    final size = MediaQuery.of(context).size;
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final physW = (size.width * pixelRatio).toInt();
    final physH = (size.height * pixelRatio).toInt();
    final version =
        pkg != null ? '${pkg.version}+${pkg.buildNumber}' : 'unknown';

    return '## SharedInbox\n\n'
        '| Property | Value |\n'
        '|----------|-------|\n'
        '| Version | $version |\n'
        '| Platform | ${Platform.operatingSystem} |\n'
        '| OS Version | ${Platform.operatingSystemVersion} |\n'
        '| Resolution | ${physW}x$physH px'
        ' (logical: ${size.width.toInt()}x${size.height.toInt()} pt,'
        ' ratio: ${pixelRatio.toStringAsFixed(1)}x) |\n'
        '| Dart Version | ${Platform.version.split(' ').first} |\n'
        '| Processors | ${Platform.numberOfProcessors} |\n';
  }

  Future<void> _copyToClipboard(BuildContext context) async {
    PackageInfo? pkg;
    try {
      pkg = await _packageInfoFuture;
    } catch (_) {}
    if (!context.mounted) return;
    await Clipboard.setData(
      ClipboardData(text: _buildMarkdown(context, pkg)),
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

  Future<void> _createIssue(BuildContext context) async {
    PackageInfo? pkg;
    try {
      pkg = await _packageInfoFuture;
    } catch (_) {}
    if (!context.mounted) return;
    final body = Uri.encodeComponent(_buildMarkdown(context, pkg));
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy to clipboard',
            onPressed: () => unawaited(_copyToClipboard(context)),
          ),
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'Create issue on Codeberg',
            onPressed: () => unawaited(_createIssue(context)),
          ),
        ],
      ),
      body: FutureBuilder<PackageInfo>(
        future: _packageInfoFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          return Markdown(
            data: _buildMarkdown(context, snapshot.data),
            selectable: true,
          );
        },
      ),
    );
  }
}
