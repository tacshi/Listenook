import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/local_media_source_resolver.dart';
import 'package:listenook/data/transcript_exporter.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/state/app_controller.dart';
import 'package:listenook/ui/inbox_page.dart';
import 'package:listenook/ui/keyboard_shortcuts.dart';
import 'package:listenook/ui/library_page.dart';
import 'package:listenook/ui/platform/platform_context.dart';
import 'package:listenook/ui/review/listening_widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('a phone Library keeps groups in a sheet and actions in menus', (
    tester,
  ) async {
    final controller = await _controller(tester, const Size(390, 844));
    await _pump(tester, controller, const LibraryPage());

    // Only the row's group pill: the organizer list is not on screen.
    expect(find.text('English'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open-library-job-done')),
      findsNothing,
      reason: 'row buttons fold into the menu',
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('show-library-organizer')));
    await tester.pumpAndSettle();
    expect(find.text('English'), findsNWidgets(2));
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget, reason: 'choosing closes it');

    await tester.tap(find.byKey(const ValueKey('library-item-menu-done')));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
  });

  testWidgets('a narrow Inbox opens its batch options in a sheet', (
    tester,
  ) async {
    final controller = await _controller(tester, const Size(390, 844));
    controller.addToInbox('ready');
    await _pump(
      tester,
      controller,
      InboxPage(onAddFiles: () {}, onImportFolder: () {}),
    );

    expect(find.byKey(const Key('inbox-detail-pane')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('inbox-batch-options-sheet')));
    await tester.pumpAndSettle();
    expect(find.text('Batch options'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sentence buttons are finger-sized on touch', (tester) async {
    Future<Size> sizeWith({required bool touch}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            platform: touch ? TargetPlatform.iOS : TargetPlatform.macOS,
          ),
          localizationsDelegates: const [AppStrings.delegate],
          home: InputModality(
            initialTouch: touch,
            child: Scaffold(
              body: SentenceNavigationControls(
                onPrevious: () {},
                onNext: () {},
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.byKey(const Key('previous-sentence')));
    }

    final touch = await sizeWith(touch: true);
    expect(touch.width, greaterThanOrEqualTo(44));
    expect(touch.height, greaterThanOrEqualTo(44));
    await sizeWith(touch: false);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('previous-sentence')))
          .constraints,
      const BoxConstraints.tightFor(width: 32, height: 40),
    );
  });

  testWidgets('⌘. works where Escape does (iPad keyboards have no Esc)', (
    tester,
  ) async {
    var escapes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () => escapes++,
            commandPeriod: () => escapes++,
          },
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    expect(
      isEscapeEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.period,
          logicalKey: LogicalKeyboardKey.period,
          timeStamp: Duration.zero,
        ),
      ),
      isTrue,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(escapes, 2);
  });
}

Future<AppController> _controller(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final now = DateTime.now().toUtc();
  final controller = AppController(
    credentialStore: MemoryCredentialStore('configured'),
    settingsRepository: MemorySettingsRepository(
      const AppSettings(onboardingComplete: true),
    ),
    jobRepository: MemoryJobRepository([
      TranscriptionJob(
        id: 'done',
        batchId: 'batch',
        sourcePath: '/recordings/a-long-lecture-recording-name.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        groupId: 'group-english',
        document: TranscriptDocument(
          tokens: const [],
          segments: const [],
          speakers: const [],
          updatedAt: now,
        ),
      ),
      TranscriptionJob(
        id: 'ready',
        batchId: 'batch',
        sourcePath: '/recordings/ready.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.ready,
      ),
    ]),
    libraryCatalogRepository: _Catalog(),
    mediaService: FakeMediaService(),
    sourceResolver: const LocalMediaSourceResolver(),
    sonioxClient: FakeSonioxClient(),
    exporter: const DefaultTranscriptExporter(),
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  return controller;
}

Future<void> _pump(
  WidgetTester tester,
  AppController controller,
  Widget page,
) async {
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
        home: Scaffold(body: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Catalog implements LibraryCatalogRepository {
  LibraryCatalog value = const LibraryCatalog(
    groups: [LibraryGroup(id: 'group-english', name: 'English')],
  );

  @override
  Future<LibraryCatalog> load() async => value;

  @override
  Future<void> save(LibraryCatalog catalog) async => value = catalog;
}
