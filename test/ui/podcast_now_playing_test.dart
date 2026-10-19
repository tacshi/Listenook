import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/core/podcast_models.dart';
import 'package:listenook/data/local_media_source_resolver.dart';
import 'package:listenook/data/podcast/http_podcast_gateway.dart';
import 'package:listenook/data/podcast/podcast_formatters.dart';
import 'package:listenook/data/transcript_exporter.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/state/app_controller.dart';
import 'package:listenook/state/podcast_controller.dart';
import 'package:listenook/state/podcast_player.dart';
import 'package:listenook/ui/podcast_episode_description.dart';
import 'package:listenook/ui/podcast_mini_bar.dart';
import 'package:listenook/ui/podcast_now_playing.dart';
import 'package:listenook/ui/podcast_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('mini player speed button lists and applies playback rates', (
    tester,
  ) async {
    var rate = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PodcastMiniSpeedButton(
              rate: rate,
              onChanged: (value) => setState(() => rate = value),
            ),
          ),
        ),
      ),
    );

    expect(find.text('1×'), findsOneWidget);
    expect(
      tester
          .widget<PopupMenuButton<double>>(
            find.byKey(const Key('podcast-mini-speed')),
          )
          .tooltip,
      'Playback speed',
    );

    await tester.tap(find.byKey(const Key('podcast-mini-speed')));
    await tester.pumpAndSettle();
    expect(
      find.byType(CheckedPopupMenuItem<double>),
      findsNWidgets(PodcastPlayer.rates.length),
    );

    await tester.tap(find.byKey(const ValueKey('podcast-mini-speed-150')));
    await tester.pumpAndSettle();
    expect(find.text('1.5×'), findsOneWidget);
  });

  testWidgets('episode description renders HTML and only opens safe links', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PodcastEpisodeDescription(
            description:
                '<p><strong>Sponsors:</strong> <a href="https://example.com">Deals</a></p>',
            openLink: (uri) async => opened.add(uri),
          ),
        ),
      ),
    );

    final html = tester.widget<HtmlWidget>(
      find.byKey(const Key('podcast-episode-description-html')),
    );
    expect(html.html, contains('<strong>Sponsors:</strong>'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Deals', findRichText: true), findsOneWidget);

    expect(await html.onTapUrl?.call('javascript:alert(1)'), isTrue);
    expect(await html.onTapUrl?.call('https://example.com'), isTrue);
    await tester.pump();

    expect(opened, [Uri.parse('https://example.com')]);
  });

  testWidgets('speed control steps, lists rates, and disables the ends', (
    tester,
  ) async {
    var rate = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PodcastSpeedControl(
              rate: rate,
              onChanged: (value) => setState(() => rate = value),
            ),
          ),
        ),
      ),
    );

    expect(find.text('1×'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('podcast-now-playing-slower')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('podcast-now-playing-faster')),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('podcast-now-playing-faster')));
    await tester.pumpAndSettle();
    expect(find.text('1.25×'), findsOneWidget);

    await tester.tap(find.byKey(const Key('podcast-now-playing-slower')));
    await tester.pumpAndSettle();
    expect(find.text('1×'), findsOneWidget);

    await tester.tap(find.byKey(const Key('podcast-now-playing-speed')));
    await tester.pumpAndSettle();
    final items = tester
        .widgetList<CheckedPopupMenuItem<double>>(
          find.byType(CheckedPopupMenuItem<double>),
        )
        .toList();
    expect(items, hasLength(PodcastPlayer.rates.length));
    expect(items.where((item) => item.checked).single.value, 1);

    await tester.tap(find.byKey(const ValueKey('podcast-speed-150')));
    await tester.pumpAndSettle();
    expect(find.text('1.5×'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: const Scaffold(
          body: PodcastSpeedControl(rate: 0.5, onChanged: _ignore),
        ),
      ),
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('podcast-now-playing-slower')),
          )
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: const Scaffold(
          body: PodcastSpeedControl(rate: 2, onChanged: _ignore),
        ),
      ),
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('podcast-now-playing-faster')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('seek bar puts times on the sides and seeks from a click', (
    tester,
  ) async {
    var position = Duration.zero;
    const duration = Duration(minutes: 4);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 480,
              child: StatefulBuilder(
                builder: (context, setState) => PodcastSeekBar(
                  position: position,
                  duration: duration,
                  onSeek: (value) => setState(() => position = value),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final positionLabel = tester.getTopLeft(
      find.byKey(const Key('podcast-now-playing-position')),
    );
    final seekBar = tester.getRect(
      find.byKey(const Key('podcast-now-playing-seek')),
    );
    final durationLabel = tester.getTopLeft(
      find.byKey(const Key('podcast-now-playing-duration')),
    );
    expect(find.text('00:00'), findsOneWidget);
    expect(find.text('04:00'), findsOneWidget);
    expect(positionLabel.dx, lessThan(seekBar.left));
    expect(durationLabel.dx, greaterThan(seekBar.right));

    await tester.tapAt(
      Offset(seekBar.left + seekBar.width * 0.25, seekBar.center.dy),
    );
    await tester.pumpAndSettle();
    expect(position.inSeconds, closeTo(60, 2));
    expect(find.text('01:00'), findsOneWidget);
    expect(find.text('04:00'), findsOneWidget);
  });

  testWidgets('compact seek bar keeps times beside a clickable track', (
    tester,
  ) async {
    var position = Duration.zero;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 480,
              child: StatefulBuilder(
                builder: (context, setState) => PodcastSeekBar(
                  position: position,
                  duration: const Duration(minutes: 10),
                  compact: true,
                  positionKey: const Key('podcast-mini-position'),
                  durationKey: const Key('podcast-mini-duration'),
                  seekKey: const Key('podcast-mini-seek'),
                  onSeek: (value) => setState(() => position = value),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('00:00'), findsOneWidget);
    expect(find.text('10:00'), findsOneWidget);
    final seekBar = tester.getRect(find.byKey(const Key('podcast-mini-seek')));
    expect(
      tester.getTopLeft(find.byKey(const Key('podcast-mini-position'))).dx,
      lessThan(seekBar.left),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('podcast-mini-duration'))).dx,
      greaterThan(seekBar.right),
    );

    await tester.tapAt(
      Offset(seekBar.left + seekBar.width * 0.5, seekBar.center.dy),
    );
    await tester.pumpAndSettle();
    expect(position.inSeconds, closeTo(300, 3));
  });

  test('formatPodcastRate trims trailing zeros', () {
    expect(formatPodcastRate(1), '1×');
    expect(formatPodcastRate(0.5), '0.5×');
    expect(formatPodcastRate(1.25), '1.25×');
  });

  test('formatEpisodeLength uses compact hour-minute labels', () {
    expect(formatEpisodeLength(null, chinese: false), isNull);
    expect(formatEpisodeLength(0, chinese: false), isNull);
    expect(
      formatEpisodeLength(
        const Duration(hours: 2, minutes: 36).inMilliseconds,
        chinese: false,
      ),
      '2h 36m',
    );
    expect(
      formatEpisodeLength(
        const Duration(minutes: 45).inMilliseconds,
        chinese: false,
      ),
      '45m',
    );
    expect(
      formatEpisodeLength(
        const Duration(hours: 1).inMilliseconds,
        chinese: false,
      ),
      '1h',
    );
    expect(formatEpisodeLength(32000, chinese: false), '32s');
    expect(
      formatEpisodeLength(
        const Duration(hours: 2, minutes: 36).inMilliseconds,
        chinese: true,
      ),
      '2小时36分',
    );
    expect(
      formatEpisodeLength(
        const Duration(minutes: 45).inMilliseconds,
        chinese: true,
      ),
      '45分钟',
    );
  });

  test('cueIndexAt follows the last cue that has started', () {
    const cues = [
      PodcastPlayerCue(startMs: 0, endMs: 0, text: 'Ad'),
      PodcastPlayerCue(startMs: 1000, endMs: 2500, text: 'Intro'),
      PodcastPlayerCue(startMs: 2500, endMs: 4000, text: 'Story'),
    ];
    expect(PodcastPlayer.cueIndexAt(cues, 0), 0);
    expect(PodcastPlayer.cueIndexAt(cues, 999), 0);
    expect(PodcastPlayer.cueIndexAt(cues, 1000), 1);
    expect(PodcastPlayer.cueIndexAt(cues, 2600), 2);
    expect(PodcastPlayer.cueIndexAt(cues, -1), -1);
  });

  test('applyDocument attaches a completed transcript to the player', () {
    final player = PodcastPlayer();
    addTearDown(player.dispose);
    final document = TranscriptDocument(
      tokens: const [],
      speakers: const [],
      updatedAt: DateTime.utc(2026, 8, 15),
      segments: const [
        TranscriptSegment(
          id: 's1',
          startMs: 0,
          endMs: 1200,
          text: 'Hello from The Daily.',
        ),
      ],
    );

    player.applyDocument(document);
    expect(player.cues, hasLength(1));
    expect(player.cues.single.text, 'Hello from The Daily.');
    expect(player.cues.single.tokens, isEmpty);

    player.applyDocument(document);
    expect(player.cues, hasLength(1));
  });

  test('applyDocument maps word tokens onto the matching cue', () {
    final player = PodcastPlayer();
    addTearDown(player.dispose);
    player.applyDocument(
      TranscriptDocument(
        tokens: const [
          TranscriptToken(text: 'Hello', startMs: 0, endMs: 300),
          TranscriptToken(text: ' there', startMs: 300, endMs: 700),
          TranscriptToken(text: 'Later', startMs: 2000, endMs: 2400),
        ],
        speakers: const [],
        updatedAt: DateTime.utc(2026, 8, 15),
        segments: const [
          TranscriptSegment(
            id: 's1',
            startMs: 0,
            endMs: 1200,
            text: 'Hello there',
          ),
          TranscriptSegment(
            id: 's2',
            startMs: 2000,
            endMs: 2800,
            text: 'Later',
          ),
        ],
      ),
    );
    expect(player.cues.first.tokens.map((token) => token.text), [
      'Hello',
      ' there',
    ]);
    expect(player.cues.last.tokens.single.text, 'Later');
  });

  test('listen progress becomes continue after a few seconds', () {
    const early = PodcastListenProgress(positionMs: 1000, durationMs: 3600000);
    const mid = PodcastListenProgress(positionMs: 900000, durationMs: 3600000);
    const done = PodcastListenProgress(
      positionMs: 3598000,
      durationMs: 3600000,
    );
    expect(early.isContinue, isFalse);
    expect(mid.isContinue, isTrue);
    expect(mid.remainingMs, 2700000);
    expect(done.isContinue, isFalse);
  });

  testWidgets('episode row actions stay hidden until hover', (tester) async {
    final episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-1',
      feedUrl: 'https://feeds.example/show',
      title: 'Episode One',
      enclosureUrl: 'https://cdn.example/one.mp3',
      mediaExtension: 'mp3',
      description: 'Notes',
    );
    final feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'The Daily',
      episodes: [episode],
    );
    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(feeds: {feed.feedUrl: feed}),
      repository: _MemoryPodcastRepo(),
    );
    addTearDown(podcast.dispose);
    await podcast.initialize();
    await podcast.openFeed(feed.feedUrl);

    final app = AppController(
      credentialStore: _EmptyCredentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(app.dispose);
    await app.initialize();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: podcast),
          ChangeNotifierProvider.value(value: app),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [
            AppStrings.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: Scaffold(body: PodcastPage()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(ValueKey('deep-listen-${episode.id}')), findsOneWidget);
    expect(
      tester
          .widget<Visibility>(
            find.byKey(ValueKey('episode-actions-${episode.id}')),
          )
          .visible,
      isFalse,
    );
    expect(find.byKey(ValueKey('preview-${episode.id}')), findsOneWidget);
    final titleSize = tester.getSize(find.text('Episode One'));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(ValueKey('episode-${episode.id}'))),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Visibility>(
            find.byKey(ValueKey('episode-actions-${episode.id}')),
          )
          .visible,
      isTrue,
    );
    expect(tester.getSize(find.text('Episode One')), titleSize);
  });

  testWidgets('Deep listen stays labeled and disabled while downloading', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'meow-podcast-downloading-',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final gateway = _DeferredDownloadGateway();
    addTearDown(gateway.release);
    const episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-downloading',
      feedUrl: 'https://feeds.example/show',
      title: 'Episode downloading',
      enclosureUrl: 'https://cdn.example/downloading.mp3',
      mediaExtension: 'mp3',
      description: 'Episode details',
    );
    const feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'The Daily',
      episodes: [episode],
    );
    gateway.feeds = {feed.feedUrl: feed};
    gateway.enclosures = {
      episode.enclosureUrl: [1, 2, 3],
    };

    final podcast = PodcastController(
      gateway: gateway,
      repository: _MemoryPodcastRepo(),
    );
    addTearDown(podcast.dispose);
    await podcast.initialize();
    await podcast.openFeed(feed.feedUrl);

    final app = AppController(
      credentialStore: _EmptyCredentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      podcastGateway: gateway,
      podcastManagedRoot: directory.path,
    );
    addTearDown(app.dispose);
    await app.initialize();
    await app.enqueuePodcastEpisode(episode, feed: feed);
    expect(app.jobForEpisode(episode.id)?.status, JobStatus.downloading);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: podcast),
          ChangeNotifierProvider.value(value: app),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: PodcastPage()),
        ),
      ),
    );
    await tester.pump();

    final listAction = find.byKey(ValueKey('deep-listen-${episode.id}'));
    expect(tester.widget<FilledButton>(listAction).onPressed, isNull);
    expect(
      find.descendant(of: listAction, matching: find.text('Deep listen')),
      findsOneWidget,
    );

    podcast.openEpisode(episode);
    await tester.pump();
    final detailAction = find.byKey(
      ValueKey('deep-listen-detail-${episode.id}'),
    );
    expect(tester.widget<IconButton>(detailAction).onPressed, isNull);
    expect(
      find.descendant(
        of: detailAction,
        matching: find.byIcon(Icons.auto_stories_rounded),
      ),
      findsOneWidget,
    );

    podcast.closeOpenedEpisode();
    podcast.closeOpenedFeed();
    podcast.setPane(PodcastPane.library);
    await tester.pump();
    final libraryAction = find.byKey(
      ValueKey('library-deep-listen-${episode.id}'),
    );
    expect(tester.widget<FilledButton>(libraryAction).onPressed, isNull);
    expect(
      find.descendant(of: libraryAction, matching: find.text('Deep listen')),
      findsOneWidget,
    );
  });

  testWidgets('episode detail actions share one visual centerline', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync(
      'meow-podcast-detail-actions-',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    const episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-actions',
      feedUrl: 'https://feeds.example/show',
      title: 'Episode actions',
      enclosureUrl: 'https://cdn.example/actions.mp3',
      mediaExtension: 'mp3',
      description: 'Episode details',
    );
    const feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'The Daily',
      episodes: [episode],
    );
    final gateway = MemoryPodcastGateway(
      feeds: {feed.feedUrl: feed},
      enclosures: {
        episode.enclosureUrl: [1, 2, 3],
      },
    );
    final podcast = PodcastController(
      gateway: gateway,
      repository: _MemoryPodcastRepo(),
    );
    addTearDown(podcast.dispose);
    await podcast.initialize();
    await podcast.openFeed(feed.feedUrl);

    final now = DateTime.now().toUtc();
    final sourcePath = '${directory.path}/episode.mp3';
    File(sourcePath).writeAsBytesSync(const [1, 2, 3]);
    final job = TranscriptionJob(
      id: 'detail-actions-job',
      batchId: 'detail-actions-batch',
      sourcePath: sourcePath,
      createdAt: now,
      updatedAt: now,
      status: JobStatus.ready,
      sourceOrigin: JobSourceOrigin.podcast,
      podcastProvenance: const PodcastEpisodeProvenance(
        feedUrl: 'https://feeds.example/show',
        episodeId: 'https://feeds.example/show\nguid-actions',
        enclosureUrl: 'https://cdn.example/actions.mp3',
        showTitle: 'The Daily',
        episodeTitle: 'Episode actions',
      ),
    );
    final app = AppController(
      credentialStore: _EmptyCredentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs([job]),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      podcastGateway: gateway,
      podcastManagedRoot: directory.path,
    );
    addTearDown(app.dispose);
    await app.initialize();
    podcast.openEpisode(episode);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: podcast),
          ChangeNotifierProvider.value(value: app),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: PodcastPage()),
        ),
      ),
    );
    await tester.pump();

    final download = find.byKey(ValueKey('episode-download-${episode.id}'));
    final export = find.byKey(
      ValueKey('episode-detail-export-media-${episode.id}'),
    );
    expect(download, findsOneWidget);
    expect(export, findsOneWidget);
    expect(
      tester.getCenter(download).dy,
      closeTo(tester.getCenter(export).dy, 1),
    );
  });

  testWidgets(
    'caption pane does not spin when a completed job has no cues yet',
    (tester) async {
      final player = PodcastPlayer();
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [AppStrings.delegate],
          home: Scaffold(
            body: PodcastCaptionPane(
              player: player,
              hasCompletedTranscript: true,
            ),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('no captions'), findsOneWidget);
    },
  );

  testWidgets('caption pane shows a saved transcript when playback is idle', (
    tester,
  ) async {
    final player = PodcastPlayer();
    addTearDown(player.dispose);
    final document = TranscriptDocument(
      tokens: const [],
      speakers: const [],
      updatedAt: DateTime.utc(2026, 8, 15),
      segments: const [
        TranscriptSegment(
          id: 's1',
          startMs: 0,
          endMs: 2000,
          text: 'She did not earn endorsements.',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: Scaffold(
          body: PodcastCaptionPane(
            player: player,
            document: document,
            episodeId: 'ep-1',
            hasCompletedTranscript: true,
            compact: true,
          ),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('She did not earn endorsements.'), findsOneWidget);
  });

  testWidgets('download button shows hover tooltip and idle icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: Scaffold(
          body: EpisodeDownloadButton(
            episodeId: 'ep-1',
            tooltip: 'Download',
            onPressed: () {},
          ),
        ),
      ),
    );

    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('episode-download-ep-1')),
    );
    expect(button.tooltip, 'Download');
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EpisodeDownloadButton(
            episodeId: 'ep-1',
            tooltip: 'Downloaded',
            done: true,
            onPressed: null,
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('episode-download-ep-1')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('continue play pill shows a progress bar and remaining time', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [AppStrings.delegate],
        home: Scaffold(
          body: EpisodePlayButton(
            episodeId: 'ep-1',
            playing: false,
            progress: 0.25,
            durationLabel: '2h 34m',
            tooltip: 'Continue',
            onPressed: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('episode-continue-progress')), findsOneWidget);
    expect(find.text('2h 34m'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });

  testWidgets('show artwork stays square when the header row stretches', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PodcastArtwork(key: Key('show-cover'), url: null, size: 88),
              ],
            ),
          ),
        ),
      ),
    );

    final image = tester.getSize(
      find.descendant(
        of: find.byKey(const Key('show-cover')),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(image.width, 88);
    expect(image.height, 88);
  });

  testWidgets('root tabs hide on a show page and include Downloads', (
    tester,
  ) async {
    final feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'The Daily',
      artworkUrl: 'https://cdn.example/daily.jpg',
      episodes: const [],
    );
    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(feeds: {feed.feedUrl: feed}),
      repository: _MemoryPodcastRepo(),
    );
    addTearDown(podcast.dispose);
    await podcast.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: podcast,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: PodcastPage()),
        ),
      ),
    );
    await tester.pump();

    final pagePadding = tester.widget<Padding>(
      find.byKey(const Key('podcast-page-padding')),
    );
    expect((pagePadding.padding as EdgeInsets).bottom, 0);
    expect(find.byKey(const Key('podcast-root-tabs')), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);

    await podcast.openFeed(feed.feedUrl);
    await tester.pump();

    expect(find.byKey(const Key('podcast-root-tabs')), findsNothing);
    expect(find.byKey(const Key('podcast-back')), findsOneWidget);
    expect(find.text('The Daily'), findsOneWidget);
  });

  testWidgets('podcast search exposes a clear button when it has text', (
    tester,
  ) async {
    final gateway = MemoryPodcastGateway(
      shows: const [
        PodcastShowSummary(
          id: 'joe-show',
          title: 'The Joe Show',
          feedUrl: 'https://feeds.example/joe',
        ),
      ],
    );
    final podcast = PodcastController(
      gateway: gateway,
      repository: _MemoryPodcastRepo(),
    );
    addTearDown(podcast.dispose);
    await podcast.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: podcast,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: PodcastPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final search = find.byKey(const Key('podcast-search-field'));
    final feed = find.byKey(const Key('podcast-feed-field'));
    expect(
      tester.getSize(search).width,
      closeTo(tester.getSize(feed).width, 1),
    );
    expect(find.byKey(const Key('podcast-search-clear')), findsNothing);

    await tester.enterText(search, 'joe');
    await tester.pump();

    final clear = find.byKey(const Key('podcast-search-clear'));
    expect(clear, findsOneWidget);
    expect(find.byTooltip('Clear search'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(podcast.query, 'joe');
    expect(find.byKey(const ValueKey('show-joe-show')), findsOneWidget);

    await tester.tap(clear);
    await tester.pump();

    expect(podcast.query, isEmpty);
    expect(podcast.results, isEmpty);
    expect(tester.widget<TextField>(search).controller?.text, isEmpty);
    expect(find.byKey(const Key('podcast-search-clear')), findsNothing);
  });

  testWidgets('RSS input exposes a clear button when it has text', (
    tester,
  ) async {
    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(),
      repository: _MemoryPodcastRepo(),
    );
    addTearDown(podcast.dispose);
    await podcast.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: podcast,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: PodcastPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final feed = find.byKey(const Key('podcast-feed-field'));
    expect(find.byKey(const Key('podcast-feed-clear')), findsNothing);
    expect(find.byKey(const Key('podcast-feed-add')), findsOneWidget);

    await tester.enterText(feed, 'https://feeds.example/show.xml');
    await tester.pump();

    final clear = find.byKey(const Key('podcast-feed-clear'));
    expect(clear, findsOneWidget);
    expect(find.byTooltip('Clear RSS URL'), findsOneWidget);
    expect(find.byKey(const Key('podcast-feed-add')), findsOneWidget);

    await tester.tap(clear);
    await tester.pump();

    expect(tester.widget<TextField>(feed).controller?.text, isEmpty);
    expect(find.byKey(const Key('podcast-feed-clear')), findsNothing);
  });

  testWidgets('clicking an unavailable browse show does not report RSS input', (
    tester,
  ) async {
    final podcast = PodcastController(
      gateway: _MissingFeedBrowseGateway(),
      repository: _MemoryPodcastRepo(),
    );
    addTearDown(podcast.dispose);
    await podcast.initialize();
    await podcast.loadBrowse(force: true);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: podcast,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: PodcastPage()),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('browse-show-missing-feed')));
    await tester.pump();

    expect(
      find.text('Could not open this podcast. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Enter a public HTTP or HTTPS feed URL.'), findsNothing);
  });

  testWidgets('Downloads toolbar selects episodes for batch export', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync(
      'meow-podcast-library-',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final now = DateTime.now().toUtc();
    final jobs = [
      for (final id in ['one', 'two'])
        TranscriptionJob(
          id: id,
          batchId: 'batch',
          sourcePath: '${directory.path}/$id.mp3',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
          sourceOrigin: JobSourceOrigin.podcast,
        ),
    ];
    for (final job in jobs) {
      File(job.sourcePath).writeAsBytesSync(const [1, 2, 3]);
    }

    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(),
      repository: _MemoryPodcastRepo(),
    );
    addTearDown(podcast.dispose);
    await podcast.initialize();
    podcast.setPane(PodcastPane.library);

    final app = AppController(
      credentialStore: _EmptyCredentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(jobs),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(app.dispose);
    await app.initialize();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: podcast),
          ChangeNotifierProvider.value(value: app),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: PodcastPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('podcast-library-toolbar')), findsOneWidget);
    expect(
      find.byKey(const Key('toggle-podcast-library-selection')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.save_alt_rounded), findsNothing);
    for (final id in ['one', 'two']) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('library-export-media-$id')),
          matching: find.byIcon(Icons.ios_share_rounded),
        ),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('podcast-library-menu-$id')), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('toggle-podcast-library-selection')));
    await tester.pump();

    expect(find.byKey(const Key('batch-export-podcast-media')), findsOneWidget);
    final batchRemove = find.byKey(const Key('batch-remove-podcast-jobs'));
    expect(batchRemove, findsOneWidget);
    expect(tester.widget<IconButton>(batchRemove).onPressed, isNull);
    for (final id in ['one', 'two']) {
      expect(
        find.byKey(ValueKey('select-podcast-library-job-$id')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('podcast-library-menu-$id')), findsNothing);
    }
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('batch-export-podcast-media')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('podcast-library-select-all')));
    await tester.pump();

    expect(find.text('2 selected'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('batch-export-podcast-media')),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.widget<IconButton>(batchRemove).onPressed, isNotNull);
    for (final id in ['one', 'two']) {
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(ValueKey('select-podcast-library-job-$id')),
            )
            .value,
        isTrue,
      );
    }
  });

  testWidgets(
    'Downloads removal confirms, stops playback, and removes the shared item',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final directory = Directory.systemTemp.createTempSync(
        'meow-podcast-remove-',
      );
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      const episode = PodcastEpisode(
        id: 'https://feeds.example/show\nguid-remove',
        feedUrl: 'https://feeds.example/show',
        title: 'Episode to remove',
        enclosureUrl: 'https://cdn.example/remove.mp3',
        mediaExtension: 'mp3',
      );
      const feed = PodcastFeed(
        feedUrl: 'https://feeds.example/show',
        title: 'The Daily',
        episodes: [episode],
      );
      final media = File('${directory.path}/podcasts/job-remove/episode.mp3');
      media.parent.createSync(recursive: true);
      media.writeAsBytesSync(const [1, 2, 3]);
      final now = DateTime.now().toUtc();
      final job = TranscriptionJob(
        id: 'job-remove',
        batchId: 'batch',
        sourcePath: media.path,
        createdAt: now,
        updatedAt: now,
        status: JobStatus.completed,
        sourceOrigin: JobSourceOrigin.podcast,
        podcastProvenance: const PodcastEpisodeProvenance(
          feedUrl: 'https://feeds.example/show',
          episodeId: 'https://feeds.example/show\nguid-remove',
          enclosureUrl: 'https://cdn.example/remove.mp3',
          showTitle: 'The Daily',
          episodeTitle: 'Episode to remove',
        ),
        document: TranscriptDocument(
          tokens: const [],
          segments: const [],
          speakers: const [],
          updatedAt: now,
        ),
      );
      final repository = _MemoryPodcastRepo()
        ..value = PodcastLibraryState(
          followed: [
            FollowedPodcast(
              feedUrl: feed.feedUrl,
              title: feed.title,
              followedAt: now,
            ),
          ],
        );
      final player = _RemovalPodcastPlayer(episode, positionMs: 42000);
      addTearDown(player.dispose);
      final podcast = PodcastController(
        gateway: MemoryPodcastGateway(feeds: {feed.feedUrl: feed}),
        repository: repository,
        player: player,
      );
      addTearDown(podcast.dispose);
      await podcast.initialize();
      podcast.setPane(PodcastPane.library);
      final app = AppController(
        credentialStore: _EmptyCredentials(),
        settingsRepository: _Settings(),
        jobRepository: _Jobs([job]),
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
      );
      addTearDown(app.dispose);
      await app.initialize();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: podcast),
            ChangeNotifierProvider.value(value: app),
          ],
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: PodcastPage()),
          ),
        ),
      );
      await tester.pump();

      final menu = find.byKey(
        const ValueKey('podcast-library-menu-job-remove'),
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Remove podcast item?'), findsOneWidget);
      expect(find.textContaining('from Downloads and Library'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(app.allJobs, hasLength(1));
      expect(media.existsSync(), isTrue);
      expect(player.stopped, isFalse);

      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-remove-library-jobs')));
      await tester.pumpAndSettle();

      expect(player.stopped, isTrue);
      expect(player.storedPositionMs(episode.id), 42000);
      expect(podcast.followed, hasLength(1));
      expect(app.allJobs, isEmpty);
      expect(app.podcastJobs, isEmpty);
      expect(find.byKey(const Key('podcast-library-empty')), findsOneWidget);
    },
  );

  testWidgets('Downloads batch removal rejects mixed busy selections', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync(
      'meow-podcast-batch-remove-',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final now = DateTime.now().toUtc();
    final readyJobs = [
      for (final id in ['one', 'two'])
        TranscriptionJob(
          id: id,
          batchId: 'batch',
          sourcePath: '${directory.path}/fixtures/$id/$id.mp3',
          createdAt: now,
          updatedAt: now,
          status: JobStatus.ready,
          sourceOrigin: JobSourceOrigin.podcast,
        ),
    ];
    for (final job in readyJobs) {
      final file = File(job.sourcePath);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(const [1, 2, 3]);
    }
    const busyEpisode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-busy',
      feedUrl: 'https://feeds.example/show',
      title: 'Still downloading',
      enclosureUrl: 'https://cdn.example/busy.mp3',
      mediaExtension: 'mp3',
    );
    const feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'The Daily',
      episodes: [busyEpisode],
    );
    final gateway = _DeferredDownloadGateway()
      ..feeds = {feed.feedUrl: feed}
      ..enclosures = {
        busyEpisode.enclosureUrl: [1, 2, 3],
      };
    addTearDown(gateway.release);
    final podcast = PodcastController(
      gateway: gateway,
      repository: _MemoryPodcastRepo(),
    );
    addTearDown(podcast.dispose);
    await podcast.initialize();
    podcast.setPane(PodcastPane.library);
    final app = AppController(
      credentialStore: _EmptyCredentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(readyJobs),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      podcastGateway: gateway,
      podcastManagedRoot: '${directory.path}/managed',
    );
    addTearDown(app.dispose);
    await app.initialize();
    final busyJob = await app.enqueuePodcastEpisode(busyEpisode, feed: feed);
    expect(busyJob?.status, JobStatus.downloading);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: podcast),
          ChangeNotifierProvider.value(value: app),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: PodcastPage()),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('toggle-podcast-library-selection')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('podcast-library-select-all')));
    await tester.pump();
    final batchRemove = find.byKey(const Key('batch-remove-podcast-jobs'));
    expect(tester.widget<IconButton>(batchRemove).onPressed, isNull);

    await tester.tap(
      find.byKey(ValueKey('select-podcast-library-job-${busyJob!.id}')),
    );
    await tester.pump();
    expect(tester.widget<IconButton>(batchRemove).onPressed, isNotNull);

    await tester.tap(batchRemove);
    await tester.pumpAndSettle();
    expect(find.text('Remove selected podcast items?'), findsOneWidget);
    expect(find.textContaining('removes 2 episodes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-remove-library-jobs')));
    await tester.pumpAndSettle();

    expect(app.allJobs.map((job) => job.id), [busyJob.id]);
    gateway.release();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('switching from Downloads to Following keeps the follow list', (
    tester,
  ) async {
    final episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-1',
      feedUrl: 'https://feeds.example/show',
      title: 'Episode One',
      enclosureUrl: 'https://cdn.example/one.mp3',
      mediaExtension: 'mp3',
      description: 'Notes',
    );
    final feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'The Daily',
      author: 'The New York Times',
      artworkUrl: 'https://cdn.example/daily.jpg',
      episodes: [episode],
    );
    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(feeds: {feed.feedUrl: feed}),
      repository: _MemoryPodcastRepo(),
    );
    addTearDown(podcast.dispose);
    await podcast.initialize();
    await podcast.openFeed(feed.feedUrl);
    await podcast.followOpenedFeed();
    podcast.closeOpenedFeed();
    podcast.setPane(PodcastPane.library);

    final app = AppController(
      credentialStore: _EmptyCredentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(app.dispose);
    await app.initialize();

    FlutterError? caught;
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      caught ??= FlutterError(details.exceptionAsString());
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: podcast),
          ChangeNotifierProvider.value(value: app),
        ],
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [
            AppStrings.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: Scaffold(body: PodcastPage()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('podcast-library-empty')), findsOneWidget);
    expect(find.text('已关注 (1)'), findsOneWidget);

    await tester.tap(find.text('已关注 (1)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(caught, isNull);
    expect(find.byKey(const Key('podcast-root-tabs')), findsOneWidget);
    expect(find.text('The Daily'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('followed-https://feeds.example/show')),
      findsOneWidget,
    );
  });
}

class _MemoryPodcastRepo implements PodcastRepository {
  PodcastLibraryState value = const PodcastLibraryState();
  Map<String, PodcastListenProgress> playback = {};

  @override
  Future<PodcastLibraryState> load() async => value;

  @override
  Future<void> save(PodcastLibraryState state) async => value = state;

  @override
  Future<Map<String, PodcastListenProgress>> loadPlaybackProgress() async =>
      playback;

  @override
  Future<void> savePlaybackProgress(
    Map<String, PodcastListenProgress> progress,
  ) async => playback = Map.of(progress);
}

class _MissingFeedBrowseGateway extends MemoryPodcastGateway {
  static const show = PodcastShowSummary(
    id: 'missing-feed',
    title: 'Unavailable show',
  );

  @override
  Future<List<PodcastShowSummary>> lookupShows(
    Iterable<String> collectionIds,
  ) async => const [show];

  @override
  Future<List<PodcastShowSummary>> topShows({
    String country = 'us',
    int? genreId,
    int limit = 16,
    bool resolveFeeds = true,
  }) async => const [];
}

class _DeferredDownloadGateway extends MemoryPodcastGateway {
  final _release = Completer<void>();

  @override
  Future<void> downloadEpisode({
    required String enclosureUrl,
    required String destinationPath,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    await _release.future;
    await super.downloadEpisode(
      enclosureUrl: enclosureUrl,
      destinationPath: destinationPath,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

class _RemovalPodcastPlayer extends PodcastPlayer {
  _RemovalPodcastPlayer(this.currentEpisode, {required this.positionMs});

  PodcastEpisode? currentEpisode;
  final int positionMs;
  bool stopped = false;

  @override
  PodcastEpisode? get episode => currentEpisode;

  @override
  int storedPositionMs(String episodeId) => positionMs;

  @override
  Future<void> stop() async {
    stopped = true;
    currentEpisode = null;
  }
}

class _Jobs implements JobRepository {
  _Jobs([this.jobs = const []]);

  final List<TranscriptionJob> jobs;

  @override
  Future<void> delete(String id) async {}

  @override
  Future<List<TranscriptionJob>> loadAll() async => jobs;

  @override
  Future<void> save(TranscriptionJob job) async {}
}

class _Settings implements SettingsRepository {
  @override
  Future<AppSettings> load() async => const AppSettings();

  @override
  Future<void> save(AppSettings settings) async {}
}

class _EmptyCredentials implements CredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => null;

  @override
  Future<void> writeApiKey(String key) async {}
}

class _Media implements MediaService {
  @override
  bool canUploadDirectly(
    String path,
    MediaMetadata metadata, {
    MediaUploadProfile profile = MediaUploadProfile.standard,
  }) => true;

  @override
  Future<void> deleteGeneratedMedia(String cacheKey) async {}

  @override
  Future<void> deleteTemporary(String path) async {}

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
    sizeBytes: 4,
    durationMs: 1000,
    hasAudio: true,
    hasVideo: false,
    formatName: 'mp3',
  );

  @override
  Future<String> renderWaveform(String sourcePath, String cacheKey) async => '';
}

class _Soniox implements SonioxClient {
  @override
  Future<void> validateKey({String? apiKey}) async {}

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async => 'tx';

  @override
  Future<void> deleteFile(String fileId) async {}

  @override
  Future<void> deleteTranscription(String transcriptionId) async {}

  @override
  Future<Map<String, dynamic>> getTranscript(String transcriptionId) async =>
      const {'tokens': []};

  @override
  Future<SonioxTranscriptionState> getTranscription(
    String transcriptionId,
  ) async => const SonioxTranscriptionState(status: 'completed');

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => 'file';
}

void _ignore(double value) {}
