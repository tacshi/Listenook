import 'models.dart';

class PodcastException implements Exception {
  const PodcastException(this.code, {this.message});

  final String code;
  final String? message;

  @override
  String toString() => 'PodcastException($code)';
}

class PodcastShowSummary {
  const PodcastShowSummary({
    required this.id,
    required this.title,
    this.feedUrl = '',
    this.author,
    this.artworkUrl,
    this.showUrl,
    this.genre,
  });

  final String id;
  final String title;
  final String feedUrl;
  final String? author;
  final String? artworkUrl;
  final String? showUrl;
  final String? genre;

  bool get hasFeed => feedUrl.trim().isNotEmpty;

  PodcastShowSummary copyWith({String? feedUrl, String? artworkUrl}) =>
      PodcastShowSummary(
        id: id,
        title: title,
        feedUrl: feedUrl ?? this.feedUrl,
        author: author,
        artworkUrl: artworkUrl ?? this.artworkUrl,
        showUrl: showUrl,
        genre: genre,
      );
}

class PodcastListenCollection {
  const PodcastListenCollection({
    required this.id,
    required this.labelKey,
    required this.appleGenreIds,
  });

  final String id;
  final String labelKey;
  final List<int> appleGenreIds;
}

const podcastListenCollections = <PodcastListenCollection>[
  PodcastListenCollection(
    id: 'news',
    labelKey: 'podcast_collection_news',
    appleGenreIds: [1489],
  ),
  PodcastListenCollection(
    id: 'lessons',
    labelKey: 'podcast_collection_lessons',
    appleGenreIds: [1304],
  ),
  PodcastListenCollection(
    id: 'interviews',
    labelKey: 'podcast_collection_interviews',
    appleGenreIds: [1324],
  ),
  PodcastListenCollection(
    id: 'science',
    labelKey: 'podcast_collection_science',
    appleGenreIds: [1533],
  ),
  PodcastListenCollection(
    id: 'business',
    labelKey: 'podcast_collection_business',
    appleGenreIds: [1321],
  ),
  PodcastListenCollection(
    id: 'stories',
    labelKey: 'podcast_collection_stories',
    appleGenreIds: [1487, 1483],
  ),
];

const podcastSkipChartGenres = {
  'Arts',
  'Comedy',
  'Government',
  'Kids & Family',
  'Leisure',
  'Music',
  'Religion & Spirituality',
  'Sports',
  'True Crime',
  'TV & Film',
};

List<PodcastShowSummary> talkHeavyShows(Iterable<PodcastShowSummary> shows) => [
  for (final show in shows)
    if (show.genre == null ||
        show.genre!.trim().isEmpty ||
        !podcastSkipChartGenres.contains(show.genre))
      show,
];

class PodcastEpisode {
  const PodcastEpisode({
    required this.id,
    required this.feedUrl,
    required this.title,
    required this.enclosureUrl,
    required this.mediaExtension,
    this.guid,
    this.publishedAt,
    this.durationMs,
    this.description,
    this.episodeUrl,
    this.artworkUrl,
    this.mimeType,
    this.transcripts = const [],
    this.transcriptTiming = PodcastTranscriptTiming.none,
  });

  final String id;
  final String feedUrl;
  final String title;
  final String enclosureUrl;
  final String mediaExtension;
  final String? guid;
  final DateTime? publishedAt;
  final int? durationMs;
  final String? description;
  final String? episodeUrl;
  final String? artworkUrl;
  final String? mimeType;
  final List<PodcastTranscriptReference> transcripts;
  final PodcastTranscriptTiming transcriptTiming;

  Map<String, dynamic> toJson() => {
    'id': id,
    'feed_url': feedUrl,
    'title': title,
    'enclosure_url': enclosureUrl,
    'media_extension': mediaExtension,
    if (guid case final value?) 'guid': value,
    if (publishedAt case final value?)
      'published_at': value.toUtc().toIso8601String(),
    if (durationMs case final value?) 'duration_ms': value,
    if (description case final value?) 'description': value,
    if (episodeUrl case final value?) 'episode_url': value,
    if (artworkUrl case final value?) 'artwork_url': value,
    if (mimeType case final value?) 'mime_type': value,
    if (transcripts.isNotEmpty)
      'transcripts': transcripts.map((item) => item.toJson()).toList(),
    'transcript_timing': transcriptTiming.name,
  };

  factory PodcastEpisode.fromJson(Map<String, dynamic> json) => PodcastEpisode(
    id: json['id'] as String? ?? '',
    feedUrl: json['feed_url'] as String? ?? '',
    title: json['title'] as String? ?? '',
    enclosureUrl: json['enclosure_url'] as String? ?? '',
    mediaExtension: json['media_extension'] as String? ?? 'mp3',
    guid: json['guid'] as String?,
    publishedAt: DateTime.tryParse(
      json['published_at'] as String? ?? '',
    )?.toUtc(),
    durationMs: (json['duration_ms'] as num?)?.toInt(),
    description: json['description'] as String?,
    episodeUrl: json['episode_url'] as String?,
    artworkUrl: json['artwork_url'] as String?,
    mimeType: json['mime_type'] as String?,
    transcripts: [
      for (final item
          in json['transcripts'] is List
              ? json['transcripts'] as List
              : const [])
        if (item is Map)
          PodcastTranscriptReference.fromJson(item.cast<String, dynamic>()),
    ],
    transcriptTiming:
        PodcastTranscriptTiming.values
            .where((value) => value.name == json['transcript_timing'])
            .firstOrNull ??
        PodcastTranscriptTiming.none,
  );

  PodcastEpisode copyWith({
    PodcastTranscriptTiming? transcriptTiming,
    List<PodcastTranscriptReference>? transcripts,
  }) => PodcastEpisode(
    id: id,
    feedUrl: feedUrl,
    title: title,
    enclosureUrl: enclosureUrl,
    mediaExtension: mediaExtension,
    guid: guid,
    publishedAt: publishedAt,
    durationMs: durationMs,
    description: description,
    episodeUrl: episodeUrl,
    artworkUrl: artworkUrl,
    mimeType: mimeType,
    transcripts: transcripts ?? this.transcripts,
    transcriptTiming: transcriptTiming ?? this.transcriptTiming,
  );
}

class PodcastFeed {
  const PodcastFeed({
    required this.feedUrl,
    required this.title,
    required this.episodes,
    this.author,
    this.description,
    this.artworkUrl,
    this.language,
    this.showUrl,
    this.fetchedAt,
  });

  final String feedUrl;
  final String title;
  final List<PodcastEpisode> episodes;
  final String? author;
  final String? description;
  final String? artworkUrl;
  final String? language;
  final String? showUrl;
  final DateTime? fetchedAt;

  Map<String, dynamic> toJson() => {
    'feed_url': feedUrl,
    'title': title,
    'episodes': episodes.take(50).map((item) => item.toJson()).toList(),
    if (author case final value?) 'author': value,
    if (description case final value?) 'description': value,
    if (artworkUrl case final value?) 'artwork_url': value,
    if (language case final value?) 'language': value,
    if (showUrl case final value?) 'show_url': value,
    if (fetchedAt case final value?)
      'fetched_at': value.toUtc().toIso8601String(),
  };

  factory PodcastFeed.fromJson(Map<String, dynamic> json) => PodcastFeed(
    feedUrl: json['feed_url'] as String? ?? '',
    title: json['title'] as String? ?? '',
    author: json['author'] as String?,
    description: json['description'] as String?,
    artworkUrl: json['artwork_url'] as String?,
    language: json['language'] as String?,
    showUrl: json['show_url'] as String?,
    fetchedAt: DateTime.tryParse(json['fetched_at'] as String? ?? '')?.toUtc(),
    episodes: [
      for (final item
          in json['episodes'] is List ? json['episodes'] as List : const [])
        if (item is Map) PodcastEpisode.fromJson(item.cast<String, dynamic>()),
    ],
  );

  PodcastFeed copyWith({List<PodcastEpisode>? episodes, DateTime? fetchedAt}) =>
      PodcastFeed(
        feedUrl: feedUrl,
        title: title,
        episodes: episodes ?? this.episodes,
        author: author,
        description: description,
        artworkUrl: artworkUrl,
        language: language,
        showUrl: showUrl,
        fetchedAt: fetchedAt ?? this.fetchedAt,
      );
}

class FollowedPodcast {
  const FollowedPodcast({
    required this.feedUrl,
    required this.title,
    required this.followedAt,
    this.author,
    this.artworkUrl,
    this.language,
    this.lastRefreshedAt,
    this.lastSeenEpisodeIds = const {},
    this.unseenEpisodeCount = 0,
  });

  final String feedUrl;
  final String title;
  final DateTime followedAt;
  final String? author;
  final String? artworkUrl;
  final String? language;
  final DateTime? lastRefreshedAt;
  final Set<String> lastSeenEpisodeIds;
  final int unseenEpisodeCount;

  FollowedPodcast copyWith({
    String? title,
    String? author,
    String? artworkUrl,
    String? language,
    DateTime? lastRefreshedAt,
    Set<String>? lastSeenEpisodeIds,
    int? unseenEpisodeCount,
  }) => FollowedPodcast(
    feedUrl: feedUrl,
    title: title ?? this.title,
    followedAt: followedAt,
    author: author ?? this.author,
    artworkUrl: artworkUrl ?? this.artworkUrl,
    language: language ?? this.language,
    lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
    lastSeenEpisodeIds: lastSeenEpisodeIds ?? this.lastSeenEpisodeIds,
    unseenEpisodeCount: unseenEpisodeCount ?? this.unseenEpisodeCount,
  );

  Map<String, dynamic> toJson() => {
    'feed_url': feedUrl,
    'title': title,
    'followed_at': followedAt.toUtc().toIso8601String(),
    if (author case final value?) 'author': value,
    if (artworkUrl case final value?) 'artwork_url': value,
    if (language case final value?) 'language': value,
    if (lastRefreshedAt case final value?)
      'last_refreshed_at': value.toUtc().toIso8601String(),
    'last_seen_episode_ids': lastSeenEpisodeIds.toList()..sort(),
    'unseen_episode_count': unseenEpisodeCount,
  };

  factory FollowedPodcast.fromJson(Map<String, dynamic> json) =>
      FollowedPodcast(
        feedUrl: json['feed_url'] as String? ?? '',
        title: json['title'] as String? ?? '',
        followedAt:
            DateTime.tryParse(json['followed_at'] as String? ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        author: json['author'] as String?,
        artworkUrl: json['artwork_url'] as String?,
        language: json['language'] as String?,
        lastRefreshedAt: DateTime.tryParse(
          json['last_refreshed_at'] as String? ?? '',
        )?.toUtc(),
        lastSeenEpisodeIds: {
          for (final value
              in json['last_seen_episode_ids'] is List
                  ? json['last_seen_episode_ids'] as List
                  : const [])
            if (value is String && value.isNotEmpty) value,
        },
        unseenEpisodeCount:
            (json['unseen_episode_count'] as num?)?.toInt() ?? 0,
      );
}

class PodcastListenProgress {
  const PodcastListenProgress({
    required this.positionMs,
    required this.durationMs,
    this.updatedAt,
  });

  static const continueAfterMs = 3000;
  static const finishedWithinMs = 5000;
  static const maxEntries = 200;

  final int positionMs;
  final int durationMs;
  final DateTime? updatedAt;

  double get fraction =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  int get remainingMs =>
      durationMs <= 0 ? 0 : (durationMs - positionMs).clamp(0, durationMs);

  bool get isContinue {
    if (positionMs < continueAfterMs) return false;
    if (durationMs <= 0) return true;
    return positionMs <= durationMs - finishedWithinMs;
  }

  PodcastListenProgress withFallbackDuration(int? fallbackMs) {
    if (durationMs > 0 || fallbackMs == null || fallbackMs <= 0) return this;
    return PodcastListenProgress(
      positionMs: positionMs,
      durationMs: fallbackMs,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'position_ms': positionMs,
    'duration_ms': durationMs,
    if (updatedAt case final value?)
      'updated_at': value.toUtc().toIso8601String(),
  };

  factory PodcastListenProgress.fromJson(Map<String, dynamic> json) =>
      PodcastListenProgress(
        positionMs: (json['position_ms'] as num?)?.toInt() ?? 0,
        durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(
          json['updated_at'] as String? ?? '',
        )?.toUtc(),
      );
}

class PodcastLibraryState {
  const PodcastLibraryState({this.followed = const [], this.feeds = const {}});

  final List<FollowedPodcast> followed;
  final Map<String, PodcastFeed> feeds;

  PodcastLibraryState copyWith({
    List<FollowedPodcast>? followed,
    Map<String, PodcastFeed>? feeds,
  }) => PodcastLibraryState(
    followed: followed ?? this.followed,
    feeds: feeds ?? this.feeds,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'followed': followed.map((item) => item.toJson()).toList(),
    'feeds': [for (final feed in feeds.values) feed.toJson()],
  };

  factory PodcastLibraryState.fromJson(Map<String, dynamic>? json) {
    final followed = [
      for (final item
          in json?['followed'] is List ? json!['followed'] as List : const [])
        if (item is Map) FollowedPodcast.fromJson(item.cast<String, dynamic>()),
    ];
    final feeds = <String, PodcastFeed>{};
    for (final item
        in json?['feeds'] is List ? json!['feeds'] as List : const []) {
      if (item is! Map) continue;
      final feed = PodcastFeed.fromJson(item.cast<String, dynamic>());
      if (feed.feedUrl.isNotEmpty) feeds[feed.feedUrl] = feed;
    }
    return PodcastLibraryState(followed: followed, feeds: feeds);
  }
}

enum PodcastDownloadLocationKind { managedCache }

class PodcastDownloadLocation {
  const PodcastDownloadLocation({
    required this.kind,
    required this.directory,
    required this.fileName,
  });

  final PodcastDownloadLocationKind kind;
  final String directory;
  final String fileName;

  String get filePath => directory.endsWith('/') || directory.endsWith('\\')
      ? '$directory$fileName'
      : '$directory${_separator(directory)}$fileName';

  static String _separator(String directory) =>
      directory.contains('\\') && !directory.contains('/') ? '\\' : '/';
}

class PublisherTranscript {
  const PublisherTranscript({required this.timing, required this.document});

  final PodcastTranscriptTiming timing;
  final TranscriptDocument document;
}

extension PodcastEpisodeProvenanceMedia on PodcastEpisodeProvenance {
  PodcastEpisode toEpisode({
    int? durationMs,
    String mediaExtension = 'mp3',
    String? description,
  }) => PodcastEpisode(
    id: episodeId,
    feedUrl: feedUrl,
    title: episodeTitle,
    enclosureUrl: enclosureUrl,
    mediaExtension: mediaExtension,
    guid: guid,
    publishedAt: publishedAt,
    durationMs: durationMs,
    description: description ?? this.description,
    episodeUrl: episodeUrl,
    artworkUrl: artworkUrl,
    transcripts: transcripts,
    transcriptTiming: transcriptTiming,
  );

  PodcastFeed toFeed({PodcastEpisode? episode, int? durationMs}) {
    final resolved = episode ?? toEpisode(durationMs: durationMs);
    return PodcastFeed(
      feedUrl: feedUrl,
      title: showTitle,
      author: author,
      artworkUrl: artworkUrl,
      showUrl: showUrl,
      language: language,
      episodes: [resolved],
    );
  }
}
