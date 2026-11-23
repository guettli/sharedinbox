import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/entry_markdown.dart';

Future<void> _pump(
  WidgetTester tester,
  String body, {
  ValueChanged<int>? onToggleTask,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: EntryMarkdown(body: body, onToggleTask: onToggleTask),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

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
}
