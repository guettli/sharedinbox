import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:url_launcher/url_launcher.dart';

/// Full-screen error page shared by the crash and database-unreadable screens:
/// an error-coloured app bar over a scrolling column that leads with a hero
/// icon. Both screens run as the root widget (via `runApp`), so this owns the
/// `MaterialApp`. The body is built through a callback so its widgets get a
/// context *below* the [Scaffold] and can reach [ScaffoldMessenger].
class ErrorReportScaffold extends StatelessWidget {
  const ErrorReportScaffold({
    super.key,
    required this.appBarTitle,
    required this.heroIcon,
    required this.bodyBuilder,
  });

  final String appBarTitle;
  final IconData heroIcon;
  final List<Widget> Function(BuildContext ctx) bodyBuilder;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        appBar: AppBar(
          title: Text(appBarTitle),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
        body: Builder(
          builder: (ctx) => SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(heroIcon, color: Colors.red, size: AppIconSize.hero),
                const SizedBox(height: AppSpacing.lg),
                ...bodyBuilder(ctx),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A bold label above a grey, monospaced detail box — used for error and
/// stack-trace dumps on the error screens.
class LabeledMonospaceBox extends StatelessWidget {
  const LabeledMonospaceBox({
    super.key,
    required this.label,
    required this.text,
    this.fontSize = 12,
  });

  final String label;
  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            style: TextStyle(fontFamily: 'monospace', fontSize: fontSize),
          ),
        ),
      ],
    );
  }
}

/// Copies text (produced lazily by [buildText]) to the clipboard and confirms
/// with a snackbar.
class CopyToClipboardButton extends StatelessWidget {
  const CopyToClipboardButton({super.key, required this.buildText});

  final Future<String> Function() buildText;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () async {
        final data = await buildText();
        await Clipboard.setData(ClipboardData(text: data));
        if (context.mounted) {
          context.showAppSnackBar(
            'Copied to clipboard',
            duration: const Duration(seconds: 5),
          );
        }
      },
      icon: const Icon(Icons.copy),
      label: const Text('Copy to Clipboard'),
    );
  }
}

/// Opens a pre-filled "new issue" page on GitHub. Only the [issueTitle] is
/// carried in the URL to avoid exceeding browser URL-length limits — long
/// stack traces caused "create issue failed" (#146); paste the clipboard
/// report into the issue body instead.
class ReportIssueButton extends StatelessWidget {
  const ReportIssueButton({super.key, required this.issueTitle});

  final String issueTitle;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () async {
        final url = Uri.parse(
          'https://github.com/guettli/sharedinbox/issues/new'
          '?title=${Uri.encodeComponent(issueTitle)}',
        );
        try {
          final launched = await launchUrl(
            url,
            mode: LaunchMode.externalApplication,
          );
          if (!launched && context.mounted) {
            context.showAppSnackBar(
              'Could not open browser.',
              level: AppLogLevel.warn,
              duration: const Duration(seconds: 5),
            );
          }
        } catch (e) {
          if (context.mounted) {
            context.showAppSnackBar(
              'Error: $e',
              level: AppLogLevel.error,
              error: e,
              duration: const Duration(seconds: 5),
            );
          }
        }
      },
      icon: const Icon(Icons.bug_report),
      label: const Text('Report Issue on GitHub'),
    );
  }
}
