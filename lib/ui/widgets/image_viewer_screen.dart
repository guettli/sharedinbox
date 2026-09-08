import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

/// Full-screen, pinch-to-zoom viewer for a locally cached image attachment.
///
/// The bytes have already been downloaded to [path] by the caller; this screen
/// only renders them. It sits on a dark scaffold with a close affordance (the
/// app bar back button) and an action to hand the file off to another app.
class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({
    super.key,
    required this.path,
    required this.filename,
  });

  final String path;
  final String filename;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(filename, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Open externally',
            onPressed: () => OpenFilex.open(path),
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
