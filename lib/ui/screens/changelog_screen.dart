import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

class ChangeLogScreen extends StatelessWidget {
  const ChangeLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ChangeLog')),
      body: FutureBuilder<String>(
        future: rootBundle.loadString('assets/changelog.txt'),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Error loading changelog: ${snapshot.error}'),
            );
          }
          final content = snapshot.data ?? 'No changelog entries found.';
          return Markdown(
            data: content,
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
            styleSheet: MarkdownStyleSheet(
              p: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          );
        },
      ),
    );
  }
}
