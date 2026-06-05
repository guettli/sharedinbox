import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/di.dart';

class TrustedImageSendersScreen extends ConsumerWidget {
  const TrustedImageSendersScreen({super.key, this.highlightedSender});

  final String? highlightedSender;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trustedSendersAsync = ref.watch(trustedImageSendersProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Allowed addresses for images')),
      body: trustedSendersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) =>
            const Center(child: Text('Error loading trusted senders')),
        data: (senders) {
          if (senders.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No addresses added yet. '
                'Tap "Load remote images" in an email to add the sender.',
              ),
            );
          }
          return ListView.builder(
            itemCount: senders.length,
            itemBuilder: (context, index) {
              final sender = senders[index];
              final isHighlighted = sender == highlightedSender;
              return ListTile(
                title: Text(
                  sender,
                  style: isHighlighted
                      ? const TextStyle(fontWeight: FontWeight.bold)
                      : null,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove',
                  onPressed: () {
                    unawaited(
                      ref
                          .read(userPreferencesRepositoryProvider)
                          .removeTrustedImageSender(sender),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
