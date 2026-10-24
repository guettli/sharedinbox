import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/ui/utils/open_file.dart';
import 'package:sharedinbox/ui/utils/save_file_as.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

/// Full-screen, pinch-to-zoom viewer for a locally cached image attachment.
///
/// The bytes have already been downloaded to [path] by the caller; this screen
/// only renders them. It sits on a dark scaffold with a close affordance (the
/// app bar back button), an action to hand the file off to another app and,
/// on desktop, one to save it to a chosen location.
class ImageViewerScreen extends ConsumerWidget {
  const ImageViewerScreen({
    super.key,
    required this.path,
    required this.filename,
  });

  final String path;
  final String filename;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(filename, overflow: TextOverflow.ellipsis),
        actions: [
          if (supportsSaveAs)
            IconButton(
              icon: const Icon(Icons.save_alt),
              tooltip: 'Save as…',
              onPressed: () => saveFileAs(
                context,
                picker: ref.read(saveLocationPickerProvider),
                filename: filename,
                source: () async => path,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Open externally',
            onPressed: () async {
              final problem = await openFile(path);
              if (problem != null && context.mounted) {
                context.showAppSnackBar(
                  problem.text,
                  level: AppLogLevel.warn,
                  event: 'image.open_failed',
                  data: {'filename': filename, 'detail': problem.detail},
                );
              }
            },
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Image.file(
            File(path),
            errorBuilder: (context, error, stack) => const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This image could not be displayed.',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
