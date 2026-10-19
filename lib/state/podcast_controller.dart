import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/contracts.dart';
import '../core/models.dart';
import '../core/podcast_models.dart';
import '../data/podcast/featured_podcasts.dart';
import '../data/podcast/podcast_urls.dart';
import 'podcast_player.dart';

enum PodcastPane { discover, following, library }

class PodcastController extends ChangeNotifier {
  PodcastController({
    required PodcastGateway gateway,
    required PodcastRepository repository,
    PodcastPlayer? player,
  }) : _gateway = gateway,
       _repository = repository,
       _player =
           player ?? PodcastPlayer(gateway: gateway, repository: repository),
       _ownsPlayer = player == null {
    _player.addListener(_handlePlaybackChange);
  }

  static const searchCacheTtl = Duration(minutes: 10);
  static const browseCacheTtl = Duration(hours: 6);
  static const feedRefreshAfter = Duration(minutes: 30);

  /// Feeds opened while browsing are cached with every episode, and the whole
  /// catalog is rewritten on each save. Followed, opened and playing feeds are
  /// always kept; beyond those, only this many recent feeds are.
  static const maxUnfollowedCachedFeeds = 10;

  final PodcastGateway _gateway;
  final PodcastRepository _repository;
  final PodcastPlayer _player;
  final bool _ownsPlayer;
  PodcastLibraryState _state = const PodcastLibraryState();
  PodcastPane _pane = PodcastPane.discover;
  String _query = '';
  List<PodcastShowSummary> _results = const [];
  PodcastFeed? _openedFeed;
  PodcastEpisode? _openedEpisode;
  bool _captionsOpen = false;
  String? _errorCode;
  bool _loading = false;
  bool _initialized = false;
  bool _browseLoading = false;
  DateTime? _browseLoadedAt;
  List<PodcastShowSummary> _featured = const [];
  List<PodcastShowSummary> _popular = const [];
  final Map<String, List<PodcastShowSummary>> _collections = {};
  PodcastListenCollection? _openedCollection;
  final Map<String, _CachedSearch> _searchCache = {};
  var _searchGeneration = 0;

  PodcastPane get pane => _pane;
  String get query => _query;
  List<PodcastShowSummary> get results => _results;
  PodcastFeed? get openedFeed => _openedFeed;
  PodcastEpisode? get openedEpisode => _openedEpisode;
  bool get captionsOpen => _captionsOpen;
  String? get errorCode => _errorCode;
  bool get loading => _loading;
  bool get initialized => _initialized;
  bool get browseLoading => _browseLoading;
  List<PodcastShowSummary> get featured => _featured;
  List<PodcastShowSummary> get popular => _popular;
  Map<String, List<PodcastShowSummary>> get collections => _collections;
  PodcastListenCollection? get openedCollection => _openedCollection;
  bool get showsRootTabs =>
      _openedFeed == null &&
      _openedCollection == null &&
      _openedEpisode == null;
  List<FollowedPodcast> get followed => _state.followed;
  PodcastPlayer get playback => _player;

  PodcastEpisodeDisplayState episodeDisplayState(
    PodcastEpisode episode, {
    TranscriptionJob? job,
    bool downloaded = false,
  }) {
    final previewing = _player.episode?.id == episode.id;
    final progress = _player.progressFor(
      episode.id,
      fallbackDurationMs: episode.durationMs,
    );
    final continuing = progress?.isContinue ?? false;
    return PodcastEpisodeDisplayState(
      playing: previewing && _player.playing,
      continuing: continuing,
      progressFraction: continuing ? progress?.fraction : null,
      displayDurationMs: continuing
          ? progress!.remainingMs
          : episode.durationMs,
      downloading: job?.status == JobStatus.downloading,
      downloaded: downloaded,
      retryable: job?.status.canRetry ?? false,
    );
  }

  Future<void> playEpisode(
    PodcastEpisode episode,
    PodcastFeed feed, {
    TranscriptDocument? document,
    String? localPath,
  }) => _player.play(
    episode,
    feed,
    document: document,
    localPath: localPath,
    feedDurationMs:
        cachedEpisode(episode.id, feedUrl: episode.feedUrl)?.durationMs ??
        episode.durationMs,
  );

  Object? _playbackSnapshot;

  /// The player notifies on every position tick. Pages that watch this
  /// controller only show playback at whole-second detail (episode rows,
  /// shell, tray), so forward a change only when that view of it differs;
  /// widgets that track the position closely listen to [playback] directly.
  void _handlePlaybackChange() {
    final player = _player;
    final snapshot = (
      player.episode,
      player.feed,
      player.document,
      player.cues,
      player.loadingCues,
      player.playing,
      player.expanded,
      player.rate,
      player.duration.inSeconds,
      player.position.inSeconds,
    );
    if (snapshot == _playbackSnapshot) return;
    _playbackSnapshot = snapshot;
    notifyListeners();
  }

  FollowedPodcast? followedByUrl(String feedUrl) {
    final url = canonicalizeHttpUrl(feedUrl) ?? feedUrl;
    for (final item in _state.followed) {
      if (item.feedUrl == url || item.feedUrl == feedUrl) return item;
    }
    return null;
  }

  PodcastFeed? cachedFeed(String feedUrl) {
    final url = canonicalizeHttpUrl(feedUrl) ?? feedUrl;
    final direct = _state.feeds[url] ?? _state.feeds[feedUrl];
    if (direct != null) return direct;
    for (final feed in _state.feeds.values) {
      if (feed.feedUrl == url || feed.feedUrl == feedUrl) return feed;
    }
    return null;
  }

  String? artworkForFollowed(FollowedPodcast show) {
    final stored = show.artworkUrl?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return cachedFeed(show.feedUrl)?.artworkUrl;
  }

  PodcastEpisode? cachedEpisode(String episodeId, {String? feedUrl}) {
    if (feedUrl != null) {
      final feed = cachedFeed(feedUrl);
      if (feed != null) {
        for (final episode in feed.episodes) {
          if (episode.id == episodeId) return episode;
        }
      }
    }
    for (final feed in _state.feeds.values) {
      for (final episode in feed.episodes) {
        if (episode.id == episodeId) return episode;
      }
    }
    return null;
  }

  PodcastEpisode hydrateEpisode(
    PodcastEpisodeProvenance provenance, {
    int? durationMs,
  }) {
    final cached = cachedEpisode(
      provenance.episodeId,
      feedUrl: provenance.feedUrl,
    );
    return provenance.toEpisode(
      durationMs: durationMs ?? cached?.durationMs,
      description: _firstNonEmpty(provenance.description, cached?.description),
    );
  }

  String? _firstNonEmpty(String? a, String? b) {
    final first = a?.trim();
    if (first != null && first.isNotEmpty) return a;
    final second = b?.trim();
    if (second != null && second.isNotEmpty) return b;
    return a ?? b;
  }

  bool isFollowed(String feedUrl) => followedByUrl(feedUrl) != null;

  Future<void> initialize() async {
    _state = await _repository.load();
    _pruneCachedFeeds();
    await _player.initialize();
    _initialized = true;
    notifyListeners();
    unawaited(loadBrowse());
  }

  Future<void> loadBrowse({bool force = false}) async {
    final loadedAt = _browseLoadedAt;
    if (!force &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < browseCacheTtl &&
        _popular.isNotEmpty) {
      return;
    }
    _browseLoading = true;
    notifyListeners();
    try {
      final featured = await _gateway.lookupShows(
        featuredEnglishLearningCollectionIds,
      );
      final popular = await _gateway.topShows(limit: 25);
      _featured = featured;
      _popular = talkHeavyShows(popular).take(16).toList();
      _browseLoadedAt = DateTime.now();
    } on PodcastException catch (error) {
      _errorCode ??= error.code;
    } on Object {
      _errorCode ??= 'podcast_chart_failed';
    } finally {
      _browseLoading = false;
      notifyListeners();
    }
    unawaited(_loadCollections());
  }

  Future<void> _loadCollections() async {
    const batchSize = 3;
    for (
      var index = 0;
      index < podcastListenCollections.length;
      index += batchSize
    ) {
      final batch = podcastListenCollections.skip(index).take(batchSize);
      await Future.wait([
        for (final collection in batch) _loadCollection(collection, limit: 9),
      ]);
      notifyListeners();
    }
  }

  Future<void> _loadCollection(
    PodcastListenCollection collection, {
    int limit = 9,
    bool resolveFeeds = false,
  }) async {
    if (_collections[collection.id]?.isNotEmpty ?? false) return;
    final merged = <PodcastShowSummary>[];
    final seen = <String>{};
    for (final genreId in collection.appleGenreIds) {
      try {
        final shows = await _gateway.topShows(
          genreId: genreId,
          limit: limit,
          resolveFeeds: resolveFeeds,
        );
        for (final show in shows) {
          if (seen.add(show.id)) merged.add(show);
        }
      } on Object {
        continue;
      }
    }
    _collections[collection.id] = merged;
  }

  Future<void> openCollection(PodcastListenCollection collection) async {
    _openedCollection = collection;
    _errorCode = null;
    notifyListeners();
    if (_collections[collection.id]?.isNotEmpty ?? false) return;
    _browseLoading = true;
    notifyListeners();
    await _loadCollection(collection, limit: 25, resolveFeeds: false);
    _browseLoading = false;
    notifyListeners();
  }

  void closeCollection() {
    if (_openedCollection == null) return;
    _openedCollection = null;
    notifyListeners();
  }

  Future<void> openShow(PodcastShowSummary show) async {
    var feedUrl = show.feedUrl;
    if (!show.hasFeed) {
      try {
        final looked = await _gateway.lookupShows([show.id]);
        feedUrl =
            looked.where((item) => item.hasFeed).firstOrNull?.feedUrl ?? '';
      } on PodcastException catch (error) {
        _errorCode = error.code;
        notifyListeners();
        return;
      } on Object {
        _errorCode = 'podcast_lookup_failed';
        notifyListeners();
        return;
      }
    }
    if (feedUrl.isEmpty) {
      _errorCode = 'podcast_lookup_failed';
      notifyListeners();
      return;
    }
    await openFeed(feedUrl);
  }

  void setPane(PodcastPane pane) {
    if (_pane == pane) return;
    _pane = pane;
    notifyListeners();
  }

  Future<void> search(String query) async {
    final trimmed = query.trim();
    final generation = ++_searchGeneration;
    _query = trimmed;
    _errorCode = null;
    _openedCollection = null;
    if (trimmed.length < 2) {
      _results = const [];
      _loading = false;
      notifyListeners();
      return;
    }
    final cached = _searchCache[trimmed.toLowerCase()];
    if (cached != null &&
        DateTime.now().difference(cached.at) < searchCacheTtl) {
      _results = cached.shows;
      _loading = false;
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      final shows = await _gateway.searchShows(trimmed);
      _searchCache[trimmed.toLowerCase()] = (at: DateTime.now(), shows: shows);
      if (generation != _searchGeneration || _query != trimmed) return;
      _results = shows;
    } on PodcastException catch (error) {
      if (generation != _searchGeneration || _query != trimmed) return;
      _errorCode = error.code;
      _results = const [];
    } on Object {
      if (generation != _searchGeneration || _query != trimmed) return;
      _errorCode = 'podcast_search_failed';
      _results = const [];
    } finally {
      if (generation == _searchGeneration && _query == trimmed) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  void openEpisode(
    PodcastEpisode episode, {
    PodcastFeed? feed,
    bool captions = false,
  }) {
    if (feed != null) _openedFeed = feed;
    _openedEpisode = episode;
    _captionsOpen = captions;
    notifyListeners();
  }

  void closeOpenedEpisode() {
    if (_openedEpisode == null && !_captionsOpen) return;
    _openedEpisode = null;
    _captionsOpen = false;
    if (_pane == PodcastPane.library) _openedFeed = null;
    notifyListeners();
  }

  void setCaptionsOpen(bool open) {
    if (_captionsOpen == open) return;
    _captionsOpen = open;
    notifyListeners();
  }

  Future<void> revealPlayingEpisode(
    PodcastEpisode episode,
    PodcastFeed feed,
  ) async {
    _errorCode = null;
    _openedCollection = null;
    _query = '';
    final url = canonicalizeHttpUrl(feed.feedUrl) ?? feed.feedUrl;
    _openedFeed = cachedFeed(url) ?? feed;
    _openedEpisode = episode;
    _captionsOpen = true;
    if (_state.feeds[_openedFeed!.feedUrl] == null) {
      _cacheFeed(_openedFeed!);
      await _persist();
    }
    notifyListeners();
  }

  Future<void> openFeed(String feedUrl) async {
    final url = canonicalizeHttpUrl(feedUrl) ?? feedUrl;
    _openedEpisode = null;
    _captionsOpen = false;
    _errorCode = null;
    final cached = cachedFeed(url);
    if (cached != null) {
      _openedFeed = cached;
      _loading = false;
      notifyListeners();
      await _refreshOpenedFeed(url);
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      final feed = await _gateway.fetchFeed(url);
      _openedFeed = feed;
      _cacheFeed(feed);
      await _persist();
    } on PodcastException catch (error) {
      _errorCode = error.code;
    } on Object {
      _errorCode = 'podcast_feed_failed';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> openFollowed(FollowedPodcast show) async {
    _openedEpisode = null;
    _captionsOpen = false;
    _errorCode = null;
    final url = canonicalizeHttpUrl(show.feedUrl) ?? show.feedUrl;
    final cached = cachedFeed(url);
    if (cached != null) {
      _openedFeed = cached;
      notifyListeners();
      await _refreshOpenedFeed(url);
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      final feed = await _gateway.fetchFeed(url);
      _openedFeed = feed;
      _cacheFeed(feed);
      await _persist();
    } on PodcastException catch (error) {
      _errorCode = error.code;
    } on Object {
      _errorCode = 'podcast_feed_failed';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> _refreshOpenedFeed(String feedUrl) async {
    try {
      final feed = await _gateway.fetchFeed(feedUrl);
      _cacheFeed(feed);
      if (_openedFeed != null &&
          (_openedFeed!.feedUrl == feed.feedUrl ||
              _openedFeed!.feedUrl == feedUrl)) {
        _openedFeed = feed;
      }
      await _persist();
      notifyListeners();
    } on Object {
      // Keep the last good snapshot so Following can still open the show.
    }
  }

  Future<void> addFeedUrl(String feedUrl) => openFeed(feedUrl);

  void clearError() {
    if (_errorCode == null) return;
    _errorCode = null;
    notifyListeners();
  }

  void closeOpenedFeed() {
    _openedFeed = null;
    _openedEpisode = null;
    _captionsOpen = false;
    _errorCode = null;
    notifyListeners();
  }

  Future<void> followOpenedFeed() async {
    final feed = _openedFeed;
    if (feed == null || isFollowed(feed.feedUrl)) return;
    final followed = [
      ..._state.followed,
      FollowedPodcast(
        feedUrl: feed.feedUrl,
        title: feed.title,
        followedAt: DateTime.now().toUtc(),
        author: feed.author,
        artworkUrl: feed.artworkUrl,
        language: feed.language,
        lastRefreshedAt: feed.fetchedAt,
        lastSeenEpisodeIds: {for (final episode in feed.episodes) episode.id},
      ),
    ];
    _state = _state.copyWith(followed: followed);
    await _persist();
    notifyListeners();
  }

  Future<void> unfollow(String feedUrl) async {
    final url = canonicalizeHttpUrl(feedUrl) ?? feedUrl;
    _state = _state.copyWith(
      followed: [
        for (final item in _state.followed)
          if (item.feedUrl != url) item,
      ],
    );
    await _persist();
    notifyListeners();
  }

  Future<void> markOpenedFeedSeen() async {
    final feed = _openedFeed;
    if (feed == null) return;
    final current = followedByUrl(feed.feedUrl);
    if (current == null) return;
    _replaceFollowed(
      current.copyWith(
        lastSeenEpisodeIds: {for (final episode in feed.episodes) episode.id},
        unseenEpisodeCount: 0,
      ),
    );
    await _persist();
    notifyListeners();
  }

  Future<void> refreshStaleFollowed({DateTime? now}) async {
    final moment = now ?? DateTime.now().toUtc();
    for (final item in List<FollowedPodcast>.of(_state.followed)) {
      final last = item.lastRefreshedAt;
      if (last != null && moment.difference(last) < feedRefreshAfter) continue;
      await _refreshFollowed(item);
    }
  }

  Future<void> refreshFollowedNow() async {
    for (final item in List<FollowedPodcast>.of(_state.followed)) {
      await _refreshFollowed(item);
    }
  }

  Future<void> _refreshFollowed(FollowedPodcast item) async {
    try {
      final feed = await _gateway.fetchFeed(item.feedUrl);
      _cacheFeed(feed);
      final unseen = feed.episodes
          .where((episode) => !item.lastSeenEpisodeIds.contains(episode.id))
          .length;
      _replaceFollowed(
        item.copyWith(
          title: feed.title,
          author: feed.author,
          artworkUrl: feed.artworkUrl,
          language: feed.language,
          lastRefreshedAt: DateTime.now().toUtc(),
          unseenEpisodeCount: unseen,
        ),
      );
      if (_openedFeed?.feedUrl == feed.feedUrl) _openedFeed = feed;
    } on Object {
      // Keep the last good snapshot; the next manual refresh can retry.
    }
    await _persist();
    notifyListeners();
  }

  void _replaceFollowed(FollowedPodcast updated) {
    _state = _state.copyWith(
      followed: [
        for (final item in _state.followed)
          if (item.feedUrl == updated.feedUrl) updated else item,
      ],
    );
  }

  void _cacheFeed(PodcastFeed feed) {
    // Re-insert so map order runs from least to most recently cached.
    _state = _state.copyWith(
      feeds: {
        for (final entry in _state.feeds.entries)
          if (entry.key != feed.feedUrl) entry.key: entry.value,
        feed.feedUrl: feed,
      },
    );
    _pruneCachedFeeds(keep: feed.feedUrl);
  }

  void _pruneCachedFeeds({String? keep}) {
    bool pinned(String url) =>
        url == keep ||
        url == _openedFeed?.feedUrl ||
        url == _player.feed?.feedUrl ||
        isFollowed(url);
    var excess =
        _state.feeds.keys.where((url) => !pinned(url)).length -
        maxUnfollowedCachedFeeds;
    if (excess <= 0) return;
    final feeds = Map<String, PodcastFeed>.of(_state.feeds)
      ..removeWhere((url, _) => !pinned(url) && excess-- > 0);
    _state = _state.copyWith(feeds: feeds);
  }

  Future<void> _persist() => _repository.save(_state);

  Future<void> shutdown() => _player.shutdown();

  @override
  void dispose() {
    _player.removeListener(_handlePlaybackChange);
    if (_ownsPlayer) _player.dispose();
    super.dispose();
  }
}

@immutable
class PodcastEpisodeDisplayState {
  const PodcastEpisodeDisplayState({
    required this.playing,
    required this.continuing,
    required this.progressFraction,
    required this.displayDurationMs,
    required this.downloading,
    required this.downloaded,
    required this.retryable,
  });

  final bool playing;
  final bool continuing;
  final double? progressFraction;
  final int? displayDurationMs;
  final bool downloading;
  final bool downloaded;
  final bool retryable;

  String get playLabelKey => playing
      ? 'pause'
      : continuing
      ? 'podcast_continue'
      : 'play';
}

typedef _CachedSearch = ({DateTime at, List<PodcastShowSummary> shows});
