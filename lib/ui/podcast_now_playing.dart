import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../core/models.dart';
import '../data/transcript_exporter.dart';
import '../data/podcast/podcast_formatters.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import '../state/podcast_controller.dart';
import '../state/podcast_player.dart';
import 'transcript_review.dart';

class PodcastNowPlaying extends StatelessWidget {
  const PodcastNowPlaying({super.key});

  @override
  Widget build(BuildContext context) {
    final podcast = context.watch<PodcastController>();
    return ListenableBuilder(
      listenable: podcast.playback,
      builder: (context, _) => _build(context, podcast),
    );
  }

  Widget _build(BuildContext context, PodcastController podcast) {
    final player = podcast.playback;
    final app = Provider.of<AppController>(context, listen: false);
    final episode = player.episode;
    final job = context.select(
      (AppController c) => episode == null ? null : c.jobForEpisode(episode.id),
    );
    if (episode == null) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    key: const Key('podcast-now-playing-collapse'),
                    tooltip: context.strings.t('podcast_collapse_player'),
                    onPressed: player.collapse,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 10),
                        Text(
                          episode.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (player.feed?.title != null)
                          Text(
                            player.feed!.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                      ],
                    ),
                  ),
                  if (job?.status == JobStatus.completed)
                    TextButton(
                      onPressed: () {
                        player.collapse();
                        app.openInWorkspace(job!.id);
                      },
                      child: Text(context.strings.t('podcast_open_workspace')),
                    )
                  else
                    FilledButton.tonal(
                      onPressed: () {
                        player.collapse();
                        final current = player.episode;
                        final feed = player.feed;
                        if (job == null && current != null && feed != null) {
                          unawaited(
                            app.enqueuePodcastEpisode(current, feed: feed),
                          );
                        }
                        app.setDestination(AppDestination.inbox);
                      },
                      child: Text(context.strings.t('podcast_deep_listen')),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: PodcastCaptionPane(
                  player: player,
                  hasCompletedTranscript: job?.status == JobStatus.completed,
                ),
              ),
              PodcastSeekBar(
                position: player.position,
                duration: player.duration,
                onSeek: player.seek,
              ),
              const SizedBox(height: 4),
              _Transport(player: player),
            ],
          ),
        ),
      ),
    );
  }
}

class PodcastCaptionPane extends StatefulWidget {
  const PodcastCaptionPane({
    super.key,
    required this.player,
    required this.hasCompletedTranscript,
    this.document,
    this.episodeId,
    this.compact = false,
  });

  final PodcastPlayer player;
  final bool hasCompletedTranscript;
  final TranscriptDocument? document;
  final String? episodeId;
  final bool compact;

  @override
  State<PodcastCaptionPane> createState() => _PodcastCaptionPaneState();
}

class _PodcastCaptionPaneState extends State<PodcastCaptionPane>
    with SingleTickerProviderStateMixin {
  final _scroll = ItemScrollController();
  late final Ticker _ticker;
  var _lastScrolled = -1;
  var _scrollQueued = false;
  var _seenCue = -2;
  int? _seenTokenStart;

  bool get _live =>
      widget.episodeId == null || widget.player.episode?.id == widget.episodeId;

  List<PodcastPlayerCue> get _cues {
    if (_live && widget.player.cues.isNotEmpty) return widget.player.cues;
    return PodcastPlayer.cuesFrom(widget.document);
  }

  int get _positionMs {
    if (_live) return widget.player.displayPositionMs;
    final episodeId = widget.episodeId;
    if (episodeId == null) return 0;
    return widget.player.storedPositionMs(episodeId);
  }

  int get _cueIndex => PodcastPlayer.cueIndexAt(_cues, _positionMs);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_handleTick);
    _syncTicker();
    _queueScroll();
  }

  @override
  void didUpdateWidget(PodcastCaptionPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) _lastScrolled = -1;
    _syncTicker();
    if (_cueIndex != _lastScrolled) _queueScroll();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _syncTicker() {
    final shouldRun = _live && widget.player.playing && _cues.isNotEmpty;
    if (shouldRun) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  void _handleTick(Duration _) {
    if (!mounted) return;
    final positionMs = _positionMs;
    final cueIndex = PodcastPlayer.cueIndexAt(_cues, positionMs);
    final tokenStart = _tokenStartAt(cueIndex, positionMs);
    if (cueIndex == _seenCue && tokenStart == _seenTokenStart) return;
    setState(() {
      _seenCue = cueIndex;
      _seenTokenStart = tokenStart;
    });
    if (cueIndex != _lastScrolled) _queueScroll();
  }

  int? _tokenStartAt(int cueIndex, int positionMs) {
    if (cueIndex < 0 || cueIndex >= _cues.length) return null;
    final tokens = _cues[cueIndex].tokens;
    int? start;
    for (final token in tokens) {
      if (token.startMs == 0 && token.endMs == 0 && token.segmentId == null) {
        continue;
      }
      if (token.startMs > positionMs) break;
      start = token.startMs;
    }
    return start;
  }

  void _queueScroll() {
    if (_scrollQueued) return;
    _scrollQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollQueued = false;
      if (mounted) unawaited(_scrollToCurrent());
    });
  }

  Future<void> _scrollToCurrent() async {
    if (!_scroll.isAttached) return;
    final index = _cueIndex;
    if (index < 0 || index == _lastScrolled) return;
    _lastScrolled = index;
    _scroll.jumpTo(index: index, alignment: index == 0 ? 0 : 0.4);
  }

  @override
  Widget build(BuildContext context) {
    final cues = _cues;
    if (widget.player.loadingCues && cues.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (cues.isEmpty) {
      return Center(
        child: Text(
          context.strings.t('podcast_no_captions'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final cueIndex = _cueIndex;
    final positionMs = _positionMs;
    final sidePad = widget.compact ? 20.0 : 96.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: sidePad),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.compact ? 560 : 680),
          child: ScrollablePositionedList.builder(
            itemScrollController: _scroll,
            itemCount: cues.length,
            itemBuilder: (context, index) {
              final cue = cues[index];
              final current = index == cueIndex;
              final nearby = (index - cueIndex).abs() == 1;
              final style = Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                color: current
                    ? Theme.of(context).colorScheme.onSurface
                    : nearby
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.outline,
              );
              return InkWell(
                onTap: () {
                  _lastScrolled = -1;
                  widget.player.seekToCue(cue);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 12,
                  ),
                  child: PlaybackHighlightedText(
                    text: cue.text,
                    tokens: cue.tokens,
                    positionMs: positionMs,
                    segmentStartMs: cue.startMs,
                    segmentEndMs: cue.endMs,
                    enabled: current,
                    textAlign: widget.compact
                        ? TextAlign.start
                        : TextAlign.center,
                    style: style,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class PodcastSeekBar extends StatefulWidget {
  const PodcastSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.compact = false,
    this.positionKey = const Key('podcast-now-playing-position'),
    this.durationKey = const Key('podcast-now-playing-duration'),
    this.seekKey = const Key('podcast-now-playing-seek'),
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final bool compact;
  final Key positionKey;
  final Key durationKey;
  final Key seekKey;

  @override
  State<PodcastSeekBar> createState() => _PodcastSeekBarState();
}

class _PodcastSeekBarState extends State<PodcastSeekBar> {
  double get _trackHeight => widget.compact ? 4.0 : 6.0;
  double get _hitHeight => widget.compact ? 22.0 : 36.0;
  double get _thumb => widget.compact ? 10.0 : 14.0;
  double get _thumbActive => widget.compact ? 14.0 : 18.0;

  double? _scrubFraction;
  bool _hovering = false;
  bool _dragging = false;

  bool get _enabled => widget.duration.inMilliseconds > 0;

  double get _progress {
    if (_scrubFraction != null) return _scrubFraction!;
    if (!_enabled) return 0;
    return (widget.position.inMilliseconds / widget.duration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  int get _displayMs {
    if (_scrubFraction != null) {
      return (widget.duration.inMilliseconds * _scrubFraction!).round();
    }
    return widget.position.inMilliseconds;
  }

  void _seekAt(double dx, double width) {
    if (!_enabled || width <= 0) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    setState(() => _scrubFraction = fraction);
    widget.onSeek(
      Duration(
        milliseconds: (widget.duration.inMilliseconds * fraction).round(),
      ),
    );
  }

  void _endScrub() {
    if (_scrubFraction == null && !_dragging) return;
    setState(() {
      _scrubFraction = null;
      _dragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final timeStyle =
        (widget.compact
                ? Theme.of(context).textTheme.labelSmall
                : Theme.of(context).textTheme.labelMedium)
            ?.copyWith(
              color: colors.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
            );
    final wide = widget.duration.inHours > 0;
    final active = _hovering || _dragging;
    final thumbSize = active ? _thumbActive : _thumb;
    final trackColor = widget.compact
        ? colors.onSurface.withValues(alpha: 0.14)
        : colors.surfaceContainerHighest;
    final thumbBorder = widget.compact
        ? colors.surfaceContainerHigh
        : colors.surface;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 4),
      child: Row(
        children: [
          _ClockLabel(
            milliseconds: _displayMs,
            width: wide
                ? (widget.compact ? 56.0 : 64.0)
                : (widget.compact ? 40.0 : 46.0),
            align: TextAlign.right,
            style: timeStyle,
            labelKey: widget.positionKey,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: MouseRegion(
              cursor: _enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onEnter: (_) => setState(() => _hovering = true),
              onExit: (_) => setState(() => _hovering = false),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return GestureDetector(
                    key: widget.seekKey,
                    behavior: HitTestBehavior.opaque,
                    onTapDown: _enabled
                        ? (details) => _seekAt(details.localPosition.dx, width)
                        : null,
                    onTapUp: _enabled ? (_) => _endScrub() : null,
                    onTapCancel: _enabled ? _endScrub : null,
                    onHorizontalDragStart: _enabled
                        ? (details) {
                            _dragging = true;
                            _seekAt(details.localPosition.dx, width);
                          }
                        : null,
                    onHorizontalDragUpdate: _enabled
                        ? (details) => _seekAt(details.localPosition.dx, width)
                        : null,
                    onHorizontalDragEnd: _enabled ? (_) => _endScrub() : null,
                    child: SizedBox(
                      height: _hitHeight,
                      width: width,
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            height: _trackHeight,
                            decoration: BoxDecoration(
                              color: trackColor,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: _progress,
                              child: Container(
                                height: _trackHeight,
                                decoration: BoxDecoration(
                                  color: colors.primary,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                              ),
                            ),
                          ),
                          if (_enabled)
                            Positioned(
                              left: (width * _progress - thumbSize / 2).clamp(
                                0.0,
                                width - thumbSize,
                              ),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 80),
                                width: thumbSize,
                                height: thumbSize,
                                decoration: BoxDecoration(
                                  color: colors.primary,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: thumbBorder,
                                    width: widget.compact ? 1.5 : 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: colors.shadow.withValues(
                                        alpha: 0.2,
                                      ),
                                      blurRadius: active ? 8 : 4,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 10),
          _ClockLabel(
            milliseconds: widget.duration.inMilliseconds,
            width: wide
                ? (widget.compact ? 56.0 : 64.0)
                : (widget.compact ? 40.0 : 46.0),
            align: TextAlign.left,
            style: timeStyle,
            labelKey: widget.durationKey,
          ),
        ],
      ),
    );
  }
}

class _ClockLabel extends StatelessWidget {
  const _ClockLabel({
    required this.milliseconds,
    required this.width,
    required this.align,
    required this.style,
    required this.labelKey,
  });

  final int milliseconds;
  final double width;
  final TextAlign align;
  final TextStyle? style;
  final Key labelKey;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        formatClock(milliseconds),
        key: labelKey,
        textAlign: align,
        maxLines: 1,
        style: style,
      ),
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.player});

  final PodcastPlayer player;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _SkipButton(
              tooltip: context.strings.t('podcast_skip_back'),
              forward: false,
              onPressed: () => player.skip(const Duration(seconds: -15)),
            ),
            const SizedBox(width: 28),
            IconButton.filled(
              key: const Key('podcast-now-playing-toggle'),
              tooltip: context.strings.t(player.playing ? 'pause' : 'play'),
              onPressed: player.toggle,
              iconSize: 36,
              style: IconButton.styleFrom(minimumSize: const Size(64, 64)),
              icon: Icon(
                player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
            const SizedBox(width: 28),
            _SkipButton(
              tooltip: context.strings.t('podcast_skip_forward'),
              forward: true,
              onPressed: () => player.skip(const Duration(seconds: 15)),
            ),
          ],
        ),
        const SizedBox(height: 14),
        PodcastSpeedControl(rate: player.rate, onChanged: player.setRate),
      ],
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({
    required this.tooltip,
    required this.forward,
    required this.onPressed,
  });

  final String tooltip;
  final bool forward;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontSize: 9,
      fontWeight: FontWeight.w700,
      height: 1,
      letterSpacing: -0.3,
    );
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
      icon: SizedBox(
        width: 36,
        height: 36,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.flip(
              flipX: forward,
              child: const Icon(Icons.replay_rounded, size: 34),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('15', style: labelStyle),
            ),
          ],
        ),
      ),
    );
  }
}

class PodcastSpeedControl extends StatelessWidget {
  const PodcastSpeedControl({
    super.key,
    required this.rate,
    required this.onChanged,
  });

  final double rate;
  final ValueChanged<double> onChanged;

  static const _epsilon = 0.001;

  bool get _canSlowDown => rate > PodcastPlayer.rates.first + _epsilon;
  bool get _canSpeedUp => rate < PodcastPlayer.rates.last - _epsilon;
  bool get _atDefault => (rate - 1).abs() < _epsilon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final atDefault = _atDefault;
    return Material(
      color: atDefault
          ? colors.surfaceContainerHighest.withValues(alpha: 0.62)
          : colors.primaryContainer.withValues(alpha: 0.78),
      shape: StadiumBorder(
        side: BorderSide(
          color: atDefault
              ? colors.outlineVariant.withValues(alpha: 0.85)
              : colors.primary.withValues(alpha: 0.26),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 36,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SpeedStepButton(
              buttonKey: const Key('podcast-now-playing-slower'),
              tooltip: context.strings.t('podcast_slower'),
              icon: Icons.remove_rounded,
              onPressed: _canSlowDown ? () => onChanged(_nudged(-1)) : null,
            ),
            PopupMenuButton<double>(
              key: const Key('podcast-now-playing-speed'),
              tooltip: context.strings.t('podcast_playback_speed'),
              initialValue: rate,
              position: PopupMenuPosition.under,
              onSelected: onChanged,
              itemBuilder: (context) => [
                for (final value in PodcastPlayer.rates)
                  CheckedPopupMenuItem(
                    key: ValueKey('podcast-speed-${(value * 100).round()}'),
                    value: value,
                    checked: (value - rate).abs() < _epsilon,
                    child: Text(formatPodcastRate(value)),
                  ),
              ],
              child: SizedBox(
                width: 56,
                height: 36,
                child: Center(
                  child: Text(
                    formatPodcastRate(rate),
                    key: const Key('podcast-now-playing-speed-label'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.15,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: atDefault
                          ? colors.onSurface
                          : colors.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
            _SpeedStepButton(
              buttonKey: const Key('podcast-now-playing-faster'),
              tooltip: context.strings.t('podcast_faster'),
              icon: Icons.add_rounded,
              onPressed: _canSpeedUp ? () => onChanged(_nudged(1)) : null,
            ),
          ],
        ),
      ),
    );
  }

  double _nudged(int step) {
    if (step > 0) {
      return PodcastPlayer.rates.firstWhere(
        (value) => value > rate + _epsilon,
        orElse: () => PodcastPlayer.rates.last,
      );
    }
    return PodcastPlayer.rates.lastWhere(
      (value) => value < rate - _epsilon,
      orElse: () => PodcastPlayer.rates.first,
    );
  }
}

class _SpeedStepButton extends StatelessWidget {
  const _SpeedStepButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        key: buttonKey,
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          foregroundColor: colors.onSurfaceVariant,
          disabledForegroundColor: colors.outline.withValues(alpha: 0.38),
          minimumSize: const Size(36, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: Icon(icon, size: 18),
      ),
    );
  }
}
