import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CrashScreen extends StatelessWidget {
  const CrashScreen({
    super.key,
    required this.exception,
    required this.stackTrace,
  });

  final Object exception;
  final StackTrace? stackTrace;

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
              const Icon(
                Icons.error_outline,
                color: Colors.red,
                size: 64,
              ),
              const SizedBox(height: 16),
              Text(
                'SharedInbox encountered an unexpected error and needs to be restarted.',
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
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 10),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () async {
                  final data = 'Error: $exception\n\nStack Trace:\n$stackTrace';
                  await Clipboard.setData(ClipboardData(text: data));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy to Clipboard'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
