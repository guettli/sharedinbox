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
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add address',
        onPressed: () => _showAddDialog(context, ref),
        child: const Icon(Icons.add),
      ),
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
                'Tap + to add an address or pattern (e.g. *@example.com), '
                'or tap "Load remote images" in an email to add the sender automatically.',
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

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: const Text('Add allowed address'),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email address or pattern',
                  hintText: '*@example.com',
                  helperText: '* matches any characters, e.g. *@example.com',
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (value) {
                  if (value.trim().isNotEmpty) {
                    _addSender(ref, value);
                    Navigator.of(ctx).pop();
                  }
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: controller.text.trim().isEmpty
                      ? null
                      : () {
                          _addSender(ref, controller.text);
                          Navigator.of(ctx).pop();
                        },
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _addSender(WidgetRef ref, String value) {
    unawaited(
      ref
          .read(userPreferencesRepositoryProvider)
          .addTrustedImageSender(value.trim()),
    );
  }
}
