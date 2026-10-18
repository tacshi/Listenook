import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import '../core/podcast_models.dart';
import '../data/podcast/podcast_formatters.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import '../state/podcast_controller.dart';
import 'job_actions.dart';
import 'podcast_media_export.dart';
import 'podcast_episode_description.dart';
import 'podcast_now_playing.dart';

class PodcastPage extends StatefulWidget {
  const PodcastPage({super.key});

  @override
  State<PodcastPage> createState() => _PodcastPageState();
}

class _PodcastPageState extends State<PodcastPage> {
  final _search = TextEditingController();
  final _feedUrl = TextEditingController();
  final Set<String> _selectedLibraryJobIds = {};
  Timer? _debounce;
  bool _refreshed = false;
  bool _librarySelectionMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_open());
    });
  }

  Future<void> _open() async {
    final podcast = context.read<PodcastController>();
    if (!podcast.initialized) await podcast.initialize();
    if (!mounted || _refreshed) return;
    _refreshed = true;
    await podcast.refreshStaleFollowed();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _feedUrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final podcast = context.watch<PodcastController>();
    final strings = context.strings;
    return SafeArea(
      child: Padding(
        key: const Key('podcast-page-padding'),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (podcast.showsRootTabs) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<PodcastPane>(
                  key: const Key('podcast-root-tabs'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: PodcastPane.discover,
                      label: Text(strings.t('podcast_discover')),
                      icon: const Icon(Icons.search_rounded),
                    ),
                    ButtonSegment(
                      value: PodcastPane.following,
                      label: Text(
                        '${strings.t('podcast_following')} '
                        '(${podcast.followed.length})',
                      ),
                      icon: const Icon(Icons.bookmark_rounded),
                    ),
                    ButtonSegment(
                      value: PodcastPane.library,
                      label: Text(strings.t('podcast_library')),
                      icon: const Icon(Icons.download_done_rounded),
                    ),
                  ],
                  selected: {podcast.pane},
                  onSelectionChanged: (values) => podcast.setPane(values.first),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Expanded(child: _body(context, podcast)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, PodcastController podcast) {
    final strings = context.strings;
    if (podcast.openedFeed != null) {
      return Column(
        children: [
          if (podcast.errorCode != null) ...[
            _PodcastErrorBanner(
              message: strings.error(podcast.errorCode),
              onDismiss: podcast.clearError,
            ),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: podcast.openedEpisode == null
                ? _feedDetail(context, podcast, podcast.openedFeed!)
                : _episodeDetail(
                    context,
                    podcast,
                    podcast.openedFeed!,
                    podcast.openedEpisode!,
                  ),
          ),
        ],
      );
    }
    if (podcast.openedCollection != null) {
      return _collectionDetail(context, podcast, podcast.openedCollection!);
    }
    return switch (podcast.pane) {
      PodcastPane.discover => _discover(context, podcast),
      PodcastPane.following => _following(context, podcast),
      PodcastPane.library => _library(context, podcast),
    };
  }

  Widget _discover(BuildContext context, PodcastController podcast) {
    final strings = context.strings;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('podcast-search-field'),
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: strings.t('podcast_search_hint'),
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          key: const Key('podcast-search-clear'),
                          tooltip: strings.t('clear_search'),
                          onPressed: () {
                            _debounce?.cancel();
                            _search.clear();
                            setState(() {});
                            unawaited(podcast.search(''));
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
                onChanged: (value) {
                  _debounce?.cancel();
                  setState(() {});
                  _debounce = Timer(const Duration(milliseconds: 400), () {
                    unawaited(podcast.search(value));
                  });
                },
                onSubmitted: podcast.search,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const Key('podcast-feed-field'),
                controller: _feedUrl,
                decoration: InputDecoration(
                  hintText: strings.t('podcast_feed_hint'),
                  prefixIcon: const Icon(Icons.rss_feed_rounded),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_feedUrl.text.isNotEmpty)
                        IconButton(
                          key: const Key('podcast-feed-clear'),
                          tooltip: strings.t('podcast_clear_feed'),
                          onPressed: () {
                            _feedUrl.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                      IconButton(
                        key: const Key('podcast-feed-add'),
                        tooltip: strings.t('podcast_add_feed'),
                        onPressed: () => podcast.addFeedUrl(_feedUrl.text),
                        icon: const Icon(Icons.add_rounded),
                      ),
                    ],
                  ),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: podcast.addFeedUrl,
              ),
            ),
          ],
        ),
        if (podcast.errorCode != null) ...[
          const SizedBox(height: 10),
          _PodcastErrorBanner(
            message: strings.error(podcast.errorCode),
            onDismiss: podcast.clearError,
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: podcast.query.length >= 2
              ? _results(context, podcast)
              : _browse(context, podcast),
        ),
      ],
    );
  }

  Widget _following(BuildContext context, PodcastController podcast) {
    if (podcast.followed.isEmpty) {
      return Center(child: Text(context.strings.t('podcast_following_empty')));
    }
    return Column(
      children: [
        if (podcast.errorCode != null) ...[
          _PodcastErrorBanner(
            message: context.strings.error(podcast.errorCode),
            onDismiss: podcast.clearError,
          ),
          const SizedBox(height: 8),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const Key('podcast-refresh'),
            onPressed: podcast.loading ? null : podcast.refreshFollowedNow,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(context.strings.t('podcast_refresh')),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: podcast.followed.length,
            itemBuilder: (context, index) {
              final show = podcast.followed[index];
              return ListTile(
                key: ValueKey('followed-${show.feedUrl}'),
                leading: PodcastArtwork(
                  url: podcast.artworkForFollowed(show),
                  size: 48,
                  borderRadius: 8,
                ),
                title: Text(show.title),
                subtitle: Text(
                  show.unseenEpisodeCount == 0
                      ? (show.author ?? '')
                      : context.strings
                            .t('podcast_unseen')
                            .replaceFirst(
                              '{count}',
                              '${show.unseenEpisodeCount}',
                            ),
                ),
                onTap: () => unawaited(podcast.openFollowed(show)),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _library(BuildContext context, PodcastController podcast) {
    final app = context.watch<AppController>();
    final jobs = app.podcastJobs;
    final visibleIds = jobs.map((job) => job.id).toSet();
    final selectedJobs = jobs
        .where((job) => _selectedLibraryJobIds.contains(job.id))
        .toList(growable: false);
    final exportableJobs = selectedJobs
        .where(
          (job) =>
              app.localMediaPathForEpisode(
                job.podcastProvenance?.episodeId ?? job.id,
              ) !=
              null,
        )
        .toList(growable: false);
    final canRemoveSelected =
        selectedJobs.isNotEmpty && selectedJobs.every((job) => !job.isBusy);
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PodcastLibraryToolbar(
          selectionMode: _librarySelectionMode,
          selectedCount: selectedJobs.length,
          hasEpisodes: jobs.isNotEmpty,
          allSelected:
              jobs.isNotEmpty && _selectedLibraryJobIds.containsAll(visibleIds),
          onToggleSelection: () => setState(() {
            _librarySelectionMode = !_librarySelectionMode;
            _selectedLibraryJobIds.clear();
          }),
          onSelectAll: () => setState(() {
            if (_selectedLibraryJobIds.containsAll(visibleIds)) {
              _selectedLibraryJobIds.removeAll(visibleIds);
            } else {
              _selectedLibraryJobIds.addAll(visibleIds);
            }
          }),
          onExport: exportableJobs.isEmpty
              ? null
              : () => unawaited(
                  exportDownloadedPodcastMediaBatch(context, exportableJobs),
                ),
          onRemove: canRemoveSelected
              ? () => unawaited(_removePodcastJobs(selectedJobs))
              : null,
        ),
        const SizedBox(height: 10),
        Expanded(
          child: jobs.isEmpty
              ? Center(
                  child: Text(
                    key: const Key('podcast-library-empty'),
                    context.strings.t('podcast_library_empty'),
                  ),
                )
              : ListView.separated(
                  key: const Key('podcast-library-list'),
                  itemCount: jobs.length,
                  separatorBuilder: (context, index) => Divider(
                    height: 1,
                    color: colors.outlineVariant.withValues(alpha: 0.55),
                  ),
                  itemBuilder: (context, index) {
                    final job = jobs[index];
                    final provenance = job.podcastProvenance;
                    final episode = provenance == null
                        ? _episodeFromJob(job)
                        : podcast.hydrateEpisode(
                            provenance,
                            durationMs: job.metadata?.durationMs,
                          );
                    final feed = provenance == null
                        ? PodcastFeed(
                            feedUrl: '',
                            title: '',
                            episodes: [episode],
                            artworkUrl: episode.artworkUrl,
                          )
                        : podcast.cachedFeed(provenance.feedUrl) ??
                              provenance.toFeed(episode: episode);
                    return _libraryTile(
                      context,
                      podcast,
                      app,
                      job,
                      episode,
                      feed,
                      selectionMode: _librarySelectionMode,
                      selected: _selectedLibraryJobIds.contains(job.id),
                      onSelectedChanged: (selected) => setState(() {
                        if (selected) {
                          _selectedLibraryJobIds.add(job.id);
                        } else {
                          _selectedLibraryJobIds.remove(job.id);
                        }
                      }),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _libraryTile(
    BuildContext context,
    PodcastController podcast,
    AppController app,
    TranscriptionJob job,
    PodcastEpisode episode,
    PodcastFeed feed, {
    required bool selectionMode,
    required bool selected,
    required ValueChanged<bool> onSelectedChanged,
  }) {
    final display = podcast.episodeDisplayState(
      episode,
      job: job,
      downloaded: app.localMediaPathForEpisode(episode.id) != null,
    );
    final durationLabel = formatEpisodeLength(
      display.displayDurationMs,
      chinese: context.strings.isZh,
    );
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: ValueKey('library-episode-${episode.id}'),
      color: Colors.transparent,
      child: InkWell(
        onTap: selectionMode
            ? () => onSelectedChanged(!selected)
            : () => podcast.openEpisode(
                episode,
                feed: feed,
                captions: job.status == JobStatus.completed,
              ),
        hoverColor: colors.onSurface.withValues(alpha: 0.04),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 4, 12),
          child: Row(
            children: [
              if (selectionMode) ...[
                Checkbox(
                  key: ValueKey('select-podcast-library-job-${job.id}'),
                  value: selected,
                  onChanged: (value) => onSelectedChanged(value ?? false),
                ),
                const SizedBox(width: 4),
              ],
              PodcastArtwork(
                url: episode.artworkUrl ?? feed.artworkUrl,
                size: 56,
                borderRadius: 8,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      episode.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        feed.title,
                        context.strings.t(_libraryStatusKey(job.status)),
                      ].where((part) => part.trim().isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),
                    EpisodePlayButton(
                      episodeId: episode.id,
                      playing: display.playing,
                      durationLabel: durationLabel,
                      progress: display.progressFraction,
                      tooltip: context.strings.t(display.playLabelKey),
                      onPressed: () =>
                          _playEpisode(podcast, app, episode, feed),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (display.downloaded)
                IconButton(
                  key: ValueKey('library-export-media-${episode.id}'),
                  tooltip: context.strings.t('podcast_export_media'),
                  onPressed: () =>
                      unawaited(exportDownloadedPodcastMedia(context, job)),
                  icon: const Icon(Icons.ios_share_rounded),
                ),
              if (!selectionMode)
                PopupMenuButton<String>(
                  key: ValueKey('podcast-library-menu-${job.id}'),
                  onSelected: (value) {
                    if (value == 'remove') {
                      unawaited(_removePodcastJobs([job]));
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'remove',
                      enabled: !job.isBusy,
                      child: Text(
                        context.strings.t('remove'),
                        style: !job.isBusy
                            ? TextStyle(color: colors.error)
                            : null,
                      ),
                    ),
                  ],
                ),
              Tooltip(
                message: _actionLabel(context, job),
                child: FilledButton.tonal(
                  key: ValueKey('library-deep-listen-${episode.id}'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _canUseDeepListen(job)
                      ? () => _deepListen(app, feed, episode, job)
                      : null,
                  child: Text(_actionLabel(context, job)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _removePodcastJobs(Iterable<TranscriptionJob> jobs) async {
    final items = jobs.toList(growable: false);
    final removed = await confirmAndRemoveLibraryJobs(context, items);
    if (!removed || !mounted) return;
    final removedIds = items.map((job) => job.id).toSet();
    setState(() => _selectedLibraryJobIds.removeAll(removedIds));
  }

  PodcastEpisode _episodeFromJob(TranscriptionJob job) {
    final name = job.fileName;
    final dot = name.lastIndexOf('.');
    final extension = dot <= 0 ? 'mp3' : name.substring(dot + 1);
    return PodcastEpisode(
      id: job.podcastProvenance?.episodeId ?? job.id,
      feedUrl: job.podcastProvenance?.feedUrl ?? '',
      title: job.displayName,
      enclosureUrl: job.podcastProvenance?.enclosureUrl ?? '',
      mediaExtension: extension,
      durationMs: job.metadata?.durationMs,
      artworkUrl: job.podcastProvenance?.artworkUrl,
    );
  }

  String _libraryStatusKey(JobStatus status) {
    if (status == JobStatus.downloading) return 'podcast_downloading';
    if (status == JobStatus.completed) return 'podcast_status_transcribed';
    if (status.isActive) return 'podcast_status_transcribing';
    if (status == JobStatus.failed || status == JobStatus.missingSource) {
      return 'failed';
    }
    return 'podcast_status_downloaded';
  }

  Widget _browse(BuildContext context, PodcastController podcast) {
    if (podcast.browseLoading &&
        podcast.featured.isEmpty &&
        podcast.popular.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      key: const Key('podcast-browse'),
      children: [
        if (podcast.featured.isNotEmpty) ...[
          _sectionTitle(context, context.strings.t('podcast_featured_english')),
          _artworkStrip(context, podcast, podcast.featured),
          const SizedBox(height: 28),
        ],
        if (podcast.popular.isNotEmpty) ...[
          _sectionTitle(context, context.strings.t('podcast_popular')),
          _artworkStrip(context, podcast, podcast.popular),
          const SizedBox(height: 28),
        ],
        _sectionTitle(context, context.strings.t('podcast_listen_by_scene')),
        _collectionGrid(context, podcast),
        const SizedBox(height: 12),
        Text(
          context.strings.t('podcast_apple_attribution'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
  );

  Widget _artworkStrip(
    BuildContext context,
    PodcastController podcast,
    List<PodcastShowSummary> shows,
  ) {
    const cover = 140.0;
    return SizedBox(
      height: cover + 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: shows.length,
        separatorBuilder: (context, index) => const SizedBox(width: 16),
        itemBuilder: (context, index) {
          final show = shows[index];
          return SizedBox(
            width: cover,
            child: InkWell(
              key: ValueKey('browse-show-${show.id}'),
              onTap: () => podcast.openShow(show),
              borderRadius: BorderRadius.circular(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PodcastArtwork(
                    url: show.artworkUrl,
                    size: cover,
                    borderRadius: 12,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    show.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _collectionGrid(BuildContext context, PodcastController podcast) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 3
            : constraints.maxWidth >= 620
            ? 2
            : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: podcastListenCollections.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.92,
          ),
          itemBuilder: (context, index) {
            final collection = podcastListenCollections[index];
            final shows = podcast.collections[collection.id] ?? const [];
            return _CollectionTile(
              collection: collection,
              shows: shows,
              onTap: () => podcast.openCollection(collection),
            );
          },
        );
      },
    );
  }

  Widget _collectionDetail(
    BuildContext context,
    PodcastController podcast,
    PodcastListenCollection collection,
  ) {
    final shows = podcast.collections[collection.id] ?? const [];
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: context.strings.t('podcast_back'),
              onPressed: podcast.closeCollection,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Expanded(
              child: Text(
                context.strings.t(collection.labelKey),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        if (podcast.browseLoading && shows.isEmpty)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(child: _showList(context, podcast, shows)),
      ],
    );
  }

  Widget _results(BuildContext context, PodcastController podcast) {
    if (podcast.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (podcast.results.isEmpty) {
      return Center(child: Text(context.strings.t('podcast_empty_results')));
    }
    return _showList(context, podcast, podcast.results);
  }

  Widget _showList(
    BuildContext context,
    PodcastController podcast,
    List<PodcastShowSummary> shows,
  ) => ListView.builder(
    itemCount: shows.length,
    itemBuilder: (context, index) {
      final show = shows[index];
      return ListTile(
        key: ValueKey('show-${show.id}'),
        leading: PodcastArtwork(url: show.artworkUrl, size: 48),
        title: Text(show.title),
        subtitle: Text(show.author ?? ''),
        onTap: () => podcast.openShow(show),
      );
    },
  );

  Widget _feedDetail(
    BuildContext context,
    PodcastController podcast,
    PodcastFeed feed,
  ) {
    final followed = podcast.isFollowed(feed.feedUrl);
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('podcast-back'),
              tooltip: context.strings.t('podcast_back'),
              onPressed: podcast.closeOpenedFeed,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PodcastArtwork(url: feed.artworkUrl, size: 88, borderRadius: 10),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      feed.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (feed.author != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        feed.author!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton(
                          key: const Key('podcast-follow'),
                          onPressed: followed
                              ? () => podcast.unfollow(feed.feedUrl)
                              : podcast.followOpenedFeed,
                          child: Text(
                            followed
                                ? context.strings.t('podcast_unfollow')
                                : context.strings.t('podcast_follow'),
                          ),
                        ),
                        if (feed.showUrl != null)
                          IconButton(
                            tooltip: context.strings.t('podcast_open_show'),
                            onPressed: () =>
                                launchUrl(Uri.parse(feed.showUrl!)),
                            icon: const Icon(Icons.open_in_new_rounded),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: ListView.separated(
            itemCount: feed.episodes.length,
            separatorBuilder: (context, index) => Divider(
              height: 1,
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
            itemBuilder: (context, index) =>
                _episodeTile(context, feed, feed.episodes[index]),
          ),
        ),
      ],
    );
  }

  Widget _episodeTile(
    BuildContext context,
    PodcastFeed feed,
    PodcastEpisode episode,
  ) {
    final app = context.watch<AppController>();
    final podcast = context.read<PodcastController>();
    final job = app.jobForEpisode(episode.id);
    final display = podcast.episodeDisplayState(
      episode,
      job: job,
      downloaded: app.localMediaPathForEpisode(episode.id) != null,
    );
    final durationLabel = formatEpisodeLength(
      display.displayDurationMs,
      chinese: context.strings.isZh,
    );
    final subtitle = _episodeSubtitle(context, episode);
    final uniqueArt = _hasUniqueEpisodeArt(episode, feed);
    return _EpisodeRow(
      episodeId: episode.id,
      artworkUrl: uniqueArt ? episode.artworkUrl : null,
      title: episode.title,
      subtitle: subtitle,
      playing: display.playing,
      durationLabel: durationLabel,
      progress: display.progressFraction,
      playTooltip: context.strings.t(display.playLabelKey),
      onPlay: () => _playEpisode(podcast, app, episode, feed),
      onOpen: _hasEpisodeDetails(episode)
          ? () => podcast.openEpisode(episode)
          : null,
      showActions: display.downloading,
      actions: [
        EpisodeDownloadButton(
          episodeId: episode.id,
          tooltip: _downloadTooltip(context, job),
          busy: display.downloading,
          done: display.downloaded,
          failed: display.retryable,
          onPressed: _canDownload(app, job, episode)
              ? () => unawaited(_downloadEpisode(app, feed, episode, job))
              : null,
        ),
        if (display.downloaded && job != null)
          IconButton(
            key: ValueKey('episode-export-media-${episode.id}'),
            tooltip: context.strings.t('podcast_export_media'),
            onPressed: () =>
                unawaited(exportDownloadedPodcastMedia(context, job)),
            icon: const Icon(Icons.ios_share_rounded),
          ),
        Tooltip(
          message: _actionLabel(context, job),
          child: FilledButton.tonal(
            key: ValueKey('deep-listen-${episode.id}'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _canUseDeepListen(job)
                ? () => _deepListen(app, feed, episode, job)
                : null,
            child: Text(_actionLabel(context, job)),
          ),
        ),
      ],
    );
  }

  bool _hasEpisodeDetails(PodcastEpisode episode) =>
      (episode.description?.trim().isNotEmpty ?? false);

  Widget _episodeDetail(
    BuildContext context,
    PodcastController podcast,
    PodcastFeed feed,
    PodcastEpisode episode,
  ) {
    final app = context.watch<AppController>();
    final job = app.jobForEpisode(episode.id);
    final display = podcast.episodeDisplayState(
      episode,
      job: job,
      downloaded: app.localMediaPathForEpisode(episode.id) != null,
    );
    final player = podcast.playback;
    final durationLabel = formatEpisodeLength(
      display.displayDurationMs,
      chinese: context.strings.isZh,
    );
    final colors = Theme.of(context).colorScheme;
    final date = episode.publishedAt == null
        ? null
        : MaterialLocalizations.of(
            context,
          ).formatMediumDate(episode.publishedAt!.toLocal());
    final canShowCaptions =
        job?.status == JobStatus.completed ||
        player.cues.isNotEmpty ||
        player.loadingCues;
    final showCaptions = podcast.captionsOpen && canShowCaptions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('podcast-episode-back'),
              tooltip: context.strings.t('podcast_back'),
              onPressed: podcast.closeOpenedEpisode,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            const Spacer(),
            if (canShowCaptions)
              IconButton(
                key: const Key('podcast-captions-toggle'),
                tooltip: context.strings.t(
                  podcast.captionsOpen
                      ? 'podcast_hide_captions'
                      : 'podcast_show_captions',
                ),
                onPressed: () => podcast.setCaptionsOpen(!podcast.captionsOpen),
                icon: Icon(
                  podcast.captionsOpen
                      ? Icons.chevron_right_rounded
                      : Icons.subtitles_outlined,
                ),
              ),
          ],
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final panelWidth = (constraints.maxWidth * 0.42).clamp(
                300.0,
                460.0,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            PodcastArtwork(
                              url: episode.artworkUrl ?? feed.artworkUrl,
                              size: 220,
                            ),
                            const SizedBox(width: 24),
                            Expanded(
                              child: SizedBox(
                                height: 220,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (date != null)
                                      Text(
                                        date,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    if (date != null) const SizedBox(height: 8),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            episode.title,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                  height: 1.2,
                                                ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        EpisodeDownloadButton(
                                          episodeId: episode.id,
                                          tooltip: _downloadTooltip(
                                            context,
                                            job,
                                          ),
                                          busy:
                                              job?.status ==
                                              JobStatus.downloading,
                                          done:
                                              app.localMediaPathForEpisode(
                                                episode.id,
                                              ) !=
                                              null,
                                          failed: _downloadFailed(job),
                                          onPressed:
                                              _canDownload(app, job, episode)
                                              ? () => unawaited(
                                                  _downloadEpisode(
                                                    app,
                                                    feed,
                                                    episode,
                                                    job,
                                                  ),
                                                )
                                              : null,
                                        ),
                                        if (display.downloaded && job != null)
                                          IconButton(
                                            key: ValueKey(
                                              'episode-detail-export-media-${episode.id}',
                                            ),
                                            tooltip: context.strings.t(
                                              'podcast_export_media',
                                            ),
                                            visualDensity:
                                                VisualDensity.compact,
                                            style: IconButton.styleFrom(
                                              minimumSize: const Size(36, 36),
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                            ),
                                            onPressed: () => unawaited(
                                              exportDownloadedPodcastMedia(
                                                context,
                                                job,
                                              ),
                                            ),
                                            icon: const Icon(
                                              Icons.ios_share_rounded,
                                              size: 20,
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        PodcastArtwork(
                                          url: feed.artworkUrl,
                                          size: 28,
                                          borderRadius: 4,
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            feed.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const Spacer(),
                                    Row(
                                      children: [
                                        EpisodePlayButton(
                                          episodeId: episode.id,
                                          playing: display.playing,
                                          durationLabel: durationLabel,
                                          progress: display.progressFraction,
                                          tooltip: context.strings.t(
                                            display.playLabelKey,
                                          ),
                                          onPressed: () {
                                            _playEpisode(
                                              podcast,
                                              app,
                                              episode,
                                              feed,
                                            );
                                            if (canShowCaptions) {
                                              podcast.setCaptionsOpen(true);
                                            }
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          key: ValueKey(
                                            'deep-listen-detail-${episode.id}',
                                          ),
                                          tooltip: _actionLabel(context, job),
                                          onPressed: _canUseDeepListen(job)
                                              ? () => _deepListen(
                                                  app,
                                                  feed,
                                                  episode,
                                                  job,
                                                )
                                              : null,
                                          icon: Icon(_actionIcon(job)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (episode.description?.trim().isNotEmpty ??
                            false) ...[
                          const SizedBox(height: 28),
                          PodcastEpisodeDescription(
                            description: episode.description!,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (showCaptions) ...[
                    VerticalDivider(
                      width: 1,
                      color: colors.outlineVariant.withValues(alpha: 0.6),
                    ),
                    SizedBox(
                      width: panelWidth,
                      child: Column(
                        children: [
                          Expanded(
                            child: PodcastCaptionPane(
                              player: player,
                              document: job?.document,
                              episodeId: episode.id,
                              hasCompletedTranscript:
                                  job?.status == JobStatus.completed,
                              compact: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  bool _hasUniqueEpisodeArt(PodcastEpisode episode, PodcastFeed feed) {
    final episodeArt = episode.artworkUrl?.trim() ?? '';
    final showArt = feed.artworkUrl?.trim() ?? '';
    return episodeArt.isNotEmpty && episodeArt != showArt;
  }

  String _episodeSubtitle(BuildContext context, PodcastEpisode episode) {
    final parts = <String>[
      if (episode.publishedAt != null)
        MaterialLocalizations.of(
          context,
        ).formatMediumDate(episode.publishedAt!.toLocal()),
      if (episode.transcripts.isNotEmpty)
        context.strings.t('podcast_has_captions'),
    ];
    return parts.join(' · ');
  }

  String _actionLabel(BuildContext context, TranscriptionJob? job) {
    if (job == null || job.status == JobStatus.downloading) {
      return context.strings.t('podcast_deep_listen');
    }
    if (job.status == JobStatus.completed) {
      return context.strings.t('podcast_open_workspace');
    }
    return context.strings.t('podcast_open_inbox');
  }

  IconData _actionIcon(TranscriptionJob? job) {
    if (job == null || job.status == JobStatus.downloading) {
      return Icons.auto_stories_rounded;
    }
    if (job.status == JobStatus.completed) {
      return Icons.space_dashboard_rounded;
    }
    return Icons.inbox_outlined;
  }

  bool _canUseDeepListen(TranscriptionJob? job) =>
      job?.status != JobStatus.downloading;

  String _downloadTooltip(BuildContext context, TranscriptionJob? job) {
    if (job?.status == JobStatus.downloading) {
      return context.strings.t('podcast_downloading');
    }
    if (_downloadFailed(job)) {
      return context.strings.t('podcast_retry_download');
    }
    if (job != null) return context.strings.t('podcast_downloaded');
    return context.strings.t('podcast_download');
  }

  bool _downloadFailed(TranscriptionJob? job) =>
      job != null && job.status.canRetry;

  bool _canDownload(
    AppController app,
    TranscriptionJob? job,
    PodcastEpisode episode,
  ) {
    if (job?.status == JobStatus.downloading) return false;
    if (app.localMediaPathForEpisode(episode.id) != null) return false;
    return job == null || job.status.canRetry;
  }

  Future<void> _downloadEpisode(
    AppController app,
    PodcastFeed feed,
    PodcastEpisode episode,
    TranscriptionJob? job,
  ) async {
    if (!_canDownload(app, job, episode)) return;
    if (job != null && job.status.canRetry) {
      await app.retry(job.id);
      return;
    }
    await app.enqueuePodcastEpisode(episode, feed: feed);
  }

  void _playEpisode(
    PodcastController podcast,
    AppController app,
    PodcastEpisode episode,
    PodcastFeed feed,
  ) {
    final job = app.jobForEpisode(episode.id);
    unawaited(
      podcast.playEpisode(
        episode,
        feed,
        document: job?.document,
        localPath: app.localMediaPathForEpisode(episode.id),
      ),
    );
  }

  Future<void> _deepListen(
    AppController app,
    PodcastFeed feed,
    PodcastEpisode episode,
    TranscriptionJob? job,
  ) async {
    if (job == null) {
      await app.enqueuePodcastEpisode(episode, feed: feed);
      app.setDestination(AppDestination.inbox);
      return;
    }
    if (job.status == JobStatus.completed) {
      app.openInWorkspace(job.id);
      return;
    }
    app.setDestination(AppDestination.inbox);
  }
}

class _PodcastLibraryToolbar extends StatelessWidget {
  const _PodcastLibraryToolbar({
    required this.selectionMode,
    required this.selectedCount,
    required this.hasEpisodes,
    required this.allSelected,
    required this.onToggleSelection,
    required this.onSelectAll,
    required this.onExport,
    required this.onRemove,
  });

  final bool selectionMode;
  final int selectedCount;
  final bool hasEpisodes;
  final bool allSelected;
  final VoidCallback onToggleSelection;
  final VoidCallback onSelectAll;
  final VoidCallback? onExport;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('podcast-library-toolbar'),
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          if (selectionMode) ...[
            Text(
              context.strings
                  .t('selected_count')
                  .replaceFirst('{count}', '$selectedCount'),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              key: const Key('podcast-library-select-all'),
              onPressed: hasEpisodes ? onSelectAll : null,
              icon: Icon(
                allSelected
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 18,
              ),
              label: Text(context.strings.t('select_all_visible')),
            ),
            const Spacer(),
            OutlinedButton.icon(
              key: const Key('batch-export-podcast-media'),
              onPressed: onExport,
              icon: const Icon(Icons.ios_share_rounded),
              label: Text(context.strings.t('export')),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const Key('batch-remove-podcast-jobs'),
              tooltip: context.strings.t('remove_selected'),
              style: IconButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
            const SizedBox(width: 8),
          ] else
            const Spacer(),
          OutlinedButton.icon(
            key: const Key('toggle-podcast-library-selection'),
            onPressed: hasEpisodes ? onToggleSelection : null,
            icon: Icon(
              selectionMode ? Icons.close_rounded : Icons.checklist_rounded,
            ),
            label: Text(context.strings.t(selectionMode ? 'done' : 'select')),
          ),
        ],
      ),
    ),
  );
}

class _PodcastErrorBanner extends StatelessWidget {
  const _PodcastErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 2, 6),
        child: Row(
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: colors.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onErrorContainer,
                ),
              ),
            ),
            IconButton(
              tooltip: context.strings.t('close'),
              onPressed: onDismiss,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, color: colors.onErrorContainer),
            ),
          ],
        ),
      ),
    );
  }
}

class PodcastArtwork extends StatelessWidget {
  const PodcastArtwork({
    super.key,
    required this.url,
    required this.size,
    this.expand = false,
    this.borderRadius = 0,
  });

  final String? url;
  final double size;
  final bool expand;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final image = url == null || url!.isEmpty
        ? ColoredBox(
            color: color.surfaceContainerHighest,
            child: Icon(Icons.podcasts_rounded, color: color.primary),
          )
        : Image.network(
            url!,
            fit: BoxFit.cover,
            width: expand ? double.infinity : size,
            height: expand ? double.infinity : size,
            errorBuilder: (context, error, stack) => ColoredBox(
              color: color.surfaceContainerHighest,
              child: Icon(Icons.podcasts_rounded, color: color.primary),
            ),
          );
    final frame = expand
        ? SizedBox.expand(child: image)
        : SizedBox(width: size, height: size, child: image);
    final child = borderRadius <= 0
        ? frame
        : ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: frame,
          );
    if (expand) return child;
    return Align(
      alignment: Alignment.topLeft,
      widthFactor: 1,
      heightFactor: 1,
      child: child,
    );
  }
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({
    required this.collection,
    required this.shows,
    required this.onTap,
  });

  final PodcastListenCollection collection;
  final List<PodcastShowSummary> shows;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final art = shows.take(9).toList();
    return InkWell(
      key: ValueKey('collection-${collection.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: art.isEmpty
                  ? ColoredBox(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: const Center(child: Icon(Icons.podcasts_outlined)),
                    )
                  : GridView.count(
                      crossAxisCount: 3,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      mainAxisSpacing: 2,
                      crossAxisSpacing: 2,
                      children: [
                        for (var index = 0; index < 9; index++)
                          index < art.length
                              ? PodcastArtwork(
                                  url: art[index].artworkUrl,
                                  size: 72,
                                  expand: true,
                                )
                              : ColoredBox(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.strings.t(collection.labelKey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _EpisodeRow extends StatefulWidget {
  const _EpisodeRow({
    required this.episodeId,
    required this.title,
    required this.subtitle,
    required this.playing,
    required this.playTooltip,
    required this.actions,
    this.artworkUrl,
    this.durationLabel,
    this.progress,
    this.onPlay,
    this.onOpen,
    this.showActions = false,
  });

  final String episodeId;
  final String? artworkUrl;
  final String title;
  final String subtitle;
  final bool playing;
  final String? durationLabel;
  final double? progress;
  final String playTooltip;
  final VoidCallback? onPlay;
  final VoidCallback? onOpen;
  final bool showActions;
  final List<Widget> actions;

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> {
  var _hovered = false;
  var _focused = false;

  bool get _actionsVisible => widget.showActions || _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: Material(
          key: ValueKey('episode-${widget.episodeId}'),
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onOpen,
            hoverColor: colors.onSurface.withValues(alpha: 0.04),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 4, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (widget.artworkUrl != null) ...[
                    PodcastArtwork(
                      url: widget.artworkUrl,
                      size: 72,
                      borderRadius: 10,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                height: 1.25,
                              ),
                        ),
                        if (widget.subtitle.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            widget.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 11,
                                  height: 1.2,
                                ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        EpisodePlayButton(
                          episodeId: widget.episodeId,
                          playing: widget.playing,
                          durationLabel: widget.durationLabel,
                          progress: widget.progress,
                          tooltip: widget.playTooltip,
                          onPressed: widget.onPlay,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Visibility(
                    key: ValueKey('episode-actions-${widget.episodeId}'),
                    visible: _actionsVisible,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: widget.actions,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class EpisodeDownloadButton extends StatelessWidget {
  const EpisodeDownloadButton({
    super.key,
    required this.episodeId,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
    this.done = false,
    this.failed = false,
  });

  final String episodeId;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool busy;
  final bool done;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final icon = busy
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.onSurfaceVariant,
            ),
          )
        : Icon(
            failed
                ? Icons.refresh_rounded
                : done
                ? Icons.download_done_rounded
                : Icons.download_rounded,
            size: 20,
          );
    return IconButton(
      key: ValueKey('episode-download-$episodeId'),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        foregroundColor: done ? colors.outline : colors.onSurfaceVariant,
        minimumSize: const Size(36, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: icon,
    );
  }
}

class EpisodePlayButton extends StatelessWidget {
  const EpisodePlayButton({
    super.key,
    required this.episodeId,
    required this.playing,
    required this.durationLabel,
    required this.tooltip,
    required this.onPressed,
    this.progress,
  });

  final String episodeId;
  final bool playing;
  final String? durationLabel;
  final double? progress;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = FilledButton.styleFrom(
      backgroundColor: colors.surfaceContainerHighest,
      foregroundColor: colors.onSurface,
      disabledBackgroundColor: colors.surfaceContainerHighest,
      disabledForegroundColor: colors.onSurface.withValues(alpha: 0.38),
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
    );
    return Tooltip(
      message: tooltip,
      child: FilledButton(
        key: ValueKey('preview-$episodeId'),
        style: style,
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 18,
            ),
            if (progress != null) ...[
              const SizedBox(width: 8),
              _EpisodeProgressBar(progress: progress!, color: colors.onSurface),
            ],
            if (durationLabel != null) ...[
              const SizedBox(width: 8),
              Text(durationLabel!),
            ],
          ],
        ),
      ),
    );
  }
}

class _EpisodeProgressBar extends StatelessWidget {
  const _EpisodeProgressBar({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('episode-continue-progress'),
      width: 28,
      height: 4,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: progress.clamp(0.08, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(99),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}
