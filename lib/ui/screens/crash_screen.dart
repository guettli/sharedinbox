import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/error_report_scaffold.dart';
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
    final versionDisplay = gitHash.isNotEmpty
        ? '[$version](https://github.com/guettli/sharedinbox/commit/$gitHash)'
        : version;
    final gitLine = gitHash.isNotEmpty
        ? 'Git Commit: [$gitHash](https://github.com/guettli/sharedinbox/commit/$gitHash)\n'
        : '';
    final timestamp = DateTime.now().toUtc().toIso8601String();
    return 'App Version: $versionDisplay\n'
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
    return ErrorReportScaffold(
      appBarTitle: 'Something went wrong',
      heroIcon: Icons.error_outline,
      bodyBuilder: (ctx) => [
        Text(
          'sharedinbox.de encountered an unexpected error and needs to be restarted.',
          style: Theme.of(ctx).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xs),
        FutureBuilder<String>(
          future: _fetchVersion(),
          builder: (context, snapshot) => Text(
            'v${snapshot.data ?? '…'}  •  $_buildMode  •  '
            '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
        ),
        if (gitHash.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (_, snapshot) {
              if (!snapshot.hasData) return const SizedBox.shrink();
              final version =
                  '${snapshot.data!.version}+${snapshot.data!.buildNumber}';
              return _commitLink(label: 'App Version: $version');
            },
          ),
          const SizedBox(height: AppSpacing.xs),
          _commitLink(label: 'Git Commit: $gitHash'),
        ],
        const SizedBox(height: AppSpacing.xl),
        LabeledMonospaceBox(
          label: 'Error Details:',
          text: exception.toString(),
        ),
        if (stackTrace != null) ...[
          const SizedBox(height: AppSpacing.lg),
          LabeledMonospaceBox(
            label: 'Stack Trace:',
            text: stackTrace.toString(),
            fontSize: 10,
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        CopyToClipboardButton(buildText: _buildReport),
        const SizedBox(height: AppSpacing.lg),
        ReportIssueButton(
          issueTitle: 'Crash: ${exception.toString().split('\n').first}',
        ),
      ],
    );
  }

  /// A tappable, underlined link to this build's commit on GitHub.
  Widget _commitLink({required String label}) {
    return GestureDetector(
      onTap: () async {
        final url = Uri.parse(
          'https://github.com/guettli/sharedinbox/commit/$gitHash',
        );
        await launchUrl(url, mode: LaunchMode.externalApplication);
      },
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          color: Colors.blue,
          decoration: TextDecoration.underline,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
