import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

class ChangeLogScreen extends StatelessWidget {
  const ChangeLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ChangeLog'),
      ),
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
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              content,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          );
        },
      ),
    );
  }
}
