import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

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
  Player? _player;
  VideoController? _video;
  final _search = TextEditingController();
  final _transcriptScroll = AutoScrollController(
    axis: Axis.vertical,
    suggestedRowHeight: 84,
  );
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _followPlayback = true;
  TranslationViewMode _viewMode = TranslationViewMode.original;
  int _programmaticScrolls = 0;
  String? _lastScrolledSegmentId;
  String? _editingSegmentId;
  String? _editingTranslationSegmentId;
  TranscriptDocument? _mappedDocument;
  Map<String, List<TranscriptToken>> _tokensBySegment = const {};
  String _openedPath = '';
  String _waveformSource = '';
  String? _waveformPath;
  bool _waveformLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSource());
  }

  void _ensurePlayer() {
    if (_player != null) return;
    final player = Player();
    _player = player;
    _video = VideoController(player);
    _positionSubscription = player.stream.position.listen(_handlePosition);
    _durationSubscription = player.stream.duration.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    _playingSubscription = player.stream.playing.listen(_handlePlaying);
  }

  @override
  void didUpdateWidget(covariant TranscriptReview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jobId != widget.jobId) {
      _search.clear();
      _position = Duration.zero;
      _duration = Duration.zero;
      _playing = false;
      _followPlayback = true;
      _editingSegmentId = null;
      _editingTranslationSegmentId = null;
      _viewMode = TranslationViewMode.original;
      _lastScrolledSegmentId = null;
      _mappedDocument = null;
      _tokensBySegment = const {};
      _openedPath = '';
      _waveformSource = '';
      _waveformPath = null;
      _waveformLoading = false;
      _openSource();
    }
  }

  void _handlePosition(Duration value) {
    if (!mounted) return;
    final document = _document;
    final previousIndex = document == null
        ? null
        : currentTranscriptSegmentIndex(
            document.segments,
            _position.inMilliseconds,
          );
    final nextIndex = document == null
        ? null
        : currentTranscriptSegmentIndex(
            document.segments,
            value.inMilliseconds,
          );
    setState(() => _position = value);
    if (_playing && previousIndex != nextIndex) _queueFocusCurrent();
  }

  void _handlePlaying(bool value) {
    if (!mounted || value == _playing) return;
    final resumed = value && !_playing;
    setState(() {
      _playing = value;
      if (resumed) _followPlayback = true;
    });
    if (resumed) _queueFocusCurrent(force: true);
  }

  TranscriptDocument? get _document => context
      .read<AppController>()
      .allJobs
      .where((item) => item.id == widget.jobId)
      .firstOrNull
      ?.document;

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
      _ensurePlayer();
      if (!(job.metadata?.hasVideo ?? false)) {
        unawaited(_loadWaveform(job));
      }
      await _player!.open(Media(job.sourcePath), play: false);
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
    _search.dispose();
    _transcriptScroll.dispose();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _player?.dispose();
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
    _ensureTokenMap(document);
    final query = _search.text.trim().toLowerCase();
    final segments = query.isEmpty
        ? document.segments
        : document.segments
              .where(
                (segment) =>
                    segment.text.toLowerCase().contains(query) ||
                    (segment.translatedText?.toLowerCase().contains(query) ??
                        false) ||
                    context.strings
                        .speakerName(document.speakerName(segment.speaker))
                        .toLowerCase()
                        .contains(query),
              )
              .toList();
    final currentIndex = query.isEmpty
        ? currentTranscriptSegmentIndex(
            document.segments,
            _position.inMilliseconds,
          )
        : null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _ReviewToolbar(
            job: job,
            search: _search,
            viewMode: _viewMode,
            onViewModeChanged: (value) => setState(() => _viewMode = value),
            onSearch: () {
              setState(() {});
              if (_search.text.trim().isEmpty) {
                _queueFocusCurrent(force: true);
              }
            },
            onFocusCurrentSentence: document.segments.isEmpty
                ? null
                : _focusCurrentSentence,
          ),
          const Divider(height: 1),
          if (!File(job.sourcePath).existsSync())
            MaterialBanner(
              content: Text(context.strings.t('source_missing')),
              leading: const Icon(Icons.link_off_rounded),
              actions: [
                TextButton(
                  onPressed: () async {
                    final linked = await chooseAndRelink(context, job.id);
                    if (!linked || !context.mounted) return;
                    _openedPath = '';
                    await _openSource();
                  },
                  child: Text(context.strings.t('relink')),
                ),
              ],
            )
          else if (_player == null || _video == null)
            const SizedBox(
              height: 64,
              child: Center(
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            _MediaPane(
              job: job,
              video: _video!,
              playing: _playing,
              position: _position,
              duration: _duration,
              waveformPath: _waveformPath,
              waveformLoading: _waveformLoading,
              onPlayPause: _player!.playOrPause,
              onSeek: _seek,
            ),
          const Divider(height: 1),
          if (document.speakers.isNotEmpty)
            SpeakerStrip(job: job, document: document),
          Expanded(
            child: Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) _suspendFollow();
              },
              child: NotificationListener<UserScrollNotification>(
                onNotification: (notification) {
                  if (_programmaticScrolls == 0 &&
                      notification.direction != ScrollDirection.idle) {
                    _suspendFollow();
                  }
                  return false;
                },
                child: Scrollbar(
                  controller: _transcriptScroll,
                  child: SelectionArea(
                    child: ListView.separated(
                      key: const Key('transcript-scroll'),
                      controller: _transcriptScroll,
                      primary: false,
                      scrollDirection: Axis.vertical,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                      itemCount: segments.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final segment = segments[index];
                        return AutoScrollTag(
                          key: ValueKey('segment-tag-${segment.id}'),
                          controller: _transcriptScroll,
                          index: index,
                          child: Column(
                            children: [
                              if (_viewMode != TranslationViewMode.translated)
                                TranscriptSegmentEditor(
                                  key: ValueKey(segment.id),
                                  segment: segment,
                                  tokens:
                                      _tokensBySegment[segment.id] ?? const [],
                                  positionMs: _position.inMilliseconds,
                                  isCurrent:
                                      query.isEmpty && index == currentIndex,
                                  query: query,
                                  speakerName: context.strings.speakerName(
                                    document.speakerName(segment.speaker),
                                  ),
                                  showSpeaker: controller.settings.showSpeakers,
                                  showTimestamp:
                                      controller.settings.showTimestamps,
                                  isEditing: _editingSegmentId == segment.id,
                                  onSeek: () => unawaited(
                                    _seek(
                                      Duration(milliseconds: segment.startMs),
                                    ),
                                  ),
                                  onEdit: () => _startEditing(segment.id),
                                  onCancel: () => _cancelEditing(segment.id),
                                  onSave: (text) =>
                                      _saveSegment(segment.id, text),
                                ),
                              if (_viewMode != TranslationViewMode.original)
                                _TranslatedSegmentEditor(
                                  key: ValueKey('translated-${segment.id}'),
                                  segment: segment,
                                  isCurrent:
                                      query.isEmpty && index == currentIndex,
                                  query: query,
                                  showTimestamp:
                                      controller.settings.showTimestamps,
                                  isEditing:
                                      _editingTranslationSegmentId ==
                                      segment.id,
                                  onSeek: () => unawaited(
                                    _seek(
                                      Duration(milliseconds: segment.startMs),
                                    ),
                                  ),
                                  onEdit: () =>
                                      _startTranslationEditing(segment.id),
                                  onCancel: () =>
                                      _cancelTranslationEditing(segment.id),
                                  onSave: (text) =>
                                      _saveTranslation(segment.id, text),
                                  onRetranslate:
                                      job.translationState.status.isActive ||
                                          !controller.translationConfigured
                                      ? null
                                      : () => context
                                            .read<AppController>()
                                            .retranslateSegment(
                                              widget.jobId,
                                              segment.id,
                                            ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _seek(Duration position) async {
    final player = _player;
    if (player == null) return;
    setState(() {
      _position = position;
      _followPlayback = true;
    });
    _queueFocusCurrent(force: true);
    await player.seek(position);
  }

  void _focusCurrentSentence() {
    _search.clear();
    setState(() => _followPlayback = true);
    _queueFocusCurrent(force: true);
  }

  void _suspendFollow() {
    if (!mounted || !_followPlayback) return;
    setState(() => _followPlayback = false);
  }

  void _queueFocusCurrent({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_scrollToCurrent(force: force));
    });
  }

  Future<void> _scrollToCurrent({bool force = false}) async {
    if (!_followPlayback ||
        _search.text.trim().isNotEmpty ||
        !_transcriptScroll.hasClients) {
      return;
    }
    final document = _document;
    if (document == null || document.segments.isEmpty) return;
    final index =
        currentTranscriptSegmentIndex(
          document.segments,
          _position.inMilliseconds,
        ) ??
        0;
    final segmentId = document.segments[index].id;
    if (!force && segmentId == _lastScrolledSegmentId) return;
    _lastScrolledSegmentId = segmentId;
    _programmaticScrolls++;
    try {
      await _transcriptScroll.scrollToIndex(
        index,
        preferPosition: AutoScrollPosition.middle,
        duration: const Duration(milliseconds: 260),
      );
    } finally {
      _programmaticScrolls--;
    }
  }

  void _startEditing(String segmentId) {
    setState(() {
      _editingSegmentId = segmentId;
      _editingTranslationSegmentId = null;
      _followPlayback = false;
    });
  }

  void _cancelEditing(String segmentId) {
    if (_editingSegmentId == segmentId) {
      setState(() => _editingSegmentId = null);
    }
  }

  Future<void> _saveSegment(String segmentId, String text) async {
    try {
      await context.read<AppController>().updateSegment(
        widget.jobId,
        segmentId,
        text,
      );
      if (mounted && _editingSegmentId == segmentId) {
        setState(() => _editingSegmentId = null);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.strings.t('error_unexpected'))),
      );
    }
  }

  void _startTranslationEditing(String segmentId) {
    setState(() {
      _editingSegmentId = null;
      _editingTranslationSegmentId = segmentId;
      _followPlayback = false;
    });
  }

  void _cancelTranslationEditing(String segmentId) {
    if (_editingTranslationSegmentId == segmentId) {
      setState(() => _editingTranslationSegmentId = null);
    }
  }

  Future<void> _saveTranslation(String segmentId, String text) async {
    try {
      await context.read<AppController>().updateTranslatedSegment(
        widget.jobId,
        segmentId,
        text,
      );
      if (mounted && _editingTranslationSegmentId == segmentId) {
        setState(() => _editingTranslationSegmentId = null);
      }
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.strings.t('error_unexpected'))),
      );
    }
  }

  void _ensureTokenMap(TranscriptDocument document) {
    if (identical(_mappedDocument, document)) return;
    _mappedDocument = document;
    final result = <String, List<TranscriptToken>>{
      for (final segment in document.segments) segment.id: [],
    };
    var segmentIndex = 0;
    for (final token in document.tokens) {
      if (token.startMs == 0 && token.endMs == 0) continue;
      while (segmentIndex + 1 < document.segments.length &&
          token.startMs >= document.segments[segmentIndex + 1].startMs) {
        segmentIndex++;
      }
      if (document.segments.isEmpty) break;
      final segment = document.segments[segmentIndex];
      if (token.startMs >= segment.startMs && token.startMs <= segment.endMs) {
        result[segment.id]!.add(token);
      }
    }
    _tokensBySegment = {
      for (final entry in result.entries)
        entry.key: List.unmodifiable(entry.value),
    };
  }
}

class _ReviewToolbar extends StatelessWidget {
  const _ReviewToolbar({
    required this.job,
    required this.search,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.onSearch,
    required this.onFocusCurrentSentence,
  });

  final TranscriptionJob job;
  final TextEditingController search;
  final TranslationViewMode viewMode;
  final ValueChanged<TranslationViewMode> onViewModeChanged;
  final VoidCallback onSearch;
  final VoidCallback? onFocusCurrentSentence;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final translationStarted =
        job.translationState.status != TranslationStatus.idle ||
        (job.document?.segments.any((segment) => segment.hasTranslation) ??
            false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  job.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(
                width: 180,
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
                key: const Key('focus-current-sentence'),
                tooltip: context.strings.t('focus_current_sentence'),
                onPressed: onFocusCurrentSentence,
                icon: const Icon(Icons.center_focus_strong_rounded),
              ),
              IconButton(
                key: const Key('translate-transcript'),
                tooltip: controller.translationConfigured
                    ? context.strings.t('translate')
                    : context.strings.t('auto_translate_requires_config'),
                onPressed:
                    controller.translationConfigured &&
                        !job.translationState.status.isActive
                    ? () => _showTranslationDialog(context, job)
                    : null,
                icon: const Icon(Icons.translate_rounded),
              ),
              IconButton(
                tooltip: context.strings.t('copy'),
                onPressed: () async {
                  final options = ExportOptions(
                    showSpeakers: controller.settings.showSpeakers,
                    showTimestamps: controller.settings.showTimestamps,
                    localeCode: Localizations.localeOf(context).languageCode,
                    contentMode: switch (viewMode) {
                      TranslationViewMode.original =>
                        ExportContentMode.original,
                      TranslationViewMode.translated =>
                        ExportContentMode.translated,
                      TranslationViewMode.bilingual =>
                        ExportContentMode.bilingual,
                    },
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
          if (translationStarted) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<TranslationViewMode>(
                  segments: [
                    ButtonSegment(
                      value: TranslationViewMode.original,
                      label: Text(context.strings.t('original')),
                    ),
                    ButtonSegment(
                      value: TranslationViewMode.translated,
                      label: Text(context.strings.t('translated')),
                    ),
                    ButtonSegment(
                      value: TranslationViewMode.bilingual,
                      label: Text(context.strings.t('bilingual')),
                    ),
                  ],
                  selected: {viewMode},
                  onSelectionChanged: (value) => onViewModeChanged(value.first),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: _TranslationStatusLabel(job: job),
                ),
                if (job.translationState.status.isActive)
                  TextButton.icon(
                    onPressed: () => controller.cancelTranslation(job.id),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(context.strings.t('cancel')),
                  )
                else if (job.translationState.status.canRetry)
                  TextButton.icon(
                    onPressed: controller.translationConfigured
                        ? () => controller.retryTranslation(job.id)
                        : null,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(context.strings.t('retry_missing')),
                  ),
                if (!job.translationState.status.isActive)
                  TextButton(
                    onPressed: controller.translationConfigured
                        ? () => _confirmRetranslateAll(context, job)
                        : null,
                    child: Text(context.strings.t('retranslate_all')),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TranslationStatusLabel extends StatelessWidget {
  const _TranslationStatusLabel({required this.job});

  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) {
    final state = job.translationState;
    final text = switch (state.status) {
      TranslationStatus.translating =>
        context.strings
            .t('translation_progress')
            .replaceFirst('{done}', '${state.completedSegments}')
            .replaceFirst('{total}', '${state.totalSegments}'),
      TranslationStatus.completed => context.strings.t('completed'),
      TranslationStatus.partial ||
      TranslationStatus.interrupted => context.strings.t('translation_partial'),
      TranslationStatus.cancelled => context.strings.t('translation_cancelled'),
      TranslationStatus.failed => context.strings.error(
        state.errorCode,
        englishFallback: state.errorMessage,
      ),
      TranslationStatus.idle => '',
    };
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

Future<void> _showTranslationDialog(
  BuildContext context,
  TranscriptionJob job,
) async {
  final controller = context.read<AppController>();
  var target = job.translationState.targetLanguage.isNotEmpty
      ? job.translationState.targetLanguage
      : controller.settings.translationSettings.targetLanguage;
  if (!supportedTranslationLanguageCodes.contains(target)) target = 'en';
  final selected = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(context.strings.t('translation_dialog_title')),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: const Key('manual-translation-target'),
                initialValue: target,
                decoration: InputDecoration(
                  labelText: context.strings.t('target_language'),
                ),
                items: [
                  for (final code in supportedTranslationLanguageCodes)
                    DropdownMenuItem(
                      value: code,
                      child: Text(
                        context.strings.translationLanguageName(code),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => target = value);
                },
              ),
              const SizedBox(height: 12),
              Text(
                context.strings
                    .t('translation_model_label')
                    .replaceFirst(
                      '{model}',
                      controller.settings.translationSettings.model,
                    ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, target),
            child: Text(context.strings.t('translate')),
          ),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  final hasExisting =
      job.document?.segments.any((segment) => segment.hasTranslation) ?? false;
  final targetChanged =
      hasExisting &&
      job.translationState.targetLanguage.isNotEmpty &&
      job.translationState.targetLanguage != selected;
  var replace = false;
  if (targetChanged) {
    replace = await _confirmTranslationReplacement(context) ?? false;
    if (!replace || !context.mounted) return;
  }
  await controller.translateJob(
    job.id,
    targetLanguage: selected,
    replaceExisting: replace,
  );
}

Future<void> _confirmRetranslateAll(
  BuildContext context,
  TranscriptionJob job,
) async {
  if (await _confirmTranslationReplacement(context) != true ||
      !context.mounted) {
    return;
  }
  final controller = context.read<AppController>();
  final target = job.translationState.targetLanguage.isNotEmpty
      ? job.translationState.targetLanguage
      : controller.settings.translationSettings.targetLanguage;
  await controller.translateJob(
    job.id,
    targetLanguage: target,
    replaceExisting: true,
  );
}

Future<bool?> _confirmTranslationReplacement(BuildContext context) =>
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.t('translation_replace_title')),
        content: Text(context.strings.t('translation_replace_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.t('continue')),
          ),
        ],
      ),
    );

class _TranslatedSegmentEditor extends StatefulWidget {
  const _TranslatedSegmentEditor({
    super.key,
    required this.segment,
    required this.isCurrent,
    required this.query,
    required this.showTimestamp,
    required this.isEditing,
    required this.onSeek,
    required this.onEdit,
    required this.onCancel,
    required this.onSave,
    required this.onRetranslate,
  });

  final TranscriptSegment segment;
  final bool isCurrent;
  final String query;
  final bool showTimestamp;
  final bool isEditing;
  final VoidCallback onSeek;
  final VoidCallback onEdit;
  final VoidCallback onCancel;
  final Future<void> Function(String) onSave;
  final Future<void> Function()? onRetranslate;

  @override
  State<_TranslatedSegmentEditor> createState() =>
      _TranslatedSegmentEditorState();
}

class _TranslatedSegmentEditorState extends State<_TranslatedSegmentEditor> {
  late final TextEditingController _draft;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _draft = TextEditingController(text: widget.segment.translatedText ?? '');
  }

  @override
  void didUpdateWidget(covariant _TranslatedSegmentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isEditing && widget.segment.translatedText != _draft.text) {
      _draft.text = widget.segment.translatedText ?? '';
    }
    if (widget.isEditing && !oldWidget.isEditing) {
      _draft.text = widget.segment.translatedText ?? '';
      _draft.selection = TextSelection.collapsed(offset: _draft.text.length);
    }
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final translated = widget.segment.translatedText?.trim();
    final fallback = translated == null || translated.isEmpty;
    return Card(
      key: ValueKey('translated-segment-${widget.segment.id}'),
      margin: const EdgeInsets.only(top: 4),
      color: widget.isCurrent
          ? colors.primaryContainer.withValues(alpha: .35)
          : colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.showTimestamp)
              TextButton(
                onPressed: widget.onSeek,
                child: Text(formatClock(widget.segment.startMs)),
              ),
            Expanded(
              child: widget.isEditing
                  ? TextField(
                      key: ValueKey('translated-field-${widget.segment.id}'),
                      controller: _draft,
                      autofocus: true,
                      minLines: 1,
                      maxLines: null,
                    )
                  : InkWell(
                      onTap: widget.onSeek,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 8,
                        ),
                        child: SearchHighlightedText(
                          text: fallback ? widget.segment.text : translated,
                          query: widget.query,
                          style: TextStyle(
                            fontStyle: fallback ? FontStyle.italic : null,
                            color: fallback ? colors.onSurfaceVariant : null,
                          ),
                        ),
                      ),
                    ),
            ),
            if (widget.isEditing) ...[
              IconButton(
                tooltip: context.strings.t('cancel'),
                onPressed: _saving ? null : widget.onCancel,
                icon: const Icon(Icons.close_rounded),
              ),
              IconButton(
                tooltip: context.strings.t('save'),
                onPressed: _saving
                    ? null
                    : () async {
                        setState(() => _saving = true);
                        await widget.onSave(_draft.text);
                        if (mounted) setState(() => _saving = false);
                      },
                icon: const Icon(Icons.check_rounded),
              ),
            ] else
              PopupMenuButton<String>(
                tooltip: context.strings.t('more_actions'),
                onSelected: (value) {
                  if (value == 'edit') widget.onEdit();
                  if (value == 'retranslate') widget.onRetranslate?.call();
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(context.strings.t('edit_translation')),
                  ),
                  if (widget.onRetranslate != null)
                    PopupMenuItem(
                      value: 'retranslate',
                      child: Text(context.strings.t('retranslate_segment')),
                    ),
                ],
              ),
          ],
        ),
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
    if (!hasVideo) {
      return AudioTransport(
        playing: playing,
        position: position,
        duration: mediaDuration,
        waveformPath: waveformPath,
        waveformLoading: waveformLoading,
        onPlayPause: onPlayPause,
        onSeek: onSeek,
      );
    }
    return Column(
      children: [
        Container(
          color: Colors.black,
          height: 160,
          width: double.infinity,
          child: Video(controller: video, controls: NoVideoControls),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
              ),
              Text(formatClock(mediaDuration.inMilliseconds)),
            ],
          ),
        ),
      ],
    );
  }
}

class AudioTransport extends StatelessWidget {
  const AudioTransport({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.waveformPath,
    required this.waveformLoading,
    required this.onPlayPause,
    required this.onSeek,
  });

  final bool playing;
  final Duration position;
  final Duration duration;
  final String? waveformPath;
  final bool waveformLoading;
  final Future<void> Function() onPlayPause;
  final Future<void> Function(Duration) onSeek;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 64,
    width: double.infinity,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          IconButton.filledTonal(
            key: const Key('audio-play-pause'),
            onPressed: onPlayPause,
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatClock(position.inMilliseconds),
            key: const Key('audio-current-time'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 36,
              child: WaveformScrubber(
                path: waveformPath,
                loading: waveformLoading,
                position: position,
                duration: duration,
                onSeek: onSeek,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            formatClock(duration.inMilliseconds),
            key: const Key('audio-duration'),
          ),
        ],
      ),
    ),
  );
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

class SpeakerStrip extends StatefulWidget {
  const SpeakerStrip({super.key, required this.job, required this.document});
  final TranscriptionJob job;
  final TranscriptDocument document;

  @override
  State<SpeakerStrip> createState() => _SpeakerStripState();
}

class _SpeakerStripState extends State<SpeakerStrip> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent ||
          event.scrollDelta.dx != 0 ||
          !_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      _scroll.jumpTo(
        (position.pixels + event.scrollDelta.dy).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    },
    child: SizedBox(
      height: 56,
      child: Scrollbar(
        controller: _scroll,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        interactive: true,
        child: ListView.separated(
          key: const Key('speaker-strip-scroll'),
          controller: _scroll,
          primary: false,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          scrollDirection: Axis.horizontal,
          itemCount: widget.document.speakers.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final speaker = widget.document.speakers[index];
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
      ),
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
        widget.job.id,
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

class TranscriptSegmentEditor extends StatefulWidget {
  const TranscriptSegmentEditor({
    super.key,
    required this.segment,
    required this.tokens,
    required this.positionMs,
    required this.isCurrent,
    required this.query,
    required this.speakerName,
    required this.showSpeaker,
    required this.showTimestamp,
    required this.isEditing,
    required this.onSeek,
    required this.onEdit,
    required this.onCancel,
    required this.onSave,
  });

  final TranscriptSegment segment;
  final List<TranscriptToken> tokens;
  final int positionMs;
  final bool isCurrent;
  final String query;
  final String speakerName;
  final bool showSpeaker;
  final bool showTimestamp;
  final bool isEditing;
  final VoidCallback onSeek;
  final VoidCallback onEdit;
  final VoidCallback onCancel;
  final Future<void> Function(String text) onSave;

  @override
  State<TranscriptSegmentEditor> createState() =>
      _TranscriptSegmentEditorState();
}

class _TranscriptSegmentEditorState extends State<TranscriptSegmentEditor> {
  late final TextEditingController _draft;
  late final FocusNode _fieldFocus;
  bool _hovered = false;
  bool _actionFocused = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _draft = TextEditingController(text: widget.segment.text);
    _fieldFocus = FocusNode();
    if (widget.isEditing) _focusEditor();
  }

  @override
  void didUpdateWidget(covariant TranscriptSegmentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isEditing && widget.segment.text != _draft.text) {
      _draft.text = widget.segment.text;
    }
    if (widget.isEditing && !oldWidget.isEditing) {
      _draft.text = widget.segment.text;
      _draft.selection = TextSelection.collapsed(offset: _draft.text.length);
      _focusEditor();
    }
    if (!widget.isEditing && oldWidget.isEditing) {
      _draft.text = widget.segment.text;
    }
  }

  void _focusEditor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isEditing) _fieldFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _draft.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.onSave(_draft.text);
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: DecoratedBox(
        key: ValueKey('segment-card-${widget.segment.id}'),
        decoration: BoxDecoration(
          color: widget.isEditing ? colors.surfaceContainerLow : null,
          borderRadius: BorderRadius.circular(12),
          border: widget.isEditing
              ? Border.all(color: colors.outlineVariant)
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.showTimestamp)
                Padding(
                  padding: EdgeInsets.only(
                    top: widget.showSpeaker && widget.speakerName.isNotEmpty
                        ? 0
                        : 4,
                  ),
                  child: TextButton(
                    key: ValueKey('segment-timestamp-${widget.segment.id}'),
                    onPressed: widget.onSeek,
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      alignment: Alignment.topCenter,
                    ),
                    child: Text(formatClock(widget.segment.startMs)),
                  ),
                )
              else
                IconButton(
                  tooltip: formatClock(widget.segment.startMs),
                  onPressed: widget.onSeek,
                  icon: const Icon(Icons.play_circle_outline_rounded, size: 20),
                ),
              Expanded(child: _buildContent(context)),
              const SizedBox(width: 4),
              _buildActions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.showSpeaker && widget.speakerName.isNotEmpty)
        Padding(
          key: ValueKey('segment-speaker-${widget.segment.id}'),
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: SearchHighlightedText(
            text: widget.speakerName,
            query: widget.query,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      if (widget.isEditing)
        SelectionContainer.disabled(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _save,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _save,
              const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
            },
            child: TextField(
              key: ValueKey('segment-editor-${widget.segment.id}'),
              controller: _draft,
              focusNode: _fieldFocus,
              minLines: 1,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                isDense: true,
                filled: false,
                contentPadding: EdgeInsets.all(4),
                border: InputBorder.none,
              ),
            ),
          ),
        )
      else
        Padding(
          key: ValueKey('segment-text-${widget.segment.id}'),
          padding: const EdgeInsets.all(4),
          child: widget.query.isEmpty
              ? PlaybackHighlightedText(
                  text: widget.segment.text,
                  tokens: widget.tokens,
                  positionMs: widget.positionMs,
                  segmentStartMs: widget.segment.startMs,
                  segmentEndMs: widget.segment.endMs,
                  enabled: widget.isCurrent,
                  style: Theme.of(context).textTheme.bodyLarge,
                )
              : SearchHighlightedText(
                  text: widget.segment.text,
                  query: widget.query,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
        ),
    ],
  );

  Widget _buildActions(BuildContext context) {
    if (widget.isEditing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('segment-cancel-${widget.segment.id}'),
            tooltip: context.strings.t('cancel'),
            onPressed: _saving ? null : widget.onCancel,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
          IconButton(
            key: ValueKey('segment-save-${widget.segment.id}'),
            tooltip: context.strings.t('save'),
            onPressed: _saving ? null : _save,
            visualDensity: VisualDensity.compact,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded, size: 18),
          ),
        ],
      );
    }
    final visible = _hovered || _actionFocused;
    return Focus(
      onFocusChange: (value) => setState(() => _actionFocused = value),
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: IconButton(
          key: ValueKey('segment-edit-${widget.segment.id}'),
          tooltip: context.strings.t('edit'),
          onPressed: widget.onEdit,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.edit_outlined, size: 18),
        ),
      ),
    );
  }
}

class PlaybackHighlightedText extends StatelessWidget {
  const PlaybackHighlightedText({
    super.key,
    required this.text,
    required this.tokens,
    required this.positionMs,
    required this.segmentStartMs,
    required this.segmentEndMs,
    this.enabled = true,
    this.style,
  });

  final String text;
  final List<TranscriptToken> tokens;
  final int positionMs;
  final int segmentStartMs;
  final int segmentEndMs;
  final bool enabled;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final ranges = enabled
        ? _playedTextRanges(
            text: text,
            tokens: tokens,
            positionMs: positionMs,
            segmentStartMs: segmentStartMs,
            segmentEndMs: segmentEndMs,
          )
        : const <TextRange>[];
    final selectionColor =
        DefaultSelectionStyle.of(context).selectionColor ??
        Theme.of(context).colorScheme.primaryContainer;
    final highlight = TextStyle(backgroundColor: selectionColor);
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final range in ranges) {
      if (range.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, range.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(range.start, range.end),
          style: highlight,
        ),
      );
      cursor = range.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

List<TextRange> _playedTextRanges({
  required String text,
  required List<TranscriptToken> tokens,
  required int positionMs,
  required int segmentStartMs,
  required int segmentEndMs,
}) {
  if (text.isEmpty || positionMs < segmentStartMs) return const [];
  if (segmentEndMs > segmentStartMs && positionMs >= segmentEndMs) {
    return [TextRange(start: 0, end: text.length)];
  }
  final timedTokens = tokens
      .where((token) => token.startMs != 0 || token.endMs != 0)
      .toList(growable: false);
  final timedRanges = _alignTokenRanges(text, timedTokens);
  final played = <TextRange>[];
  for (
    var index = 0;
    index < timedTokens.length && index < timedRanges.length;
    index++
  ) {
    final range = timedRanges[index];
    if (range != null && timedTokens[index].startMs <= positionMs) {
      played.add(range);
    }
  }
  return _mergeTextRanges(played);
}

List<TextRange?> _alignTokenRanges(String text, List<TranscriptToken> tokens) {
  if (tokens.isEmpty) return const [];
  final raw = StringBuffer();
  final rawRanges = <TextRange>[];
  for (final token in tokens) {
    final start = raw.length;
    raw.write(token.text);
    rawRanges.add(TextRange(start: start, end: raw.length));
  }
  final joined = raw.toString();
  final leading = joined.length - joined.trimLeft().length;
  final trailing = joined.trimRight().length;
  final normalized = joined.substring(leading, trailing);
  if (normalized == text) {
    return [
      for (final range in rawRanges)
        TextRange(
          start: (range.start - leading).clamp(0, text.length),
          end: (range.end - leading).clamp(0, text.length),
        ),
    ];
  }

  final normalizedText = text.toLowerCase();
  final result = <TextRange?>[];
  var cursor = 0;
  for (final token in tokens) {
    final part = token.text.trim();
    if (part.isEmpty) {
      result.add(null);
      continue;
    }
    final match = normalizedText.indexOf(part.toLowerCase(), cursor);
    if (match < 0) {
      result.add(null);
      continue;
    }
    final end = match + part.length;
    result.add(TextRange(start: match, end: end));
    cursor = end;
  }
  return result;
}

List<TextRange> _mergeTextRanges(List<TextRange> ranges) {
  if (ranges.isEmpty) return const [];
  final merged = <TextRange>[ranges.first];
  for (final range in ranges.skip(1)) {
    final previous = merged.last;
    if (range.start <= previous.end) {
      merged[merged.length - 1] = TextRange(
        start: previous.start,
        end: range.end > previous.end ? range.end : previous.end,
      );
    } else {
      merged.add(range);
    }
  }
  return merged;
}

int? currentTranscriptSegmentIndex(
  List<TranscriptSegment> segments,
  int positionMs,
) {
  if (segments.isEmpty || positionMs < segments.first.startMs) return null;
  var low = 0;
  var high = segments.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (segments[middle].startMs <= positionMs) {
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return high;
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
