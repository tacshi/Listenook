import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/data/local_media_source_resolver.dart';
import 'package:listenook/data/transcript_exporter.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/state/app_controller.dart';
import 'package:listenook/ui/library_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('Library visuals keep organizer metadata compact', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final catalog = _Catalog()
      ..value = const LibraryCatalog(
        groups: [LibraryGroup(id: 'group-english', name: 'English')],
        tags: [
          LibraryTag(id: 'tag-practice', name: 'Practice'),
          LibraryTag(id: 'tag-review', name: 'Review'),
        ],
      );
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'organized',
          batchId: 'batch',
          sourcePath: '/recordings/organized.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          groupId: 'group-english',
          tagIds: const {'tag-practice', 'tag-review'},
        ),
        TranscriptionJob(
          id: 'plain',
          batchId: 'batch',
          sourcePath: '/recordings/plain.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
        ),
      ]),
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    final organizedItem = find.byKey(
      const ValueKey('library-history-item-organized'),
    );
    final plainItem = find.byKey(const ValueKey('library-history-item-plain'));
    expect(
      find.ancestor(
        of: find.text('organized.wav'),
        matching: find.byType(Card),
      ),
      findsNothing,
    );
    expect(find.byType(Divider), findsOneWidget);
    expect(find.text('English'), findsWidgets);
    expect(find.text('Practice'), findsWidgets);
    expect(find.text('Review'), findsWidgets);
    expect(
      tester.getSize(organizedItem).height,
      lessThanOrEqualTo(tester.getSize(plainItem).height + 8),
    );

    Color tagPillColor(String tagId) => tester
        .widget<Icon>(
          find.descendant(
            of: find.byKey(ValueKey('library-item-tag-organized-$tagId')),
            matching: find.byIcon(Icons.sell_outlined),
          ),
        )
        .color!;

    final practiceColor = tagPillColor('tag-practice');
    final reviewColor = tagPillColor('tag-review');
    expect(practiceColor, isNot(reviewColor));
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(const ValueKey('library-tag-tag-practice')),
              matching: find.byIcon(Icons.sell_outlined),
            ),
          )
          .color,
      practiceColor,
    );
  });

  testWidgets('library sidebar tags never share a color', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final catalog = _Catalog()
      ..value = const LibraryCatalog(
        tags: [
          LibraryTag(id: 'tag-meeting', name: 'meeting'),
          LibraryTag(id: 'tag-podcast', name: 'podcast'),
          LibraryTag(id: 'tag-shadowing', name: 'shadowing'),
        ],
      );
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'a',
          batchId: 'batch',
          sourcePath: '/a.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          tagIds: const {'tag-meeting'},
        ),
        TranscriptionJob(
          id: 'b',
          batchId: 'batch',
          sourcePath: '/b.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          tagIds: const {'tag-podcast'},
        ),
        TranscriptionJob(
          id: 'c',
          batchId: 'batch',
          sourcePath: '/c.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          tagIds: const {'tag-shadowing'},
        ),
      ]),
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    Color colorOf(String tagId) => tester
        .widget<Icon>(
          find.descendant(
            of: find.byKey(ValueKey('library-tag-$tagId')),
            matching: find.byIcon(Icons.sell_outlined),
          ),
        )
        .color!;

    final colors = {
      colorOf('tag-meeting'),
      colorOf('tag-podcast'),
      colorOf('tag-shadowing'),
    };
    expect(colors, hasLength(3));
  });

  testWidgets('Library toolbar keeps search status and selection aligned', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(const []),
      libraryCatalogRepository: _Catalog(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    final toolbar = find.byKey(const Key('library-toolbar'));
    final search = find.byKey(const Key('library-search'));
    final status = find.byKey(const Key('library-status-filter'));
    final selection = find.byKey(const Key('toggle-library-selection'));
    expect(search, findsOneWidget);
    expect(find.byKey(const Key('toggle-library-search')), findsNothing);
    expect(
      tester.widget<TextField>(search).decoration?.prefixIcon,
      isA<Icon>(),
    );
    for (final label in [
      'Any time',
      'Last 7 days',
      'Under 30 min',
      '30 min+',
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(
      find.descendant(of: toolbar, matching: find.text('All statuses')),
      findsOneWidget,
    );
    expect(find.descendant(of: toolbar, matching: selection), findsOneWidget);
    final toolbarCenter = tester.getCenter(toolbar).dy;
    expect(tester.getCenter(search).dy, closeTo(toolbarCenter, 1));
    expect(tester.getCenter(status).dy, closeTo(toolbarCenter, 1));
    expect(tester.getCenter(selection).dy, closeTo(toolbarCenter, 1));

    await tester.tap(selection);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-selection-bar')), findsOneWidget);
    for (final key in [
      'bulk-tag-library-items',
      'bulk-move-library-items',
      'bulk-export-library-items',
      'bulk-remove-library-items',
    ]) {
      final button = tester.widget<IconButton>(find.byKey(Key(key)));
      expect(button.style?.side, isNull);
    }
    expect(
      tester.getTopLeft(find.byKey(const Key('library-selection-bar'))).dy,
      greaterThan(tester.getBottomLeft(toolbar).dy),
    );
    await tester.tap(selection);
    await tester.pumpAndSettle();

    await tester.enterText(search, 'meeting');
    await tester.pump();
    expect(find.byKey(const Key('clear-library-search')), findsOneWidget);
    await tester.tap(find.byKey(const Key('clear-library-search')));
    await tester.pump();
    expect(search, findsOneWidget);
    expect(tester.widget<TextField>(search).controller?.text, isEmpty);

    final dropdown = find.byType(DropdownButton<String>);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Completed').last);
    await tester.pumpAndSettle();

    final selected = tester.widget<DropdownButton<String>>(dropdown);
    expect(selected.value, 'completed');
    expect(selected.focusColor, Colors.transparent);
  });

  testWidgets('Needs attention includes every actionable inactive job', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    const actionableStatuses = [
      JobStatus.ready,
      JobStatus.paused,
      JobStatus.failed,
      JobStatus.cancelled,
      JobStatus.missingSource,
      JobStatus.empty,
    ];
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        for (final status in actionableStatuses)
          TranscriptionJob(
            id: status.name,
            batchId: 'batch',
            sourcePath: '/missing/${status.name}.wav',
            createdAt: now,
            updatedAt: now,
            status: status,
          ),
        TranscriptionJob(
          id: 'completed',
          batchId: 'batch',
          sourcePath: '/missing/completed.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
        ),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    final statusDropdown = find.byWidgetPredicate(
      (widget) => widget is DropdownButton<String>,
    );
    await tester.tap(statusDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Needs attention').last);
    await tester.pumpAndSettle();

    for (final status in actionableStatuses) {
      expect(find.text('${status.name}.wav'), findsOneWidget);
    }
    expect(find.text('completed.wav'), findsNothing);
  });

  testWidgets(
    'Add to Inbox restores ready and failed jobs without transcribing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final temporaryDirectory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('meow-stt-ready-job-'),
      );
      expect(temporaryDirectory, isNotNull);
      final directory = temporaryDirectory!;
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/ready.wav');
      await tester.runAsync(() => source.writeAsBytes(const [0]));
      final now = DateTime.now().toUtc();
      final soniox = _Soniox();
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: _Settings(),
        jobRepository: _Jobs([
          TranscriptionJob(
            id: 'ready',
            batchId: 'batch',
            sourcePath: source.path,
            createdAt: now,
            updatedAt: now,
            status: JobStatus.ready,
          ),
          TranscriptionJob(
            id: 'failed',
            batchId: 'batch',
            sourcePath: source.path,
            createdAt: now,
            updatedAt: now,
            status: JobStatus.failed,
            errorCode: 'conversion_failed',
            errorMessage: 'The audio could not be extracted.',
          ),
        ]),
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: soniox,
        exporter: const DefaultTranscriptExporter(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      controller.setDestination(AppDestination.library);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: LibraryPage()),
          ),
        ),
      );

      final addToInboxButton = find.byKey(
        const Key('add-to-inbox-ready-job-ready'),
      );
      final addFailedToInboxButton = find.byKey(
        const Key('add-to-inbox-failed-job-failed'),
      );
      expect(addToInboxButton, findsOneWidget);
      expect(addFailedToInboxButton, findsOneWidget);
      expect(tester.widget<IconButton>(addToInboxButton).onPressed, isNotNull);
      expect(
        tester.widget<IconButton>(addFailedToInboxButton).onPressed,
        isNotNull,
      );
      expect(tester.getSize(addToInboxButton).width, lessThanOrEqualTo(48));
      expect(find.text('Add to Inbox'), findsNothing);
      expect(find.byIcon(Icons.input_rounded), findsNWidgets(2));
      expect(
        find.byTooltip('Adds this file to the Inbox transcription queue.'),
        findsNWidgets(2),
      );

      await tester.tap(addFailedToInboxButton);
      await tester.pumpAndSettle();

      expect(controller.destination, AppDestination.inbox);
      expect(controller.inboxJobs.single.id, 'failed');
      expect(controller.activeWorkspaceJobId, isNull);
      expect(controller.inboxJobs.single.status, JobStatus.failed);
      expect(controller.processing, isFalse);
      expect(soniox.uploadCalls, 0);
    },
  );

  testWidgets('Open enters Workspace without adding history to Inbox', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'completed',
          batchId: 'batch',
          sourcePath: '/missing/completed.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          document: TranscriptDocument(
            tokens: const [],
            segments: const [
              TranscriptSegment(
                id: 'segment',
                startMs: 0,
                endMs: 1000,
                text: 'Transcript',
              ),
            ],
            speakers: const [],
            updatedAt: now,
          ),
        ),
      ]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    expect(find.text('Export'), findsNothing);
    expect(find.text('Open'), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('export-library-job-completed')),
          )
          .tooltip,
      'Export',
    );
    final openButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('open-library-job-completed')),
    );
    expect(openButton.tooltip, 'Open');
    expect(
      openButton.style?.backgroundColor?.resolve(const <WidgetState>{}),
      Colors.transparent,
    );
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('open-library-job-completed')))
          .dx,
      lessThan(
        tester
            .getCenter(
              find.byKey(const ValueKey('export-library-job-completed')),
            )
            .dx,
      ),
      reason: 'Library actions should match Inbox: Open, then Export.',
    );
    await tester.tap(find.byKey(const ValueKey('open-library-job-completed')));
    await tester.pump();

    expect(controller.destination, AppDestination.workspace);
    expect(controller.activeWorkspaceJobId, 'completed');
    expect(controller.inboxJobs, isEmpty);
  });

  testWidgets(
    'Rename changes the display title but keeps the source filename',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.now().toUtc();
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'organized',
          batchId: 'batch',
          sourcePath: '/recordings/original.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
        ),
      ]);
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: _Settings(),
        jobRepository: jobs,
        libraryCatalogRepository: _Catalog(),
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: LibraryPage()),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('library-item-menu-organized')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('rename-library-item-field')),
        'Weekly sync',
      );
      await tester.tap(find.byKey(const Key('confirm-rename-library-item')));
      await tester.pumpAndSettle();

      expect(find.text('Weekly sync'), findsOneWidget);
      expect(find.text('original.wav'), findsOneWidget);
      expect(jobs.saved['organized']!.sourcePath, '/recordings/original.wav');
    },
  );

  testWidgets('A custom display title can be reset to the original filename', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'renamed',
        batchId: 'batch',
        sourcePath: '/recordings/original.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        displayTitle: 'Weekly sync',
      ),
    ]);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      libraryCatalogRepository: _Catalog(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('library-item-menu-renamed')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reset-library-item-title')));
    await tester.pumpAndSettle();

    expect(find.text('Weekly sync'), findsNothing);
    expect(find.text('original.wav'), findsOneWidget);
    expect(jobs.saved['renamed']!.displayTitle, isNull);
  });

  testWidgets('A reusable group can be created before it has items', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final catalog = _Catalog();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(const []),
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('add-library-group')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('library-organizer-name-field')),
      'Work',
    );
    await tester.tap(find.byKey(const Key('confirm-library-organizer')));
    await tester.pumpAndSettle();

    expect(find.text('Work'), findsOneWidget);
    expect(catalog.value.groups.single.name, 'Work');
  });

  testWidgets('Organizer names are unique after trimming and case folding', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final catalog = _Catalog()
      ..value = const LibraryCatalog(
        groups: [LibraryGroup(id: 'group-work', name: 'Work')],
      );
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(const []),
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('add-library-group')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('library-organizer-name-field')),
      ' work ',
    );
    await tester.tap(find.byKey(const Key('confirm-library-organizer')));
    await tester.pump();

    expect(find.text('A group with this name already exists.'), findsOneWidget);
    expect(catalog.value.groups, hasLength(1));
  });

  testWidgets('Moving an item into a group makes the group browsable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final catalog = _Catalog()
      ..value = const LibraryCatalog(
        groups: [LibraryGroup(id: 'group-work', name: 'Work')],
      );
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'meeting',
        batchId: 'batch',
        sourcePath: '/recordings/meeting.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
      ),
      TranscriptionJob(
        id: 'personal',
        batchId: 'batch',
        sourcePath: '/recordings/personal.wav',
        createdAt: now.subtract(const Duration(minutes: 1)),
        updatedAt: now,
        status: JobStatus.completed,
      ),
    ]);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('library-item-menu-meeting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to group'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-to-group-group-work')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-group-group-work')));
    await tester.pumpAndSettle();

    expect(find.text('meeting.wav'), findsOneWidget);
    expect(find.text('personal.wav'), findsNothing);
    expect(jobs.saved['meeting']!.groupId, 'group-work');
  });

  testWidgets('Tag sidebar is read-only and hides reusable unused tags', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final catalog = _Catalog()
      ..value = const LibraryCatalog(
        tags: [
          LibraryTag(id: 'tag-used', name: 'Used'),
          LibraryTag(id: 'tag-unused', name: 'Unused'),
        ],
      );
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'meeting',
          batchId: 'batch',
          sourcePath: '/recordings/meeting.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          tagIds: const {'tag-used'},
        ),
      ]),
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    expect(find.byKey(const Key('add-library-tag')), findsNothing);
    expect(
      find.byKey(const ValueKey('library-tag-menu-tag-used')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('library-tag-tag-used')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('library-tag-tag-used')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('library-tag-tag-unused')), findsNothing);
  });

  testWidgets('Manage tags creates and assigns a custom tag', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final catalog = _Catalog();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'meeting',
        batchId: 'batch',
        sourcePath: '/recordings/meeting.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
      ),
      TranscriptionJob(
        id: 'other',
        batchId: 'batch',
        sourcePath: '/recordings/other.wav',
        createdAt: now.subtract(const Duration(minutes: 1)),
        updatedAt: now,
        status: JobStatus.completed,
      ),
    ]);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('library-item-menu-meeting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage tags'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('new-library-tag-field')),
      ' Important ',
    );
    await tester.tap(find.byKey(const Key('add-library-tag-in-dialog')));
    await tester.pump();
    expect(find.text('Important'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-library-tags')));
    await tester.pumpAndSettle();

    expect(catalog.value.tags.single.name, 'Important');
    final tagId = catalog.value.tags.single.id;
    expect(jobs.saved['meeting']!.tagIds, {tagId});
    await tester.tap(find.byKey(ValueKey('library-tag-$tagId')));
    await tester.pumpAndSettle();

    expect(find.text('meeting.wav'), findsOneWidget);
    expect(find.text('other.wav'), findsNothing);
  });

  testWidgets(
    'Manage tags detaches a tag while keeping it reusable off the sidebar',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.now().toUtc();
      final catalog = _Catalog()
        ..value = const LibraryCatalog(
          tags: [LibraryTag(id: 'tag-important', name: 'Important')],
        );
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'meeting',
          batchId: 'batch',
          sourcePath: '/recordings/meeting.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          tagIds: const {'tag-important'},
        ),
      ]);
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: _Settings(),
        jobRepository: jobs,
        libraryCatalogRepository: catalog,
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: LibraryPage()),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('library-item-menu-meeting')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manage tags'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('library-tag-option-tag-important')),
      );
      await tester.tap(find.byKey(const Key('confirm-library-tags')));
      await tester.pumpAndSettle();

      expect(jobs.saved['meeting']!.tagIds, isEmpty);
      expect(catalog.value.tags.single.name, 'Important');
      expect(
        find.byKey(const ValueKey('library-tag-tag-important')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('library-item-menu-meeting')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manage tags'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-tag-option-tag-important')),
        findsOneWidget,
      );
    },
  );

  testWidgets('Detaching the active last tag returns to all items', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final catalog = _Catalog()
      ..value = const LibraryCatalog(
        tags: [LibraryTag(id: 'tag-important', name: 'Important')],
      );
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'meeting',
        batchId: 'batch',
        sourcePath: '/recordings/meeting.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        tagIds: const {'tag-important'},
      ),
    ]);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('library-tag-tag-important')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('library-item-menu-meeting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage tags'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('library-tag-option-tag-important')),
    );
    await tester.tap(find.byKey(const Key('confirm-library-tags')));
    await tester.pumpAndSettle();

    expect(find.text('meeting.wav'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-tag-tag-important')),
      findsNothing,
    );
  });

  testWidgets('Cancelling Manage tags discards staged custom tags', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final catalog = _Catalog();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'meeting',
        batchId: 'batch',
        sourcePath: '/recordings/meeting.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
      ),
    ]);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('library-item-menu-meeting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage tags'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('new-library-tag-field')),
      'Draft',
    );
    await tester.tap(find.byKey(const Key('add-library-tag-in-dialog')));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(catalog.value.tags, isEmpty);
    expect(jobs.saved['meeting']!.tagIds, isEmpty);
    expect(find.text('Draft'), findsNothing);
  });

  for (final testCase in [
    (
      locale: const Locale('en'),
      menuLabel: 'Manage tags',
      requiredMessage: 'Enter a tag name.',
      duplicateMessage: 'A tag with this name already exists.',
      tooLongMessage: 'Tag names can be up to 60 characters.',
    ),
    (
      locale: const Locale('zh', 'CN'),
      menuLabel: '管理标签',
      requiredMessage: '请输入标签名称。',
      duplicateMessage: '已存在同名标签。',
      tooLongMessage: '标签名称不能超过 60 个字符。',
    ),
  ]) {
    testWidgets(
      'Manage tags validates custom names in ${testCase.locale.languageCode}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final now = DateTime.now().toUtc();
        final catalog = _Catalog()
          ..value = const LibraryCatalog(
            tags: [LibraryTag(id: 'tag-important', name: 'Important')],
          );
        final jobs = _Jobs([
          TranscriptionJob(
            id: 'meeting',
            batchId: 'batch',
            sourcePath: '/recordings/meeting.wav',
            createdAt: now,
            updatedAt: now,
            status: JobStatus.completed,
          ),
        ]);
        final controller = AppController(
          credentialStore: _Credentials(),
          settingsRepository: _Settings(),
          jobRepository: jobs,
          libraryCatalogRepository: catalog,
          mediaService: _Media(),
          sourceResolver: const LocalMediaSourceResolver(),
          sonioxClient: _Soniox(),
          exporter: const DefaultTranscriptExporter(),
        );
        addTearDown(controller.dispose);
        await controller.initialize();

        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: controller,
            child: MaterialApp(
              locale: testCase.locale,
              supportedLocales: AppStrings.supportedLocales,
              localizationsDelegates: const [
                AppStrings.delegate,
                ...GlobalMaterialLocalizations.delegates,
              ],
              home: const Scaffold(body: LibraryPage()),
            ),
          ),
        );

        await tester.tap(
          find.byKey(const ValueKey('library-item-menu-meeting')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(testCase.menuLabel));
        await tester.pumpAndSettle();

        final field = find.byKey(const Key('new-library-tag-field'));
        final addButton = find.byKey(const Key('add-library-tag-in-dialog'));
        await tester.tap(addButton);
        await tester.pump();
        expect(find.text(testCase.requiredMessage), findsOneWidget);

        await tester.enterText(field, ' important ');
        await tester.tap(addButton);
        await tester.pump();
        expect(find.text(testCase.duplicateMessage), findsOneWidget);

        await tester.enterText(field, List.filled(61, 'x').join());
        await tester.tap(addButton);
        await tester.pump();
        expect(find.text(testCase.tooLongMessage), findsOneWidget);

        await tester.enterText(field, ' Custom ');
        await tester.tap(addButton);
        await tester.pump();
        expect(find.text('Custom'), findsOneWidget);
        await tester.tap(find.byKey(const Key('confirm-library-tags')));
        await tester.pumpAndSettle();

        expect(
          catalog.value.tags.map((tag) => tag.name),
          orderedEquals(['Important', 'Custom']),
        );
        final customTagId = catalog.value.tags.last.id;
        expect(jobs.saved['meeting']!.tagIds, {customTagId});
      },
    );
  }

  testWidgets('Deleting a group unfiles its items without deleting them', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final catalog = _Catalog()
      ..value = const LibraryCatalog(
        groups: [LibraryGroup(id: 'group-work', name: 'Work')],
      );
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'meeting',
        batchId: 'batch',
        sourcePath: '/recordings/meeting.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        groupId: 'group-work',
      ),
    ]);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('library-group-menu-group-work')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-organizer')));
    await tester.pumpAndSettle();

    expect(catalog.value.groups, isEmpty);
    expect(jobs.saved['meeting'], isNotNull);
    expect(jobs.saved['meeting']!.groupId, isNull);
    expect(find.text('meeting.wav'), findsOneWidget);
  });

  testWidgets('Multi-select moves all selected items together', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final catalog = _Catalog()
      ..value = const LibraryCatalog(
        groups: [LibraryGroup(id: 'group-work', name: 'Work')],
      );
    final jobs = _Jobs([
      for (final id in ['one', 'two'])
        TranscriptionJob(
          id: id,
          batchId: 'batch',
          sourcePath: '/recordings/$id.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
        ),
    ]);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('toggle-library-selection')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('select-library-item-one')));
    await tester.tap(find.byKey(const ValueKey('select-library-item-two')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-move-library-items')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-to-group-group-work')));
    await tester.pumpAndSettle();

    expect(jobs.saved['one']!.groupId, 'group-work');
    expect(jobs.saved['two']!.groupId, 'group-work');
  });

  testWidgets(
    'Bulk Manage tags applies mixed and custom tags to all selected',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.now().toUtc();
      final catalog = _Catalog()
        ..value = const LibraryCatalog(
          tags: [LibraryTag(id: 'tag-important', name: 'Important')],
        );
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'one',
          batchId: 'batch',
          sourcePath: '/recordings/one.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          tagIds: const {'tag-important'},
        ),
        TranscriptionJob(
          id: 'two',
          batchId: 'batch',
          sourcePath: '/recordings/two.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
        ),
      ]);
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: _Settings(),
        jobRepository: jobs,
        libraryCatalogRepository: catalog,
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: LibraryPage()),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('toggle-library-selection')));
      await tester.pump();
      await tester.tap(find.text('Select all visible'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('bulk-tag-library-items')));
      await tester.pumpAndSettle();

      final importantOption = find.byKey(
        const ValueKey('library-tag-option-tag-important'),
      );
      expect(tester.widget<CheckboxListTile>(importantOption).value, isNull);
      await tester.tap(importantOption);
      await tester.enterText(
        find.byKey(const Key('new-library-tag-field')),
        'Team',
      );
      await tester.tap(find.byKey(const Key('confirm-library-tags')));
      await tester.pumpAndSettle();

      final teamTagId = catalog.value.tags
          .singleWhere((tag) => tag.name == 'Team')
          .id;
      expect(jobs.saved['one']!.tagIds, {'tag-important', teamTagId});
      expect(jobs.saved['two']!.tagIds, {'tag-important', teamTagId});
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('library-tag-tag-important')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('library-tag-$teamTagId')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('Bulk removal confirms before deleting selected library items', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      for (final id in ['one', 'two'])
        TranscriptionJob(
          id: id,
          batchId: 'batch',
          sourcePath: '/recordings/$id.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
        ),
    ]);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      libraryCatalogRepository: _Catalog(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('toggle-library-selection')));
    await tester.pump();
    await tester.tap(find.text('Select all visible'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-remove-library-items')));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 selected'), findsWidgets);
    await tester.tap(find.byKey(const Key('confirm-remove-library-jobs')));
    await tester.pumpAndSettle();

    expect(jobs.saved, isEmpty);
    expect(find.text('one.wav'), findsNothing);
    expect(find.text('two.wav'), findsNothing);
  });

  testWidgets(
    'Library podcast removal also clears Downloads and cached audio',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final directory = Directory.systemTemp.createTempSync(
        'meow-library-podcast-remove-',
      );
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final media = File('${directory.path}/podcasts/podcast-job/episode.mp3');
      media.parent.createSync(recursive: true);
      media.writeAsBytesSync(const [1, 2, 3]);
      final now = DateTime.now().toUtc();
      final jobs = _Jobs([
        TranscriptionJob(
          id: 'podcast-job',
          batchId: 'batch',
          sourcePath: media.path,
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          displayTitle: 'Shared podcast episode',
          sourceOrigin: JobSourceOrigin.podcast,
          podcastProvenance: const PodcastEpisodeProvenance(
            feedUrl: 'https://feeds.example/show',
            episodeId: 'episode-id',
            enclosureUrl: 'https://cdn.example/episode.mp3',
            showTitle: 'The Daily',
            episodeTitle: 'Shared podcast episode',
          ),
        ),
      ]);
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: _Settings(),
        jobRepository: jobs,
        libraryCatalogRepository: _Catalog(),
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: LibraryPage()),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('library-item-menu-podcast-job')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();
      expect(find.text('Remove podcast item?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-remove-library-jobs')));
      await tester.pumpAndSettle();

      expect(controller.allJobs, isEmpty);
      expect(controller.podcastJobs, isEmpty);
      expect(jobs.saved, isEmpty);
      expect(find.text('Shared podcast episode'), findsNothing);
    },
  );

  testWidgets('Removing a single transcript asks for confirmation first', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final jobs = _Jobs([
      TranscriptionJob(
        id: 'meeting',
        batchId: 'batch',
        sourcePath: '/recordings/meeting.wav',
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        displayTitle: 'Weekly meeting',
      ),
    ]);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      libraryCatalogRepository: _Catalog(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    final context = tester.element(find.byType(LibraryPage));
    final localizations = MaterialLocalizations.of(context);
    final summary = tester
        .widget<Text>(
          find.byKey(const ValueKey('library-item-summary-meeting')),
        )
        .data!;
    expect(summary, contains(localizations.formatShortDate(now.toLocal())));
    expect(summary, isNot(contains(now.toLocal().toString().substring(0, 10))));

    await tester.tap(find.byKey(const ValueKey('library-item-menu-meeting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();
    expect(find.text('Remove selected items?'), findsOneWidget);
    expect(controller.allJobs, hasLength(1));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Remove selected items?'), findsNothing);
    expect(controller.allJobs, hasLength(1));
    expect(find.text('Weekly meeting'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-item-menu-meeting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-remove-library-jobs')));
    await tester.pumpAndSettle();
    expect(controller.allJobs, isEmpty);
    expect(jobs.saved, isEmpty);
    expect(find.text('Weekly meeting'), findsNothing);
  });

  testWidgets('Changing the visible search scope clears hidden selections', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        for (final id in ['one', 'two'])
          TranscriptionJob(
            id: id,
            batchId: 'batch',
            sourcePath: '/recordings/$id.wav',
            createdAt: now,
            updatedAt: now,
            status: JobStatus.completed,
          ),
      ]),
      libraryCatalogRepository: _Catalog(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('toggle-library-selection')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('select-library-item-one')));
    await tester.enterText(find.byKey(const Key('library-search')), 'two');
    await tester.pump();

    expect(find.text('0 selected'), findsOneWidget);
    expect(find.text('one.wav'), findsNothing);
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('select-library-item-two')),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('Search matches group and tag names as well as item titles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().toUtc();
    final catalog = _Catalog()
      ..value = const LibraryCatalog(
        groups: [LibraryGroup(id: 'group-work', name: 'Client Work')],
        tags: [LibraryTag(id: 'tag-important', name: 'Important')],
      );
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([
        TranscriptionJob(
          id: 'meeting',
          batchId: 'batch',
          sourcePath: '/recordings/meeting.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
          groupId: 'group-work',
          tagIds: const {'tag-important'},
        ),
        TranscriptionJob(
          id: 'other',
          batchId: 'batch',
          sourcePath: '/recordings/other.wav',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.completed,
        ),
      ]),
      libraryCatalogRepository: catalog,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('library-search')),
      'Client Work',
    );
    await tester.pump();
    expect(find.text('meeting.wav'), findsOneWidget);
    expect(find.text('other.wav'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('library-search')),
      'Important',
    );
    await tester.pump();
    expect(find.text('meeting.wav'), findsOneWidget);
  });
}

class _Credentials implements CredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => null;

  @override
  Future<void> writeApiKey(String key) async {}
}

class _Settings implements SettingsRepository {
  @override
  Future<AppSettings> load() async => const AppSettings();

  @override
  Future<void> save(AppSettings settings) async {}
}

class _Jobs implements JobRepository {
  _Jobs(Iterable<TranscriptionJob> initial) {
    for (final job in initial) {
      saved[job.id] = job;
    }
  }

  final Map<String, TranscriptionJob> saved = {};

  @override
  Future<void> delete(String id) async => saved.remove(id);

  @override
  Future<List<TranscriptionJob>> loadAll() async => saved.values.toList();

  @override
  Future<void> save(TranscriptionJob job) async => saved[job.id] = job;
}

class _Catalog implements LibraryCatalogRepository {
  LibraryCatalog value = const LibraryCatalog();

  @override
  Future<LibraryCatalog> load() async => value;

  @override
  Future<void> save(LibraryCatalog catalog) async => value = catalog;
}

class _Media implements MediaService {
  @override
  bool canUploadDirectly(
    String path,
    MediaMetadata metadata, {
    MediaUploadProfile profile = MediaUploadProfile.standard,
  }) => true;

  @override
  Future<void> deleteTemporary(String path) async {}

  @override
  Future<void> deleteGeneratedMedia(String cacheKey) async {}

  @override
  Future<void> clearGeneratedMediaExcept(Set<String> retainedCacheKeys) async {}

  @override
  Future<MediaDiagnostics> diagnostics() async =>
      const MediaDiagnostics(available: true);

  @override
  Future<String> extractAudio(
    String sourcePath,
    String jobId, {
    required int durationMs,
    MediaUploadProfile profile = MediaUploadProfile.standard,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => sourcePath;

  @override
  Future<MediaMetadata> inspect(String sourcePath) async => const MediaMetadata(
    sizeBytes: 1,
    durationMs: 1000,
    hasAudio: true,
    hasVideo: false,
    formatName: 'wav',
  );

  @override
  Future<String> renderWaveform(String sourcePath, String cacheKey) async => '';
}

class _Soniox implements SonioxClient {
  int uploadCalls = 0;

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async => 'tx';

  @override
  Future<void> deleteFile(String id) async {}

  @override
  Future<void> deleteTranscription(String id) async {}

  @override
  Future<Map<String, dynamic>> getTranscript(String id) async => {};

  @override
  Future<SonioxTranscriptionState> getTranscription(String id) async =>
      const SonioxTranscriptionState(status: 'completed');

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    uploadCalls++;
    return 'file';
  }

  @override
  Future<void> validateKey({String? apiKey}) async {}
}
