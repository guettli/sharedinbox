import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/shrink_image_dialog.dart';

/// Standalone tool for shrinking an arbitrary image without composing a mail:
/// pick a file, tweak the shrink settings, then save the result somewhere.
class ShrinkImageScreen extends ConsumerStatefulWidget {
  const ShrinkImageScreen({super.key});

  @override
  ConsumerState<ShrinkImageScreen> createState() => _ShrinkImageScreenState();
}

class _ShrinkImageScreenState extends ConsumerState<ShrinkImageScreen> {
  bool _busy = false;

  Future<void> _pickAndShrink() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      final files = result?.files ?? const [];
      final path = files.isEmpty ? null : files.first.path;
      if (path == null || !mounted) return;
      final service = ref.read(imageShrinkServiceProvider);
      if (!service.isShrinkable(_guessType(path))) {
        context.showAppSnackBar(
          'That file is not a supported image.',
          duration: const Duration(seconds: 5),
        );
        return;
      }
      final shrunk = await ShrinkImageDialog.show(
        context,
        path: path,
        service: service,
      );
      if (shrunk == null || !mounted) return;

      final base = p.basenameWithoutExtension(path);
      final savedPath = await FilePicker.saveFile(
        dialogTitle: 'Save shrunk image',
        fileName: '$base-shrunk.jpg',
        bytes: shrunk.bytes,
      );
      if (savedPath == null || !mounted) return;
      // On desktop the picker only chooses a location; on mobile it writes the
      // bytes itself. Write on desktop so both paths end up with the file.
      if (!Platform.isAndroid && !Platform.isIOS) {
        await File(savedPath).writeAsBytes(shrunk.bytes);
      }
      if (!mounted) return;
      context.showAppSnackBar(
        'Saved shrunk image',
        duration: const Duration(seconds: 3),
      );
    } catch (e, stack) {
      if (!mounted) return;
      context.showAppSnackBar(
        'Failed to shrink image: $e',
        level: AppLogLevel.error,
        event: 'shrink_image.failed',
        error: e,
        stack: stack,
        duration: const Duration(seconds: 5),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _guessType(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      case '.gif':
        return 'image/gif';
      default:
        return 'application/octet-stream';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shrink image')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Pick an image to resize and re-encode it as a smaller JPEG. '
                'The original file is left untouched.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: _busy ? null : _pickAndShrink,
                icon: const Icon(Icons.compress),
                label: const Text('Choose image'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
