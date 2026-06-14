import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/utils/about_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  final Future<PackageInfo> _packageInfoFuture = PackageInfo.fromPlatform();
  late final Future<String?> _deviceModelFuture;
  late final Stream<List<Account>> _accountsStream;
  String? _deviceModel;

  @override
  void initState() {
    super.initState();
    _accountsStream = ref.read(accountRepositoryProvider).observeAccounts();
    _deviceModelFuture = getDeviceModel();
    unawaited(
      _deviceModelFuture.then((model) {
        if (mounted) setState(() => _deviceModel = model);
      }),
    );
  }

  Future<void> _copyToClipboard(
    BuildContext context,
    int imapCount,
    int jmapCount,
  ) async {
    PackageInfo? pkg;
    try {
      pkg = await _packageInfoFuture;
    } catch (_) {}
    String? deviceModel;
    try {
      deviceModel = await _deviceModelFuture;
    } catch (_) {}
    if (!context.mounted) return;
    await Clipboard.setData(
      ClipboardData(
        text: buildAboutMarkdown(
          context: context,
          pkg: pkg,
          imapCount: imapCount,
          jmapCount: jmapCount,
          deviceModel: deviceModel,
        ),
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

  Future<void> _launchUrl(BuildContext context, Uri url) async {
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
    String? deviceModel;
    try {
      deviceModel = await _deviceModelFuture;
    } catch (_) {}
    if (!context.mounted) return;
    final body = Uri.encodeComponent(
      buildAboutMarkdown(
        context: context,
        pkg: pkg,
        imapCount: imapCount,
        jmapCount: jmapCount,
        deviceModel: deviceModel,
      ),
    );
    final url = Uri.parse(
      'https://sialoop.thomas-guettler.de/guettli/sharedinbox/issues/new?body=$body',
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
                      data: buildAboutMarkdown(
                        context: context,
                        pkg: snapshot.data,
                        imapCount: imapCount,
                        jmapCount: jmapCount,
                        deviceModel: _deviceModel,
                      ),
                      selectable: true,
                      onTapLink: (text, href, title) {
                        if (href != null) {
                          unawaited(_launchUrl(context, Uri.parse(href)));
                        }
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy info'),
                        onPressed: () => unawaited(
                          _copyToClipboard(context, imapCount, jmapCount),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.bug_report_outlined),
                        label: const Text('Public issue'),
                        onPressed: () => unawaited(
                          _createIssue(context, imapCount, jmapCount),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.feedback_outlined),
                        label: const Text('Report bug'),
                        onPressed: () => context.push('/bug-report'),
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
