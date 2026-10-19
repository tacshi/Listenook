import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/ui/podcast_media_export.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('completePodcastMediaExport shows success after a copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: [AppStrings.delegate],
        home: Scaffold(body: SizedBox.expand()),
      ),
    );

    final context = tester.element(find.byType(Scaffold));
    await completePodcastMediaExport(context, () async => '/tmp/out.mp3');
    await tester.pump();

    expect(find.text('Downloaded audio exported'), findsOneWidget);
  });

  testWidgets('completePodcastMediaExport shows a failure snackbar', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: [AppStrings.delegate],
        home: Scaffold(body: SizedBox.expand()),
      ),
    );

    final context = tester.element(find.byType(Scaffold));
    await completePodcastMediaExport(context, () async {
      throw const FileSystemException('Podcast media is missing.');
    });
    await tester.pump();

    expect(find.text('Could not export the downloaded audio.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completePodcastMediaBatchExport reports the exported count', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: [AppStrings.delegate],
        home: Scaffold(body: SizedBox.expand()),
      ),
    );

    final context = tester.element(find.byType(Scaffold));
    await completePodcastMediaBatchExport(context, () async => 2);
    await tester.pump();

    expect(find.text('2 downloaded episodes exported'), findsOneWidget);
  });

  test('batch export keeps every file when names collide', () async {
    final directory = Directory.systemTemp.createTempSync(
      'meow-podcast-export-',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    File('${directory.path}/episode.mp3').writeAsBytesSync(const [1]);
    final now = DateTime.now().toUtc();
    final jobs = [
      for (final id in ['one', 'two'])
        TranscriptionJob(
          id: id,
          batchId: 'batch',
          sourcePath: '/downloads/$id/episode.mp3',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
          sourceOrigin: JobSourceOrigin.podcast,
        ),
    ];

    final destinations = await exportPodcastMediaFilesToDirectory(
      jobs,
      directory.path,
      (job, destination) async => destination,
    );

    expect(destinations.map(p.basename), [
      'episode (2).mp3',
      'episode (3).mp3',
    ]);
  });
}
