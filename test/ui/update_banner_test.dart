import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/ui/app_shell.dart';

void main() {
  testWidgets('shows update as a compact title-bar action', (tester) async {
    var restarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: AppWindowToolbar(
            sidebarVisible: true,
            onToggleSidebar: () {},
            updateVersion: '2.0.0',
            updateInstalling: false,
            onRestartUpdate: () => restarts++,
          ),
        ),
      ),
    );

    final toolbar = find.byKey(const Key('app-window-toolbar'));
    final toggle = find.byKey(const Key('toggle-app-sidebar'));
    final update = find.byKey(const Key('restart-to-update'));
    expect(find.byKey(const Key('update-ready-banner')), findsNothing);
    expect(find.text('Listenook 2.0.0 is ready to install.'), findsNothing);
    expect(update, findsOneWidget);
    expect(tester.getSize(update), const Size.square(32));
    expect(tester.getCenter(toggle).dx, lessThan(tester.getCenter(update).dx));
    expect(tester.getTopLeft(update).dy, tester.getTopLeft(toolbar).dy);
    expect(
      find.byTooltip('Listenook 2.0.0 is ready to install. Restart to Update'),
      findsOneWidget,
    );
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
          body: AppWindowToolbar(
            sidebarVisible: true,
            onToggleSidebar: () {},
            updateVersion: '2.0.0',
            updateInstalling: true,
            onRestartUpdate: () => fail('disabled action was invoked'),
          ),
        ),
      ),
    );

    expect(find.text('Listenook 2.0.0 已下载完成。'), findsNothing);
    expect(find.byTooltip('正在重启…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.byKey(const Key('restart-to-update')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('omits the update action until an update is ready', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppWindowToolbar(sidebarVisible: true, onToggleSidebar: () {}),
        ),
      ),
    );

    expect(find.byKey(const Key('restart-to-update')), findsNothing);
  });
}
