import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/core/dictation_comparison.dart';
import 'package:listenook/ui/dictation_panel.dart';

void main() {
  testWidgets(
    'wrong checks shake again; editing and reduced motion stop the shake',
    (tester) async {
      final controller = TextEditingController(text: 'wrong');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      DictationResult? result;
      var reducedMotion = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: [AppStrings.delegate],
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reducedMotion),
                child: Scaffold(
                  body: DictationPanel(
                    controller: controller,
                    focusNode: focus,
                    targetLabel: 'Sentence 1',
                    eligible: true,
                    result: result,
                    onChanged: (_) {},
                    onCheck: () => update(
                      () => result = compareDictation('right', 'wrong'),
                    ),
                    onReplay: () {},
                    onClose: () {},
                  ),
                ),
              );
            },
          ),
        ),
      );
      double offset() => tester
          .widget<Transform>(find.byKey(const Key('dictation-answer-shake')))
          .transform
          .storage[12];
      for (var retry = 0; retry < 2; retry++) {
        await tester.tap(find.byKey(const Key('dictation-check')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        expect(offset().abs(), greaterThan(0));
        await tester.pumpAndSettle();
        expect(offset().abs(), lessThan(.001));
      }
      await tester.tap(find.byKey(const Key('dictation-check')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      update(() => result = null);
      await tester.pump();
      expect(offset(), 0);
      update(() => reducedMotion = true);
      await tester.pump();
      await tester.tap(find.byKey(const Key('dictation-check')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(offset(), 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('check button advertises its shortcut per platform', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'draft');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    for (final (platform, modifier) in [
      (TargetPlatform.macOS, '⌘'),
      (TargetPlatform.windows, 'Ctrl+'),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: DictationPanel(
              controller: controller,
              focusNode: focus,
              targetLabel: 'Sentence 1',
              eligible: true,
              result: null,
              onChanged: (_) {},
              onCheck: () {},
              onReplay: () {},
              onClose: () {},
            ),
          ),
        ),
      );
      // Let the theme transition finish so the platform is not lerped.
      await tester.pumpAndSettle();
      expect(find.byTooltip('Check ($modifier↩)'), findsOneWidget);
    }
    expect(
      tester.getSize(find.byKey(const Key('close-dictation'))),
      const Size(40, 40),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('incorrect answer feedback keeps missing words hidden', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'It happened');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: [AppStrings.delegate],
        home: Scaffold(
          body: DictationPanel(
            controller: controller,
            focusNode: focus,
            targetLabel: 'Sentence 2',
            eligible: true,
            result: compareDictation(
              'It happened when I was in school',
              'It happened',
            ),
            onChanged: (_) {},
            onCheck: () {},
            onReplay: () {},
            onClose: () {},
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('dictation-retry')), findsOneWidget);
    expect(find.textContaining('school'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('school')), findsNothing);
    expect(find.byKey(const Key('dictation-correct')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('check feedback echoes answer with wrong and missing words', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'the quik fox jumps');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: [AppStrings.delegate],
        home: Scaffold(
          body: DictationPanel(
            controller: controller,
            focusNode: focus,
            targetLabel: 'Sentence 1',
            eligible: true,
            result: compareDictation(
              'the quick brown fox jumps high',
              'the quik fox jumps',
            ),
            onChanged: (_) {},
            onCheck: () {},
            onReplay: () {},
            onClose: () {},
          ),
        ),
      ),
    );
    final diff = find.byKey(const Key('dictation-diff'));
    expect(diff, findsOneWidget);
    expect(
      tester.widget<Text>(diff).textSpan!.toPlainText(),
      'the quik … fox jumps …',
    );
    expect(find.textContaining('quick'), findsNothing);
    expect(find.textContaining('brown'), findsNothing);
    expect(find.textContaining('high'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'typing and IME composition do not accidentally check; narrow panel fits',
    (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      var checks = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: DictationPanel(
                  controller: controller,
                  focusNode: focus,
                  targetLabel: 'Sentence 1 · 00:00',
                  eligible: true,
                  result: null,
                  onChanged: (_) {},
                  onCheck: () => checks++,
                  onReplay: () {},
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      final input = find.byKey(const Key('dictation-answer'));
      await tester.tap(input);
      await tester.enterText(input, 'six cats');
      for (final key in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.keyS,
        LogicalKeyboardKey.keyX,
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.arrowLeft,
      ]) {
        await tester.sendKeyEvent(key);
      }
      expect(checks, 0);
      controller.value = const TextEditingValue(
        text: 'hello',
        composing: TextRange(start: 0, end: 5),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(checks, 0);
      controller.clearComposing();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(checks, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
