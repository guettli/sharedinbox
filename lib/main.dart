import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'di.dart';
import 'ui/router.dart';

void main() {
  runApp(const ProviderScope(child: SharedInboxApp()));
}

class SharedInboxApp extends ConsumerWidget {
  const SharedInboxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Start background sync
    ref.watch(syncManagerProvider).start();

    return MaterialApp.router(
      title: 'SharedInbox',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}
