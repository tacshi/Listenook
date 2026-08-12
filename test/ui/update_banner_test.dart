import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/l10n/strings.dart';
import 'package:meow_stt/ui/app_shell.dart';

void main() {
  testWidgets('shows a persistent restart action with the target version', (
    tester,
  ) async {
    var restarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateReadyBanner(
            version: '2.0.0',
            installing: false,
            onRestart: () => restarts++,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('update-ready-banner')), findsOneWidget);
    expect(find.text('MeowSTT 2.0.0 is ready to install.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('restart-to-update')));
    expect(restarts, 1);
  });

  testWidgets('localizes and disables the action while installation starts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: UpdateReadyBanner(
            version: '2.0.0',
            installing: true,
            onRestart: () => fail('disabled action was invoked'),
          ),
        ),
      ),
    );

    expect(find.text('MeowSTT 2.0.0 已下载完成。'), findsOneWidget);
    expect(find.text('正在重启…'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });
}
