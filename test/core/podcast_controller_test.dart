import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/core/podcast_models.dart';
import 'package:listenook/data/local_media_source_resolver.dart';
import 'package:listenook/data/podcast/http_podcast_gateway.dart';
import 'package:listenook/data/transcript_exporter.dart';
import 'package:listenook/state/app_controller.dart';
import 'package:listenook/state/podcast_controller.dart';
import 'package:listenook/state/podcast_player.dart';

void main() {
  test('search, follow, and enqueue a podcast episode into Inbox', () async {
    final directory = await Directory.systemTemp.createTemp('meow-podcast-');
    addTearDown(() => directory.delete(recursive: true));
    final episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-1',
      feedUrl: 'https://feeds.example/show',
      title: 'Episode One',
      enclosureUrl: 'https://cdn.example/one.mp3',
      mediaExtension: 'mp3',
      guid: 'guid-1',
      description: 'A cached show-notes paragraph.',
      transcripts: const [
        PodcastTranscriptReference(
          url: 'https://cdn.example/one.vtt',
          type: 'text/vtt',
        ),
      ],
    );
    final feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'Study English',
      language: 'en-us',
      episodes: [episode],
    );
    final gateway = MemoryPodcastGateway(
      shows: const [
        PodcastShowSummary(
          id: '1',
          title: 'Study English',
          feedUrl: 'https://feeds.example/show',
        ),
      ],
      feeds: {'https://feeds.example/show': feed},
      transcripts: {
        'https://cdn.example/one.vtt':
            'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello.\n',
      },
      enclosures: {
        'https://cdn.example/one.mp3': [1, 2, 3, 4],
      },
    );
    final podcast = PodcastController(
      gateway: gateway,
      repository: _MemoryPodcastRepository(),
    );
    await podcast.initialize();
    await podcast.search('Study');
    expect(podcast.results.single.title, 'Study English');
    await podcast.openFeed('https://feeds.example/show');
    await podcast.followOpenedFeed();
    expect(podcast.followed, hasLength(1));

    await _waitFor(() => !podcast.browseLoading);
    expect(podcast.popular, isNotEmpty);

    final jobs = _Jobs();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      podcastGateway: gateway,
      podcastManagedRoot: directory.path,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.enqueuePodcastEpisode(episode, feed: feed);
    await _waitFor(
      () =>
          controller.inboxJobs.isNotEmpty &&
          controller.inboxJobs.single.status == JobStatus.ready,
    );

    final job = controller.inboxJobs.single;
    expect(job.sourceOrigin, JobSourceOrigin.podcast);
    expect(job.displayName, contains('Study English'));
    expect(
      job.transcriptAcquisitionMode,
      TranscriptAcquisitionMode.publisherCaptions,
    );
    expect(
      job.podcastProvenance?.transcriptTiming,
      PodcastTranscriptTiming.cue,
    );
    expect(File(job.sourcePath).existsSync(), isTrue);
    expect(job.sourcePath, contains('${directory.path}/podcasts/'));
    expect(controller.podcastJobs.single.id, job.id);
    expect(controller.localMediaPathForEpisode(episode.id), job.sourcePath);
    expect(job.podcastProvenance?.description, episode.description);
  });

  test(
    'deleting a podcast removes both projections and permits re-download',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-podcast-delete-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const episode = PodcastEpisode(
        id: 'https://feeds.example/show\nguid-delete',
        feedUrl: 'https://feeds.example/show',
        title: 'Delete and download again',
        enclosureUrl: 'https://cdn.example/delete.mp3',
        mediaExtension: 'mp3',
      );
      const feed = PodcastFeed(
        feedUrl: 'https://feeds.example/show',
        title: 'Study English',
        episodes: [episode],
      );
      final gateway = MemoryPodcastGateway(
        feeds: {feed.feedUrl: feed},
        enclosures: {
          episode.enclosureUrl: [1, 2, 3, 4],
        },
      );
      final jobs = _Jobs();
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: _Settings(),
        jobRepository: jobs,
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
        podcastGateway: gateway,
        podcastManagedRoot: directory.path,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.enqueuePodcastEpisode(episode, feed: feed);
      await _waitFor(
        () => controller.jobForEpisode(episode.id)?.status == JobStatus.ready,
      );
      final original = controller.jobForEpisode(episode.id)!;
      final originalPath = original.sourcePath;
      expect(controller.allJobs, hasLength(1));
      expect(controller.podcastJobs, hasLength(1));
      expect(File(originalPath).existsSync(), isTrue);

      await controller.deleteHistory(original.id);

      expect(controller.jobForEpisode(episode.id), isNull);
      expect(controller.allJobs, isEmpty);
      expect(controller.podcastJobs, isEmpty);
      expect(jobs.saved, isEmpty);
      expect(File(originalPath).existsSync(), isFalse);

      await controller.enqueuePodcastEpisode(episode, feed: feed);
      await _waitFor(
        () => controller.jobForEpisode(episode.id)?.status == JobStatus.ready,
      );
      final downloadedAgain = controller.jobForEpisode(episode.id)!;
      expect(downloadedAgain.id, isNot(original.id));
      expect(File(downloadedAgain.sourcePath).existsSync(), isTrue);
      expect(gateway.downloads, hasLength(2));
    },
  );

  test('untranscribed podcast cache files appear in Downloads', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meow-podcast-downloads-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const jobId = 'job-essentials';
    final media = File(
      '${directory.path}/podcasts/$jobId/Dr. Sa [d5bc464696].mp3',
    );
    await media.parent.create(recursive: true);
    await media.writeAsBytes(const [1, 2, 3, 4]);
    final now = DateTime.now().toUtc();
    final jobs = _Jobs();
    jobs.saved[jobId] = TranscriptionJob(
      id: jobId,
      batchId: 'batch',
      sourcePath: media.path,
      createdAt: now,
      updatedAt: now,
      status: JobStatus.ready,
      displayTitle:
          'Essentials How to Optimize Female Hormone Health for Vitality & Longevity',
      sourceOrigin: JobSourceOrigin.manual,
    );
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: jobs,
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      podcastManagedRoot: directory.path,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    expect(controller.podcastJobs, hasLength(1));
    expect(
      controller.podcastJobs.single.displayName,
      contains('Essentials How to Optimize'),
    );
    expect(controller.podcastJobs.single.status, JobStatus.ready);
  });

  test('root tabs hide on show, episode, and collection pages', () async {
    final episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-1',
      feedUrl: 'https://feeds.example/show',
      title: 'Episode One',
      enclosureUrl: 'https://cdn.example/one.mp3',
      mediaExtension: 'mp3',
    );
    final feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'The Daily',
      episodes: [episode],
    );
    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(feeds: {feed.feedUrl: feed}),
      repository: _MemoryPodcastRepository(),
    );
    await podcast.initialize();
    expect(podcast.showsRootTabs, isTrue);

    await podcast.openCollection(podcastListenCollections.first);
    expect(podcast.showsRootTabs, isFalse);
    podcast.closeCollection();
    expect(podcast.showsRootTabs, isTrue);

    await podcast.openFeed(feed.feedUrl);
    expect(podcast.showsRootTabs, isFalse);
    podcast.openEpisode(episode);
    expect(podcast.showsRootTabs, isFalse);
    podcast.closeOpenedEpisode();
    expect(podcast.openedFeed?.title, 'The Daily');
    expect(podcast.showsRootTabs, isFalse);
    podcast.closeOpenedFeed();
    expect(podcast.showsRootTabs, isTrue);
  });

  test('library episode back skips the show page', () async {
    final episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-1',
      feedUrl: 'https://feeds.example/show',
      title: 'Episode One',
      enclosureUrl: 'https://cdn.example/one.mp3',
      mediaExtension: 'mp3',
    );
    final feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'The Daily',
      episodes: [episode],
    );
    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(feeds: {feed.feedUrl: feed}),
      repository: _MemoryPodcastRepository(),
    );
    podcast.setPane(PodcastPane.library);
    podcast.openEpisode(episode, feed: feed, captions: true);
    expect(podcast.showsRootTabs, isFalse);
    podcast.closeOpenedEpisode();
    expect(podcast.openedEpisode, isNull);
    expect(podcast.openedFeed, isNull);
    expect(podcast.pane, PodcastPane.library);
    expect(podcast.showsRootTabs, isTrue);
  });

  test('hydrateEpisode restores description from the cached feed', () async {
    final episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-1',
      feedUrl: 'https://feeds.example/show',
      title: 'Episode One',
      enclosureUrl: 'https://cdn.example/one.mp3',
      mediaExtension: 'mp3',
      description: 'Show notes from the RSS feed.',
    );
    final feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'The Daily',
      episodes: [episode],
    );
    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(feeds: {feed.feedUrl: feed}),
      repository: _MemoryPodcastRepository(),
    );
    await podcast.initialize();
    await podcast.openFeed(feed.feedUrl);

    const provenance = PodcastEpisodeProvenance(
      feedUrl: 'https://feeds.example/show',
      episodeId: 'https://feeds.example/show\nguid-1',
      enclosureUrl: 'https://cdn.example/one.mp3',
      showTitle: 'The Daily',
      episodeTitle: 'Episode One',
    );
    expect(
      podcast.hydrateEpisode(provenance).description,
      'Show notes from the RSS feed.',
    );
  });

  test(
    'downloaded playback keeps the feed duration for ad detection',
    () async {
      final feedEpisode = PodcastEpisode(
        id: 'https://feeds.example/show\nguid-ad',
        feedUrl: 'https://feeds.example/show',
        title: 'Episode with an inserted ad',
        enclosureUrl: 'https://cdn.example/ad.mp3',
        mediaExtension: 'mp3',
        durationMs: 395000,
      );
      final feed = PodcastFeed(
        feedUrl: feedEpisode.feedUrl,
        title: 'The Show',
        episodes: [feedEpisode],
      );
      final player = _RecordingPodcastPlayer();
      final podcast = PodcastController(
        gateway: MemoryPodcastGateway(feeds: {feed.feedUrl: feed}),
        repository: _MemoryPodcastRepository(),
        player: player,
      );
      await podcast.initialize();
      await podcast.openFeed(feed.feedUrl);
      final downloadedEpisode = PodcastEpisode(
        id: feedEpisode.id,
        feedUrl: feedEpisode.feedUrl,
        title: feedEpisode.title,
        enclosureUrl: feedEpisode.enclosureUrl,
        mediaExtension: feedEpisode.mediaExtension,
        durationMs: 434233,
      );

      await podcast.playEpisode(downloadedEpisode, feed);

      expect(player.feedDurationMs, 395000);
    },
  );

  test(
    'opening a followed show uses the cached feed if refresh fails',
    () async {
      final episode = PodcastEpisode(
        id: 'https://feeds.example/show\nguid-1',
        feedUrl: 'https://feeds.example/show',
        title: 'Episode One',
        enclosureUrl: 'https://cdn.example/one.mp3',
        mediaExtension: 'mp3',
        guid: 'guid-1',
      );
      final feed = PodcastFeed(
        feedUrl: 'https://feeds.example/show',
        title: 'Huberman Lab',
        author: 'Scicomm Media',
        artworkUrl: 'https://cdn.example/huberman.jpg',
        episodes: [episode],
      );
      final gateway = MemoryPodcastGateway(
        feeds: {'https://feeds.example/show': feed},
      );
      final podcast = PodcastController(
        gateway: gateway,
        repository: _MemoryPodcastRepository(),
      );
      await podcast.initialize();
      await podcast.openFeed('https://feeds.example/show');
      await podcast.followOpenedFeed();
      expect(
        podcast.artworkForFollowed(podcast.followed.single),
        feed.artworkUrl,
      );

      podcast.setPane(PodcastPane.following);
      podcast.closeOpenedFeed();
      gateway.feeds = {};

      await podcast.openFollowed(podcast.followed.single);
      expect(podcast.openedFeed?.title, 'Huberman Lab');
      expect(podcast.pane, PodcastPane.following);
      expect(podcast.showsRootTabs, isFalse);
      expect(podcast.errorCode, isNull);
    },
  );

  test('opening a followed show clears its unseen badge', () async {
    const url = 'https://feeds.example/show';
    PodcastEpisode episode(int number) => PodcastEpisode(
      id: '$url\nguid-$number',
      feedUrl: url,
      title: 'Episode $number',
      enclosureUrl: 'https://cdn.example/$number.mp3',
      mediaExtension: 'mp3',
    );
    final gateway = MemoryPodcastGateway(
      feeds: {
        url: PodcastFeed(feedUrl: url, title: 'Show', episodes: [episode(1)]),
      },
    );
    final repository = _MemoryPodcastRepository();
    final podcast = PodcastController(gateway: gateway, repository: repository);
    await podcast.initialize();
    await podcast.openFeed(url);
    await podcast.followOpenedFeed();

    gateway.feeds = {
      url: PodcastFeed(
        feedUrl: url,
        title: 'Show',
        episodes: [episode(2), episode(1)],
      ),
    };
    await podcast.refreshFollowedNow();
    expect(podcast.followed.single.unseenEpisodeCount, 1);

    await podcast.openFollowed(podcast.followed.single);
    expect(podcast.followed.single.unseenEpisodeCount, 0);
    expect(repository.value.followed.single.unseenEpisodeCount, 0);

    await podcast.refreshFollowedNow();
    expect(podcast.followed.single.unseenEpisodeCount, 0);
  });

  test('keeps followed feeds and only the most recent others cached', () async {
    const limit = PodcastController.maxUnfollowedCachedFeeds;
    final feeds = [
      for (var index = 0; index < limit + 3; index++)
        PodcastFeed(
          feedUrl: 'https://feeds.example/show-$index',
          title: 'Show $index',
          episodes: const [],
        ),
    ];
    final repository = _MemoryPodcastRepository();
    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(
        feeds: {for (final feed in feeds) feed.feedUrl: feed},
      ),
      repository: repository,
    );
    await podcast.initialize();
    await podcast.openFeed(feeds.first.feedUrl);
    await podcast.followOpenedFeed();
    for (final feed in feeds.skip(1)) {
      await podcast.openFeed(feed.feedUrl);
    }

    // The followed and opened feeds sit outside the limit, so only the
    // oldest browsed feed is evicted.
    final cached = repository.value.feeds.keys.toSet();
    expect(cached, hasLength(limit + 2));
    expect(cached, contains(feeds.first.feedUrl));
    expect(cached, isNot(contains(feeds[1].feedUrl)));
    expect(cached, contains(feeds[2].feedUrl));
    expect(cached, contains(feeds.last.feedUrl));
  });

  test('revealPlayingEpisode opens the episode with captions', () async {
    final episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-1',
      feedUrl: 'https://feeds.example/show',
      title: 'Episode One',
      enclosureUrl: 'https://cdn.example/one.mp3',
      mediaExtension: 'mp3',
    );
    final feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'The Daily',
      episodes: [episode],
    );
    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(feeds: {feed.feedUrl: feed}),
      repository: _MemoryPodcastRepository(),
    );
    await podcast.initialize();
    await podcast.revealPlayingEpisode(episode, feed);
    expect(podcast.openedFeed?.title, 'The Daily');
    expect(podcast.openedEpisode?.id, episode.id);
    expect(podcast.captionsOpen, isTrue);
    expect(podcast.showsRootTabs, isFalse);
    podcast.setCaptionsOpen(false);
    expect(podcast.captionsOpen, isFalse);
    podcast.closeOpenedEpisode();
    expect(podcast.openedEpisode, isNull);
    expect(podcast.openedFeed?.title, 'The Daily');
  });

  test('feed errors stay dismissible without leaving browse', () async {
    final podcast = PodcastController(
      gateway: MemoryPodcastGateway(),
      repository: _MemoryPodcastRepository(),
    );
    await podcast.openFeed('https://feeds.example/missing');
    expect(podcast.openedFeed, isNull);
    expect(podcast.errorCode, 'podcast_feed_failed');
    podcast.clearError();
    expect(podcast.errorCode, isNull);
  });

  test('a stale search response cannot replace the current query', () async {
    final gateway = _DeferredSearchGateway();
    final podcast = PodcastController(
      gateway: gateway,
      repository: _MemoryPodcastRepository(),
    );
    addTearDown(podcast.dispose);

    final first = podcast.search('older');
    final second = podcast.search('current');
    gateway.complete('current', const [
      PodcastShowSummary(id: 'current', title: 'Current result'),
    ]);
    await second;
    gateway.complete('older', const [
      PodcastShowSummary(id: 'older', title: 'Older result'),
    ]);
    await first;

    expect(podcast.query, 'current');
    expect(podcast.results.single.id, 'current');
    expect(podcast.loading, isFalse);

    final pending = podcast.search('pending');
    expect(podcast.loading, isTrue);
    await podcast.search('current');
    expect(podcast.results.single.id, 'current');
    expect(podcast.loading, isFalse);
    gateway.complete('pending', const [
      PodcastShowSummary(id: 'pending', title: 'Pending result'),
    ]);
    await pending;
    expect(podcast.results.single.id, 'current');
  });

  test('imports publisher timing as free sentence-level captions', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meow-podcast-word-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const wordJson = '''
{
  "segments": [
    {
      "body": "Hello there friends today",
      "startTime": 0.0,
      "endTime": 2.4,
      "words": [
        {"body": "Hello", "startTime": 0.0, "endTime": 0.3},
        {"body": "there", "startTime": 0.35, "endTime": 0.6},
        {"body": "friends", "startTime": 0.7, "endTime": 1.1},
        {"body": "today", "startTime": 1.2, "endTime": 1.5}
      ]
    },
    {
      "body": "we talk about English",
      "startTime": 1.6,
      "endTime": 3.2,
      "words": [
        {"body": "we", "startTime": 1.6, "endTime": 1.75},
        {"body": "talk", "startTime": 1.8, "endTime": 2.1},
        {"body": "about", "startTime": 2.15, "endTime": 2.4},
        {"body": "English", "startTime": 2.5, "endTime": 3.1}
      ]
    }
  ]
}
''';
    final episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-word',
      feedUrl: 'https://feeds.example/show',
      title: 'Word Timed',
      enclosureUrl: 'https://cdn.example/word.mp3',
      mediaExtension: 'mp3',
      transcripts: const [
        PodcastTranscriptReference(
          url: 'https://cdn.example/word.json',
          type: 'application/json',
        ),
      ],
    );
    final feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'Study English',
      episodes: [episode],
    );
    final gateway = MemoryPodcastGateway(
      feeds: {'https://feeds.example/show': feed},
      transcripts: {'https://cdn.example/word.json': wordJson},
      enclosures: {
        'https://cdn.example/word.mp3': [1, 2, 3],
      },
    );
    final controller = AppController(
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
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.keyConfigured, isFalse);
    await controller.enqueuePodcastEpisode(episode, feed: feed);
    await _waitFor(
      () =>
          controller.inboxJobs.isNotEmpty &&
          controller.inboxJobs.single.status == JobStatus.ready,
    );
    expect(
      controller.inboxJobs.single.transcriptAcquisitionMode,
      TranscriptAcquisitionMode.publisherCaptions,
    );

    await controller.startReady();
    await _waitFor(
      () => controller.inboxJobs.single.status == JobStatus.completed,
    );
    expect(
      controller.inboxJobs.single.transcriptSource,
      TranscriptSource.publisher,
    );
    expect(controller.inboxJobs.single.document!.tokens, isEmpty);
    expect(controller.inboxJobs.single.document!.segments, hasLength(2));
  });

  test(
    'official captions default to free import and Soniox remains explicit',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-podcast-captions-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final episode = PodcastEpisode(
        id: 'https://feeds.example/show\nguid-vtt',
        feedUrl: 'https://feeds.example/show',
        title: 'Caption Episode',
        enclosureUrl: 'https://cdn.example/cap.mp3',
        mediaExtension: 'mp3',
        transcripts: const [
          PodcastTranscriptReference(
            url: 'https://cdn.example/cap.vtt',
            type: 'text/vtt',
          ),
        ],
      );
      final feed = PodcastFeed(
        feedUrl: 'https://feeds.example/show',
        title: 'Study English',
        episodes: [episode],
      );
      final gateway = MemoryPodcastGateway(
        feeds: {'https://feeds.example/show': feed},
        transcripts: {
          'https://cdn.example/cap.vtt':
              'WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nHello there.\n\n00:00:01.500 --> 00:00:03.000\nHow are you?\n',
        },
        enclosures: {
          'https://cdn.example/cap.mp3': [1, 2, 3],
        },
      );
      final controller = AppController(
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
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.enqueuePodcastEpisode(episode, feed: feed);
      await _waitFor(
        () =>
            controller.inboxJobs.isNotEmpty &&
            controller.inboxJobs.single.status == JobStatus.ready,
      );
      expect(
        controller.inboxJobs.single.transcriptAcquisitionMode,
        TranscriptAcquisitionMode.publisherCaptions,
      );
      expect(controller.canStartReady, isTrue);

      await controller.setTranscriptAcquisitionMode(
        controller.inboxJobs.single.id,
        TranscriptAcquisitionMode.soniox,
      );
      expect(controller.canStartReady, isFalse);
      await controller.setTranscriptAcquisitionMode(
        controller.inboxJobs.single.id,
        TranscriptAcquisitionMode.publisherCaptions,
      );

      await controller.startReady();
      await _waitFor(
        () => controller.inboxJobs.single.status == JobStatus.completed,
      );
      final job = controller.inboxJobs.single;
      expect(job.transcriptSource, TranscriptSource.publisher);
      expect(job.document!.tokens, isEmpty);
      expect(job.document!.segments, hasLength(2));
      expect(job.document!.segments.first.text, 'Hello there.');
    },
  );

  test('publisher failure never falls through to Soniox', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meow-podcast-publisher-failure-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-missing-caption',
      feedUrl: 'https://feeds.example/show',
      title: 'Missing captions',
      enclosureUrl: 'https://cdn.example/missing-caption.mp3',
      mediaExtension: 'mp3',
      transcripts: [
        PodcastTranscriptReference(
          url: 'https://cdn.example/missing-caption.vtt',
          type: 'text/vtt',
        ),
      ],
    );
    const feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'Study English',
      episodes: [episode],
    );
    final gateway = MemoryPodcastGateway(
      feeds: const {'https://feeds.example/show': feed},
      enclosures: const {
        'https://cdn.example/missing-caption.mp3': [1, 2, 3],
      },
    );
    final soniox = _Soniox();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: soniox,
      exporter: const DefaultTranscriptExporter(),
      podcastGateway: gateway,
      podcastManagedRoot: directory.path,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.enqueuePodcastEpisode(episode, feed: feed);
    await _waitFor(() => controller.inboxJobs.single.status == JobStatus.ready);

    expect(
      controller.inboxJobs.single.transcriptAcquisitionMode,
      TranscriptAcquisitionMode.publisherCaptions,
    );
    await controller.startReady();

    expect(controller.inboxJobs.single.status, JobStatus.failed);
    expect(controller.inboxJobs.single.errorCode, 'podcast_transcript_failed');
    expect(soniox.uploads, 0);
  });

  test('retry discards invalid final media and downloads it again', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meow-podcast-retry-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const episode = PodcastEpisode(
      id: 'https://feeds.example/show\nguid-retry',
      feedUrl: 'https://feeds.example/show',
      title: 'Retry me',
      enclosureUrl: 'https://cdn.example/retry.mp3',
      mediaExtension: 'mp3',
    );
    const feed = PodcastFeed(
      feedUrl: 'https://feeds.example/show',
      title: 'Study English',
      episodes: [episode],
    );
    final gateway = MemoryPodcastGateway(
      feeds: const {'https://feeds.example/show': feed},
      enclosures: const {
        'https://cdn.example/retry.mp3': [1, 2, 3, 4],
      },
    );
    final controller = AppController(
      credentialStore: _EmptyCredentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _FlakyMedia(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      podcastGateway: gateway,
      podcastManagedRoot: directory.path,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.enqueuePodcastEpisode(episode, feed: feed);
    await _waitFor(
      () => controller.inboxJobs.single.status == JobStatus.failed,
    );
    expect(gateway.downloads, hasLength(1));
    expect(File(controller.inboxJobs.single.sourcePath).existsSync(), isTrue);

    await controller.retry(controller.inboxJobs.single.id);
    await _waitFor(() => controller.inboxJobs.single.status == JobStatus.ready);

    expect(gateway.downloads, hasLength(2));
    expect(File(controller.inboxJobs.single.sourcePath).existsSync(), isTrue);

    final exported = '${directory.path}/exported.mp3';
    await controller.exportPodcastMedia(
      controller.inboxJobs.single.id,
      exported,
    );
    expect(await File(exported).readAsBytes(), [1, 2, 3, 4]);

    final managed = controller.inboxJobs.single.sourcePath;
    await controller.deleteHistory(controller.inboxJobs.single.id);
    expect(File(managed).existsSync(), isFalse);
    expect(await File(exported).readAsBytes(), [1, 2, 3, 4]);
  });
}

class _DeferredSearchGateway extends MemoryPodcastGateway {
  final _pending = <String, Completer<List<PodcastShowSummary>>>{};

  @override
  Future<List<PodcastShowSummary>> searchShows(
    String query, {
    String country = 'us',
  }) {
    final completer = Completer<List<PodcastShowSummary>>();
    _pending[query] = completer;
    return completer.future;
  }

  void complete(String query, List<PodcastShowSummary> shows) {
    _pending.remove(query)!.complete(shows);
  }
}

class _MemoryPodcastRepository implements PodcastRepository {
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

class _RecordingPodcastPlayer extends PodcastPlayer {
  int? feedDurationMs;

  @override
  Future<void> play(
    PodcastEpisode episode,
    PodcastFeed feed, {
    TranscriptDocument? document,
    String? localPath,
    int? feedDurationMs,
  }) async {
    this.feedDurationMs = feedDurationMs;
  }
}

class _Jobs implements JobRepository {
  final saved = <String, TranscriptionJob>{};

  @override
  Future<void> delete(String id) async => saved.remove(id);

  @override
  Future<List<TranscriptionJob>> loadAll() async => saved.values.toList();

  @override
  Future<void> save(TranscriptionJob job) async => saved[job.id] = job;
}

class _Settings implements SettingsRepository {
  @override
  Future<AppSettings> load() async => const AppSettings();

  @override
  Future<void> save(AppSettings settings) async {}
}

class _Credentials implements CredentialStore {
  @override
  Future<void> deleteApiKey() async {}

  @override
  Future<String?> readApiKey() async => 'configured';

  @override
  Future<void> writeApiKey(String key) async {}
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

class _FlakyMedia extends _Media {
  var inspections = 0;

  @override
  Future<MediaMetadata> inspect(String sourcePath) async {
    inspections++;
    if (inspections == 1) {
      throw StateError('The media is invalid.');
    }
    return super.inspect(sourcePath);
  }
}

class _Soniox implements SonioxClient {
  var uploads = 0;

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
  }) async {
    uploads++;
    return 'file';
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
