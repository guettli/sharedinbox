import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'di.dart';
import 'ui/router.dart';

void main({List<Override> overrides = const []}) {
  runApp(ProviderScope(overrides: overrides, child: const SharedInboxApp()));
}

class SharedInboxApp extends ConsumerStatefulWidget {
  const SharedInboxApp({super.key});

  @override
  ConsumerState<SharedInboxApp> createState() => _SharedInboxAppState();
}

class _SharedInboxAppState extends ConsumerState<SharedInboxApp> {
  @override
  void initState() {
    super.initState();
    // Start background IMAP sync once — runs for the lifetime of the app.
    ref.read(syncManagerProvider).start();
  }

  @override
  Widget build(BuildContext context) {
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
