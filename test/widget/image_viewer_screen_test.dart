import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/utils/save_file_as.dart';
import 'package:sharedinbox/ui/widgets/image_viewer_screen.dart';

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  Future<void> pumpViewer(
    WidgetTester tester,
    String path,
    SaveLocationPicker picker,
  ) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [saveLocationPickerProvider.overrideWithValue(picker)],
          child: MaterialApp(
            home: ImageViewerScreen(path: path, filename: 'photo.png'),
          ),
        ),
      );

  testWidgets('Save as… on Linux copies the image to the chosen path', (
    tester,
  ) async {
    // Reset inside the body: the post-test invariant check runs before
    // tearDown callbacks.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final dir = Directory.systemTemp.createTempSync('viewer_save_as');
      addTearDown(() => dir.deleteSync(recursive: true));
      final source = File('${dir.path}/cached.png')..writeAsBytesSync(png);
      final target = '${dir.path}/saved.png';
      final suggested = <String>[];
      await pumpViewer(tester, source.path, (name) async {
        suggested.add(name);
        return target;
      });

      await tester.tap(find.byTooltip('Save as…'));
      // File.copy is real I/O: alternate real waits with pumps.
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.textContaining('Saved to').evaluate().isNotEmpty) break;
      }

      expect(suggested, ['photo.png']);
      expect(File(target).readAsBytesSync(), png);
      expect(find.text('Saved to $target'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('no Save as… on Android', (tester) async {
    await pumpViewer(tester, '/nonexistent.png', (_) async => null);
    expect(find.byTooltip('Open externally'), findsOneWidget);
    expect(find.byTooltip('Save as…'), findsNothing);
  });
}
