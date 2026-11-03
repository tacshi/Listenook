import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/data/local_media_source_resolver.dart';
import 'package:listenook/data/transcript_exporter.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/state/app_controller.dart';
import 'package:listenook/ui/app_shell.dart';
import 'package:listenook/ui/platform/platform_context.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('an iPhone gets tabs and no window toolbar', (tester) async {
    final controller = await _pumpShell(tester, const Size(390, 844));

    expect(find.byKey(const Key('app-bottom-navigation')), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const Key('app-window-toolbar')), findsNothing);

    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.inbox);
    // No folder monitoring on iOS.
    expect(
      find.textContaining('Automatically add media from a folder'),
      findsNothing,
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(controller.destination, AppDestination.settings);
    // Login items, tray and Dock icons do not exist on iOS.
    expect(find.byKey(const Key('settings-launch-at-login')), findsNothing);
    expect(find.byKey(const Key('settings-show-tray-icon')), findsNothing);
    expect(find.byKey(const Key('settings-inbox-monitor-path')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an iPad keeps the rail without a window toolbar', (
    tester,
  ) async {
    await _pumpShell(tester, const Size(1366, 1024));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(const Key('inbox-fab')), findsOneWidget);
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);
    expect(find.byKey(const Key('app-window-toolbar')), findsNothing);
  });

  testWidgets('the rail keeps clear of a landscape iPhone notch', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(left: 59, right: 59);
    await _pumpShell(tester, const Size(844, 390));

    expect(
      tester.getTopLeft(find.byType(NavigationRail)).dx,
      greaterThanOrEqualTo(59),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an iPad trackpad switches to the pointer layout until a touch', (
    tester,
  ) async {
    await _pumpShell(tester, const Size(1366, 1024));
    final context = tester.element(find.byType(NavigationRail));
    expect(context.touchActive, isTrue);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(600, 500));
    await mouse.moveTo(const Offset(610, 510));
    await tester.pump();
    expect(tester.element(find.byType(NavigationRail)).touchActive, isFalse);

    await tester.tapAt(const Offset(600, 500));
    await tester.pump();
    expect(tester.element(find.byType(NavigationRail)).touchActive, isTrue);
  });
}

Future<AppController> _pumpShell(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = AppController(
    credentialStore: MemoryCredentialStore(),
    settingsRepository: MemorySettingsRepository(),
    jobRepository: MemoryJobRepository([]),
    mediaService: FakeMediaService(),
    sourceResolver: const LocalMediaSourceResolver(),
    sonioxClient: FakeSonioxClient(),
    exporter: const DefaultTranscriptExporter(),
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  await controller.updateSettings(
    controller.settings.copyWith(onboardingComplete: true),
  );
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [
          AppStrings.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        builder: (context, child) => InputModality(child: child!),
        home: const AppShell(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}
