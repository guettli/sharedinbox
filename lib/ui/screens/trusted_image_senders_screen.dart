import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/utils/sender_address.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

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
              padding: EdgeInsets.all(AppSpacing.lg),
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
    // The error is shown only once the user tried to submit, not while typing.
    var submitAttempted = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            final pattern = trustedImageSenderPattern(controller.text);
            void add() {
              _addSender(ref, pattern!);
              Navigator.of(ctx).pop();
            }

            return AlertDialog(
              title: const Text('Add allowed address'),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email address or pattern',
                  hintText: '*@example.com',
                  helperText: '* matches any characters, e.g. *@example.com',
                  errorText: submitAttempted && pattern == null
                      ? 'Not an email address or pattern like *@example.com'
                      : null,
                ),
                onChanged: (_) => setState(() => submitAttempted = false),
                onSubmitted: (_) {
                  if (pattern != null) {
                    add();
                  } else {
                    setState(() => submitAttempted = true);
                  }
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: pattern == null ? null : add,
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _addSender(WidgetRef ref, String pattern) {
    unawaited(
      ref
          .read(userPreferencesRepositoryProvider)
          .addTrustedImageSender(pattern),
    );
  }
}
