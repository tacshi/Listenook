import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../data/transcript_exporter.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'workspace_page.dart';

class TranscriptReview extends StatefulWidget {
  const TranscriptReview({super.key, required this.jobId});
  final String jobId;

  @override
  State<TranscriptReview> createState() => _TranscriptReviewState();
}

class _TranscriptReviewState extends State<TranscriptReview> {
  late final Player _player;
  late final VideoController _video;
  final _search = TextEditingController();
  final Map<String, Timer> _editTimers = {};
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  String _openedPath = '';
  String _waveformSource = '';
  String? _waveformPath;
  bool _waveformLoading = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _video = VideoController(_player);
    _positionSubscription = _player.stream.position.listen((value) {
      if (mounted) setState(() => _position = value);
    });
    _durationSubscription = _player.stream.duration.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    _playingSubscription = _player.stream.playing.listen((value) {
      if (mounted) setState(() => _playing = value);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSource());
  }

  @override
  void didUpdateWidget(covariant TranscriptReview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jobId != widget.jobId) _openSource();
  }

  Future<void> _openSource() async {
    if (!mounted) return;
    final job = context
        .read<AppController>()
        .allJobs
        .where((item) => item.id == widget.jobId)
        .firstOrNull;
    if (job == null || job.sourcePath == _openedPath) return;
    _openedPath = job.sourcePath;
    if (await File(job.sourcePath).exists()) {
      if (!(job.metadata?.hasVideo ?? false)) {
        unawaited(_loadWaveform(job));
      }
      await _player.open(Media(job.sourcePath), play: false);
    }
  }

  Future<void> _loadWaveform(TranscriptionJob job) async {
    final source = job.sourcePath;
    if (_waveformSource == source &&
        (_waveformLoading || _waveformPath != null)) {
      return;
    }
    setState(() {
      _waveformSource = source;
      _waveformPath = null;
      _waveformLoading = true;
    });
    final path = await context.read<AppController>().loadWaveform(job.id);
    if (!mounted || _openedPath != source) return;
    setState(() {
      _waveformPath = path;
      _waveformLoading = false;
    });
  }

  @override
  void dispose() {
    for (final timer in _editTimers.values) {
      timer.cancel();
    }
    _search.dispose();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final job = controller.allJobs
        .where((item) => item.id == widget.jobId)
        .firstOrNull;
    final document = job?.document;
    if (job == null || document == null) return const SizedBox.shrink();
    final query = _search.text.trim().toLowerCase();
    final segments = query.isEmpty
        ? document.segments
        : document.segments
              .where(
                (segment) =>
                    segment.text.toLowerCase().contains(query) ||
                    context.strings
                        .speakerName(document.speakerName(segment.speaker))
                        .toLowerCase()
                        .contains(query),
              )
              .toList();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _ReviewToolbar(
            job: job,
            search: _search,
            onSearch: () => setState(() {}),
          ),
          const Divider(height: 1),
          if (!File(job.sourcePath).existsSync())
            MaterialBanner(
              content: Text(context.strings.t('source_missing')),
              leading: const Icon(Icons.link_off_rounded),
              actions: [
                TextButton(
                  onPressed: () async {
                    final file = await openFile();
                    if (file == null || !context.mounted) return;
                    await context.read<AppController>().relink(
                      job.id,
                      file.path,
                    );
                    _openedPath = '';
                    await _openSource();
                  },
                  child: Text(context.strings.t('relink')),
                ),
              ],
            )
          else
            _MediaPane(
              job: job,
              video: _video,
              playing: _playing,
              position: _position,
              duration: _duration,
              waveformPath: _waveformPath,
              waveformLoading: _waveformLoading,
              onPlayPause: _player.playOrPause,
              onSeek: _player.seek,
            ),
          const Divider(height: 1),
          if (document.speakers.isNotEmpty)
            SpeakerStrip(job: job, document: document),
          Expanded(
            child: SelectionArea(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                itemCount: segments.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final segment = segments[index];
                  return _SegmentEditor(
                    key: ValueKey(
                      '${segment.id}-${document.updatedAt.millisecondsSinceEpoch}',
                    ),
                    segment: segment,
                    query: query,
                    speakerName: context.strings.speakerName(
                      document.speakerName(segment.speaker),
                    ),
                    showSpeaker: controller.settings.showSpeakers,
                    showTimestamp: controller.settings.showTimestamps,
                    onSeek: () =>
                        _player.seek(Duration(milliseconds: segment.startMs)),
                    onChanged: (text) => _scheduleEdit(segment.id, text),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _scheduleEdit(String segmentId, String text) {
    _editTimers[segmentId]?.cancel();
    _editTimers[segmentId] = Timer(const Duration(milliseconds: 450), () {
      if (mounted) {
        context.read<AppController>().updateSegment(
          widget.jobId,
          segmentId,
          text,
        );
      }
    });
  }
}

class _ReviewToolbar extends StatelessWidget {
  const _ReviewToolbar({
    required this.job,
    required this.search,
    required this.onSearch,
  });

  final TranscriptionJob job;
  final TextEditingController search;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              job.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          SizedBox(
            width: 210,
            child: TextField(
              controller: search,
              onChanged: (_) => onSearch(),
              decoration: InputDecoration(
                isDense: true,
                hintText: context.strings.t('search_transcript'),
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: context.strings.t('copy'),
            onPressed: () async {
              final options = ExportOptions(
                showSpeakers: controller.settings.showSpeakers,
                showTimestamps: controller.settings.showTimestamps,
                localeCode: Localizations.localeOf(context).languageCode,
              );
              await Clipboard.setData(
                ClipboardData(text: controller.renderJob(job.id, options)),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.strings.t('copied'))),
                );
              }
            },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: context.strings.t('export'),
            onPressed: () => showExportDialog(context, jobId: job.id),
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
    );
  }
}

class _MediaPane extends StatelessWidget {
  const _MediaPane({
    required this.job,
    required this.video,
    required this.playing,
    required this.position,
    required this.duration,
    required this.waveformPath,
    required this.waveformLoading,
    required this.onPlayPause,
    required this.onSeek,
  });

  final TranscriptionJob job;
  final VideoController video;
  final bool playing;
  final Duration position;
  final Duration duration;
  final String? waveformPath;
  final bool waveformLoading;
  final Future<void> Function() onPlayPause;
  final Future<void> Function(Duration) onSeek;

  @override
  Widget build(BuildContext context) {
    final hasVideo = job.metadata?.hasVideo ?? false;
    final mediaDuration = duration.inMilliseconds > 0
        ? duration
        : Duration(milliseconds: job.metadata?.durationMs ?? 0);
    return Column(
      children: [
        if (hasVideo)
          Container(
            color: Colors.black,
            height: 210,
            width: double.infinity,
            child: Video(controller: video, controls: NoVideoControls),
          )
        else
          SizedBox(
            height: 94,
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 18),
              child: WaveformScrubber(
                path: waveformPath,
                loading: waveformLoading,
                position: position,
                duration: mediaDuration,
                onSeek: onSeek,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              IconButton.filledTonal(
                onPressed: onPlayPause,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Text(formatClock(position.inMilliseconds)),
              if (hasVideo)
                Expanded(
                  child: Slider(
                    value: position.inMilliseconds
                        .clamp(0, mediaDuration.inMilliseconds)
                        .toDouble(),
                    max: mediaDuration.inMilliseconds
                        .clamp(1, double.infinity)
                        .toDouble(),
                    onChanged: (value) =>
                        onSeek(Duration(milliseconds: value.round())),
                  ),
                )
              else
                const Spacer(),
              Text(formatClock(mediaDuration.inMilliseconds)),
            ],
          ),
        ),
      ],
    );
  }
}

class WaveformScrubber extends StatelessWidget {
  const WaveformScrubber({
    super.key,
    required this.path,
    required this.loading,
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final String? path;
  final bool loading;
  final Duration position;
  final Duration duration;
  final Future<void> Function(Duration) onSeek;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }
    final enabled = duration.inMilliseconds > 0;
    final progress = enabled
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void seek(double dx) {
          if (!enabled || width <= 0) return;
          final fraction = (dx / width).clamp(0.0, 1.0);
          unawaited(
            onSeek(
              Duration(
                milliseconds: (duration.inMilliseconds * fraction).round(),
              ),
            ),
          );
        }

        return Semantics(
          slider: true,
          value:
              '${formatClock(position.inMilliseconds)} / '
              '${formatClock(duration.inMilliseconds)}',
          increasedValue: enabled
              ? formatClock(
                  (duration.inMilliseconds * (progress + .05).clamp(0.0, 1.0))
                      .round(),
                )
              : null,
          decreasedValue: enabled
              ? formatClock(
                  (duration.inMilliseconds * (progress - .05).clamp(0.0, 1.0))
                      .round(),
                )
              : null,
          onIncrease: enabled
              ? () => seek(width * (progress + .05).clamp(0.0, 1.0))
              : null,
          onDecrease: enabled
              ? () => seek(width * (progress - .05).clamp(0.0, 1.0))
              : null,
          child: MouseRegion(
            cursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: GestureDetector(
              key: const Key('waveform-scrubber'),
              behavior: HitTestBehavior.opaque,
              onTapDown: enabled
                  ? (details) => seek(details.localPosition.dx)
                  : null,
              onHorizontalDragStart: enabled
                  ? (details) => seek(details.localPosition.dx)
                  : null,
              onHorizontalDragUpdate: enabled
                  ? (details) => seek(details.localPosition.dx)
                  : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _waveformLayer(context, colors.outlineVariant),
                  ClipRect(
                    clipper: _WaveformProgressClipper(progress),
                    child: _waveformLayer(context, colors.primary),
                  ),
                  if (enabled)
                    Positioned(
                      left: (width * progress - 1).clamp(0.0, width - 2),
                      top: 0,
                      bottom: 0,
                      child: Container(
                        key: const Key('waveform-playhead'),
                        width: 2,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _waveformLayer(BuildContext context, Color color) {
    if (path case final value?) {
      return Image.file(
        File(value),
        key: ValueKey('$value-${color.toARGB32()}'),
        fit: BoxFit.fill,
        color: color,
        colorBlendMode: BlendMode.srcIn,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _fallback(color),
      );
    }
    return _fallback(color);
  }

  Widget _fallback(Color color) => Center(
    child: Container(
      height: 2,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(99),
      ),
    ),
  );
}

class _WaveformProgressClipper extends CustomClipper<Rect> {
  const _WaveformProgressClipper(this.progress);

  final double progress;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * progress, size.height);

  @override
  bool shouldReclip(_WaveformProgressClipper oldClipper) =>
      oldClipper.progress != progress;
}

class SpeakerStrip extends StatelessWidget {
  const SpeakerStrip({super.key, required this.job, required this.document});
  final TranscriptionJob job;
  final TranscriptDocument document;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      scrollDirection: Axis.horizontal,
      itemCount: document.speakers.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final speaker = document.speakers[index];
        return ActionChip(
          avatarBoxConstraints: const BoxConstraints.tightFor(
            width: 18,
            height: 18,
          ),
          avatar: Container(
            key: ValueKey('speaker-avatar-${speaker.id}'),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.primary,
            ),
            child: Text(
              '${index + 1}',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
          label: Text(context.strings.speakerName(speaker.name)),
          onPressed: () => _rename(context, speaker),
        );
      },
    ),
  );

  Future<void> _rename(BuildContext context, SpeakerProfile speaker) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => _RenameSpeakerDialog(
        initialValue: context.strings.speakerName(speaker.name),
      ),
    );
    if (value != null && value.trim().isNotEmpty && context.mounted) {
      await context.read<AppController>().renameSpeaker(
        job.id,
        speaker.id,
        value,
      );
    }
  }
}

class _RenameSpeakerDialog extends StatefulWidget {
  const _RenameSpeakerDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_RenameSpeakerDialog> createState() => _RenameSpeakerDialogState();
}

class _RenameSpeakerDialogState extends State<_RenameSpeakerDialog> {
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_field.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.t('rename_speaker')),
    content: TextField(
      key: const Key('speaker-name-field'),
      controller: _field,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.strings.t('cancel')),
      ),
      FilledButton(
        key: const Key('save-speaker-name'),
        onPressed: _submit,
        child: Text(context.strings.t('save')),
      ),
    ],
  );
}

class _SegmentEditor extends StatelessWidget {
  const _SegmentEditor({
    super.key,
    required this.segment,
    required this.query,
    required this.speakerName,
    required this.showSpeaker,
    required this.showTimestamp,
    required this.onSeek,
    required this.onChanged,
  });

  final TranscriptSegment segment;
  final String query;
  final String speakerName;
  final bool showSpeaker;
  final bool showTimestamp;
  final VoidCallback onSeek;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTimestamp)
            TextButton(
              onPressed: onSeek,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 7),
              ),
              child: Text(formatClock(segment.startMs)),
            )
          else
            IconButton(
              tooltip: formatClock(segment.startMs),
              onPressed: onSeek,
              icon: const Icon(Icons.play_circle_outline_rounded, size: 20),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showSpeaker && speakerName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: SearchHighlightedText(
                      text: speakerName,
                      query: query,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (query.isEmpty)
                  TextFormField(
                    initialValue: segment.text,
                    minLines: 1,
                    maxLines: null,
                    onChanged: onChanged,
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: false,
                      contentPadding: EdgeInsets.all(4),
                      border: InputBorder.none,
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: SearchHighlightedText(
                      text: segment.text,
                      query: query,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class SearchHighlightedText extends StatelessWidget {
  const SearchHighlightedText({
    super.key,
    required this.text,
    required this.query,
    this.style,
  });

  final String text;
  final String query;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Text(text, style: style);
    final normalizedText = text.toLowerCase();
    final normalizedQuery = trimmed.toLowerCase();
    final highlight = TextStyle(
      color: Theme.of(context).colorScheme.onPrimaryContainer,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      fontWeight: FontWeight.w700,
    );
    final spans = <InlineSpan>[];
    var cursor = 0;
    while (cursor < text.length) {
      final match = normalizedText.indexOf(normalizedQuery, cursor);
      if (match < 0) {
        spans.add(TextSpan(text: text.substring(cursor)));
        break;
      }
      if (match > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match)));
      }
      final end = match + trimmed.length;
      spans.add(TextSpan(text: text.substring(match, end), style: highlight));
      cursor = end;
    }
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
