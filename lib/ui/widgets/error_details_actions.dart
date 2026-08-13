import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:url_launcher/url_launcher.dart';

/// The shared "Error Details / optional Stack Trace / Copy / Report" block used
/// by both [CrashScreen] and [DatabaseUnreadableScreen]. Kept in one place so
/// the two error screens do not duplicate the clipboard and issue-report logic.
class ErrorDetailsActions extends StatelessWidget {
  const ErrorDetailsActions({
    super.key,
    required this.detail,
    required this.buildReport,
    required this.issueTitle,
    this.stackTrace,
  });

  /// Monospace error text shown in the first box.
  final String detail;

  /// Optional stack trace shown in a second box below the error.
  final String? stackTrace;

  /// Builds the full text copied to the clipboard. Async so callers can fetch
  /// version/platform metadata at tap time.
  final Future<String> Function() buildReport;

  /// Title for the prefilled GitHub issue. The URL carries only the title, not
  /// the body — long reports exceeded browser URL limits (#146).
  final String issueTitle;

  @override
  Widget build(BuildContext context) {
    final stack = stackTrace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Error Details:',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: AppSpacing.sm),
        _monoBox(detail, 12),
        if (stack != null) ...[
          const SizedBox(height: AppSpacing.lg),
          const Text(
            'Stack Trace:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: AppSpacing.sm),
          _monoBox(stack, 10),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton.icon(
          onPressed: () async {
            final data = await buildReport();
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
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton.icon(
          onPressed: () async {
            await _reportIssue(context);
          },
          icon: const Icon(Icons.bug_report),
          label: const Text('Report Issue on GitHub'),
        ),
      ],
    );
  }

  Future<void> _reportIssue(BuildContext context) async {
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

  Widget _monoBox(String text, double fontSize) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(fontFamily: 'monospace', fontSize: fontSize),
      ),
    );
  }
}
