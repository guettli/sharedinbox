import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/ui/widgets/text_prompt_dialog.dart';

void main() {
  // Pumps a button that opens the prompt and records what it returns.
  Future<List<String?>> pumpPrompt(WidgetTester tester, {int maxLines = 1}) {
    final results = <String?>[];
    return tester
        .pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
              await showTextPrompt(
                context,
                title: 'Name it',
                confirmLabel: 'Create',
                maxLines: maxLines,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    )
        .then((_) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    });
  }

  testWidgets('returns the trimmed text and closes cleanly', (tester) async {
    final results = await pumpPrompt(tester);
    await tester.enterText(find.byType(TextField), '  Projects  ');
    await tester.tap(find.text('Create'));
    // Runs the exit animation, which used to hit the disposed controller.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Name it'), findsNothing);
    expect(results, ['Projects']);
  });

  testWidgets('Enter submits a single-line prompt', (tester) async {
    final results = await pumpPrompt(tester);
    await tester.enterText(find.byType(TextField), 'Projects');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(results, ['Projects']);
  });

  testWidgets('an empty field keeps the dialog open', (tester) async {
    final results = await pumpPrompt(tester);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Name it'), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets('Cancel returns null', (tester) async {
    final results = await pumpPrompt(tester, maxLines: 4);
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(results, [null]);
  });
}
