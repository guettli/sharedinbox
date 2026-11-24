import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/entry_markdown.dart';

Future<void> _pump(
  WidgetTester tester,
  String body, {
  ValueChanged<int>? onToggleTask,
  EntryImageLoader? loadImage,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: EntryMarkdown(
            body: body,
            onToggleTask: onToggleTask,
            loadImage: loadImage,
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

/// A 1×1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  'WjR9awAAAABJRU5ErkJggg==',
);

typedef _Image = ({String contentType, Uint8List bytes});

Checkbox _checkbox(WidgetTester tester, int i) =>
    tester.widget<Checkbox>(find.byKey(Key('entryTask_$i')));

void main() {
  testWidgets('renders heading, bold and list as rich text', (tester) async {
    await _pump(tester, '# Head\n\nSome **bold** text\n\n- one\n- two');
    expect(find.textContaining('Head', findRichText: true), findsWidgets);
    expect(find.textContaining('bold', findRichText: true), findsWidgets);
    expect(find.textContaining('one', findRichText: true), findsWidgets);
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('# Head', findRichText: true), findsNothing);
  });

  testWidgets('task checkboxes show their state and report taps',
      (tester) async {
    final taps = <int>[];
    await _pump(tester, '- [ ] a\n- [x] b', onToggleTask: taps.add);
    expect(_checkbox(tester, 0).value, isFalse);
    expect(_checkbox(tester, 1).value, isTrue);

    await tester.tap(find.byKey(const Key('entryTask_1')));
    await tester.pump();
    expect(taps, [1]);
  });

  testWidgets('without a callback the checkboxes are read-only',
      (tester) async {
    await _pump(tester, '- [ ] a');
    expect(_checkbox(tester, 0).onChanged, isNull);
    await tester.tap(find.byKey(const Key('entryTask_0')));
    await tester.pump();
    expect(_checkbox(tester, 0).value, isFalse);
  });

  testWidgets('si-img is a placeholder and never fetched', (tester) async {
    await _pump(tester, '![pic](si-img:abc)');
    expect(find.byKey(const Key('entryImagePlaceholder')), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.text('pic'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a remote image is a placeholder and never fetched',
      (tester) async {
    await _pump(tester, '![remote](https://example.com/track.png)');
    expect(find.byKey(const Key('entryImagePlaceholder')), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  group('si-img with a loader (#1377)', () {
    testWidgets('shows a placeholder while loading, then the image',
        (tester) async {
      final loading = Completer<_Image?>();
      final asked = <String>[];
      await _pump(
        tester,
        '![pic](si-img:abc)',
        loadImage: (id) {
          asked.add(id);
          return loading.future;
        },
        settle: false,
      );
      await tester.pump();
      expect(find.byKey(const Key('entryImageLoading')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('pic'), findsOneWidget);
      expect(find.byKey(const Key('entryImage_abc')), findsNothing);

      loading.complete((contentType: 'image/png', bytes: _png));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('entryImage_abc')), findsOneWidget);
      expect(find.byKey(const Key('entryImageLoading')), findsNothing);
      expect(asked, ['abc']);
    });

    testWidgets('an image that cannot be had now can be tried again',
        (tester) async {
      _Image? next;
      var calls = 0;
      await _pump(
        tester,
        '![](si-img:abc)',
        loadImage: (_) async {
          calls++;
          return next;
        },
      );
      expect(find.byKey(const Key('entryImageRetry')), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(calls, 1);

      next = (contentType: 'image/png', bytes: _png);
      await tester.tap(find.byKey(const Key('entryImageRetry')));
      await tester.pump();
      await tester.pump();
      expect(calls, 2);
      expect(find.byKey(const Key('entryImage_abc')), findsOneWidget);
    });

    testWidgets('remote and cid: images are placeholders, never loaded',
        (tester) async {
      var calls = 0;
      await _pump(
        tester,
        '![a](https://example.com/track.png)\n\n![b](cid:part1)',
        loadImage: (_) async {
          calls++;
          return null;
        },
      );
      expect(find.byKey(const Key('entryImagePlaceholder')), findsNWidgets(2));
      expect(find.byKey(const Key('entryImageRetry')), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(calls, 0);
    });
  });
}
