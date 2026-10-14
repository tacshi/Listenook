import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/transcript_structure_editor.dart';
import '../../data/transcript_exporter.dart';
import '../../l10n/strings.dart';
import '../transcript_review.dart';
import 'media_pane.dart';
import 'review_toolbar.dart';
import 'speaker_strip.dart';
import 'transcript_review_state.dart';

class TranscriptSegmentGroup extends StatefulWidget {
  const TranscriptSegmentGroup({
    super.key,
    this.blindListening = false,
    this.blurred = false,
    required this.segment,
    required this.tokens,
    required this.positionMs,
    required this.isCurrent,
    required this.viewMode,
    required this.query,
    required this.speakerName,
    required this.speakers,
    required this.showSpeaker,
    required this.showTimestamp,
    required this.highlightTranslated,
    required this.isEditingOriginal,
    required this.isEditingTranslation,
    required this.structureMode,
    required this.splitTargets,
    required this.isRepeating,
    required this.onToggleRepeat,
    required this.onSeek,
    required this.onEditOriginal,
    required this.onCancelOriginal,
    required this.onSaveOriginal,
    required this.onSplit,
    required this.onSpeakerChanged,
    required this.onEditTranslation,
    required this.onCancelTranslation,
    required this.onSaveTranslation,
    required this.onRetranslate,
  });

  final bool blindListening;
  final bool blurred;
  final TranscriptSegment segment;
  final List<TranscriptToken> tokens;
  final int positionMs;
  final bool isCurrent;
  final TranslationViewMode viewMode;
  final String query;
  final String speakerName;
  final List<SpeakerProfile> speakers;
  final bool showSpeaker;
  final bool showTimestamp;
  final bool highlightTranslated;
  final bool isEditingOriginal;
  final bool isEditingTranslation;
  final bool structureMode;
  final List<TranscriptSplitTarget> splitTargets;
  final bool isRepeating;
  final VoidCallback? onToggleRepeat;
  final TranscriptSegmentSeekCallback onSeek;
  final VoidCallback onEditOriginal;
  final VoidCallback onCancelOriginal;
  final Future<void> Function(String) onSaveOriginal;
  final Future<void> Function(int rightTokenIndex) onSplit;
  final Future<void> Function(String) onSpeakerChanged;
  final VoidCallback onEditTranslation;
  final VoidCallback onCancelTranslation;
  final Future<void> Function(String) onSaveTranslation;
  final Future<void> Function()? onRetranslate;

  @override
  State<TranscriptSegmentGroup> createState() => _TranscriptSegmentGroupState();
}

class _TranscriptSegmentGroupState extends State<TranscriptSegmentGroup> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final showOriginal = widget.viewMode != TranslationViewMode.translated;
    final showTranslation = widget.viewMode != TranslationViewMode.original;
    return MouseRegion(
      key: ValueKey('segment-group-${widget.segment.id}'),
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: TranscriptSegmentSurface(
        surfaceKey: ValueKey(
          widget.viewMode == TranslationViewMode.translated
              ? 'translated-segment-${widget.segment.id}'
              : 'segment-card-${widget.segment.id}',
        ),
        hovered: _hovered,
        isCurrent: widget.isCurrent,
        isEditing: widget.isEditingOriginal || widget.isEditingTranslation,
        highlightTranslated: widget.highlightTranslated,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showTimestamp ||
                (widget.showSpeaker && widget.speakerName.isNotEmpty))
              TranscriptSegmentMetadata(
                segment: widget.segment,
                query: widget.query,
                speakerName: widget.speakerName,
                speakers: widget.speakers,
                showSpeaker: widget.showSpeaker,
                showTimestamp: widget.showTimestamp,
                onSeek: widget.onSeek,
                onSpeakerChanged: widget.blindListening
                    ? null
                    : widget.onSpeakerChanged,
              ),
            if (showOriginal)
              TranscriptSegmentEditor(
                blindListening: widget.blindListening,
                blurred: widget.blurred,
                key: ValueKey(widget.segment.id),
                segment: widget.segment,
                tokens: widget.tokens,
                positionMs: widget.positionMs,
                isCurrent: widget.isCurrent,
                query: widget.query,
                speakerName: widget.speakerName,
                showSpeaker: false,
                showTimestamp: false,
                isEditing: widget.isEditingOriginal,
                structureMode: widget.structureMode,
                splitTargets: widget.splitTargets,
                isRepeating: widget.isRepeating,
                embedded: true,
                groupHovered: _hovered,
                onToggleRepeat: widget.onToggleRepeat,
                onSeek: widget.onSeek,
                onEdit: widget.onEditOriginal,
                onCancel: widget.onCancelOriginal,
                onSave: widget.onSaveOriginal,
                onSplit: widget.onSplit,
              ),
            if (showOriginal && showTranslation) const SizedBox(height: 6),
            if (showTranslation)
              KeyedSubtree(
                key: widget.viewMode == TranslationViewMode.bilingual
                    ? ValueKey('translated-segment-${widget.segment.id}')
                    : null,
                child: _TranslatedSegmentEditor(
                  blindListening: widget.blindListening,
                  blurred: widget.blurred,
                  key: ValueKey('translated-${widget.segment.id}'),
                  segment: widget.segment,
                  isCurrent: widget.isCurrent,
                  query: widget.query,
                  showTimestamp: false,
                  highlightTranslated: false,
                  isEditing: widget.isEditingTranslation,
                  showRepeatAction:
                      widget.viewMode == TranslationViewMode.translated,
                  isRepeating:
                      widget.viewMode == TranslationViewMode.translated &&
                      widget.isRepeating,
                  embedded: true,
                  groupHovered: _hovered,
                  bilingual: widget.viewMode == TranslationViewMode.bilingual,
                  onToggleRepeat:
                      widget.viewMode == TranslationViewMode.translated
                      ? widget.onToggleRepeat
                      : null,
                  onSeek: widget.onSeek,
                  onEdit: widget.onEditTranslation,
                  onCancel: widget.onCancelTranslation,
                  onSave: widget.onSaveTranslation,
                  onRetranslate: widget.onRetranslate,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class TranscriptSegmentSurface extends StatelessWidget {
  const TranscriptSegmentSurface({
    super.key,
    required this.surfaceKey,
    required this.hovered,
    required this.isCurrent,
    required this.isEditing,
    required this.highlightTranslated,
    required this.padding,
    required this.child,
  });

  final Key surfaceKey;
  final bool hovered;
  final bool isCurrent;
  final bool isEditing;
  final bool highlightTranslated;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final backgroundColor = isEditing
        ? colors.surfaceContainerLow
        : hovered
        ? colors.surfaceContainerLow
        : highlightTranslated
        ? translatedSegmentHighlightColor(context)
        : null;
    return DecoratedBox(
      key: surfaceKey,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: isEditing ? Border.all(color: colors.outlineVariant) : null,
      ),
      child: Stack(
        children: [
          Padding(padding: padding, child: child),
          Positioned(
            left: 0,
            top: 8,
            bottom: 8,
            child: AnimatedContainer(
              key: ValueKey('segment-current-indicator-$surfaceKey'),
              duration: const Duration(milliseconds: 120),
              width: 3,
              decoration: BoxDecoration(
                color: isCurrent ? colors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TranscriptSegmentMetadata extends StatelessWidget {
  const TranscriptSegmentMetadata({
    super.key,
    required this.segment,
    required this.query,
    required this.speakerName,
    this.speakers = const [],
    required this.showSpeaker,
    required this.showTimestamp,
    required this.onSeek,
    this.onSpeakerChanged,
  });

  final TranscriptSegment segment;
  final String query;
  final String speakerName;
  final List<SpeakerProfile> speakers;
  final bool showSpeaker;
  final bool showTimestamp;
  final TranscriptSegmentSeekCallback onSeek;
  final Future<void> Function(String)? onSpeakerChanged;

  @override
  Widget build(BuildContext context) {
    final showsSpeaker = showSpeaker && speakerName.isNotEmpty;
    final canChangeSpeaker =
        showsSpeaker && speakers.length > 1 && onSpeakerChanged != null;
    final speakerColor = colorForSpeaker(
      context,
      segment.speaker ?? speakerName,
    );
    final speakerLabel = SearchHighlightedText(
      key: ValueKey('segment-speaker-${segment.id}'),
      text: speakerName,
      query: query,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: speakerColor,
        fontWeight: FontWeight.w700,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showTimestamp)
            TextButton(
              key: ValueKey('segment-timestamp-${segment.id}'),
              onPressed: () =>
                  onSeek(reason: TranscriptSeekReason.sentenceClick),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                formatClock(segment.startMs),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          if (showTimestamp && showsSpeaker) const SizedBox(width: 8),
          if (showsSpeaker)
            Expanded(
              child: canChangeSpeaker
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: MenuAnchor(
                        key: ValueKey('segment-speaker-menu-${segment.id}'),
                        menuChildren: [
                          for (final speaker in speakers)
                            MenuItemButton(
                              key: ValueKey(
                                'segment-speaker-option-${segment.id}-${speaker.id}',
                              ),
                              leadingIcon: Icon(
                                speaker.id == segment.speaker
                                    ? Icons.check_rounded
                                    : Icons.circle,
                                size: speaker.id == segment.speaker ? 18 : 10,
                                color: colorForSpeaker(context, speaker.id),
                              ),
                              onPressed: speaker.id == segment.speaker
                                  ? null
                                  : () => unawaited(
                                      onSpeakerChanged!(speaker.id),
                                    ),
                              child: Text(
                                context.strings.speakerName(speaker.name),
                                style: TextStyle(
                                  color: colorForSpeaker(context, speaker.id),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                        builder: (context, menuController, child) => Tooltip(
                          message: context.strings.t('change_speaker'),
                          child: TextButton(
                            key: ValueKey(
                              'segment-speaker-dropdown-${segment.id}',
                            ),
                            onPressed: () => menuController.isOpen
                                ? menuController.close()
                                : menuController.open(),
                            style: TextButton.styleFrom(
                              foregroundColor: speakerColor,
                              minimumSize: Size.zero,
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(child: speakerLabel),
                                const SizedBox(width: 2),
                                const Icon(
                                  Icons.arrow_drop_down_rounded,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  : speakerLabel,
            ),
        ],
      ),
    );
  }
}

class _TranslatedSegmentEditor extends StatefulWidget {
  const _TranslatedSegmentEditor({
    this.blindListening = false,
    this.blurred = false,
    super.key,
    required this.segment,
    required this.isCurrent,
    required this.query,
    required this.showTimestamp,
    required this.highlightTranslated,
    required this.isEditing,
    required this.showRepeatAction,
    required this.isRepeating,
    this.embedded = false,
    this.groupHovered = false,
    this.bilingual = false,
    required this.onToggleRepeat,
    required this.onSeek,
    required this.onEdit,
    required this.onCancel,
    required this.onSave,
    required this.onRetranslate,
  });

  final bool blindListening;
  final bool blurred;
  final TranscriptSegment segment;
  final bool isCurrent;
  final String query;
  final bool showTimestamp;
  final bool highlightTranslated;
  final bool isEditing;
  final bool showRepeatAction;
  final bool isRepeating;
  final bool embedded;
  final bool groupHovered;
  final bool bilingual;
  final VoidCallback? onToggleRepeat;
  final TranscriptSegmentSeekCallback onSeek;
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
  bool _hovered = false;
  bool _actionFocused = false;
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

  void _seek() => widget.onSeek(reason: TranscriptSeekReason.sentenceClick);

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.onSave(_draft.text);
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final translated = widget.segment.translatedText?.trim();
    final fallback = translated == null || translated.isEmpty;
    final textStyle = widget.bilingual
        ? Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant)
        : Theme.of(context).textTheme.bodyLarge;
    final line = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTimestamp)
          TranscriptSegmentMetadata(
            segment: widget.segment,
            query: widget.query,
            speakerName: '',
            showSpeaker: false,
            showTimestamp: true,
            onSeek: widget.onSeek,
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: BlindListeningBlur(
                key: ValueKey('blind-translation-${widget.segment.id}'),
                blurred: widget.blurred,
                onHiddenTap: _seek,
                child: widget.isEditing
                    ? SelectionContainer.disabled(
                        child: CallbackShortcuts(
                          bindings: {
                            const SingleActivator(
                              LogicalKeyboardKey.enter,
                              meta: true,
                            ): _save,
                            const SingleActivator(
                              LogicalKeyboardKey.enter,
                              control: true,
                            ): _save,
                            const SingleActivator(LogicalKeyboardKey.escape):
                                widget.onCancel,
                          },
                          child: TextField(
                            key: ValueKey(
                              'translated-field-${widget.segment.id}',
                            ),
                            controller: _draft,
                            autofocus: true,
                            minLines: 1,
                            maxLines: null,
                            style: textStyle,
                            decoration: const InputDecoration(
                              isDense: true,
                              filled: false,
                              contentPadding: EdgeInsets.all(4),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                      )
                    : InkWell(
                        key: ValueKey('translated-text-${widget.segment.id}'),
                        onTap: _seek,
                        hoverColor: Colors.transparent,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: SearchHighlightedText(
                            text: fallback ? widget.segment.text : translated,
                            query: widget.query,
                            style: textStyle?.copyWith(
                              fontStyle: fallback ? FontStyle.italic : null,
                              color: fallback
                                  ? colors.onSurfaceVariant
                                  : textStyle.color,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 4),
            _buildActions(context),
          ],
        ),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.embedded
          ? KeyedSubtree(
              key: ValueKey('translated-line-${widget.segment.id}'),
              child: line,
            )
          : TranscriptSegmentSurface(
              surfaceKey: ValueKey('translated-segment-${widget.segment.id}'),
              hovered: _hovered,
              isCurrent: widget.isCurrent,
              isEditing: widget.isEditing,
              highlightTranslated: widget.highlightTranslated,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: line,
            ),
    );
  }

  Widget _buildActions(BuildContext context) {
    if (widget.isEditing) {
      final actionCount = (widget.isRepeating ? 1 : 0) + 2;
      return SizedBox(
        width: actionCount * 32,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.isRepeating)
              SentenceRepeatButton(
                segmentId: widget.segment.id,
                isRepeating: true,
                onPressed: widget.onToggleRepeat,
              ),
            IconButton(
              key: ValueKey('translated-cancel-${widget.segment.id}'),
              tooltip: context.strings.t('cancel'),
              onPressed: _saving ? null : widget.onCancel,
              style: compactSegmentActionStyle(context),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
            IconButton(
              key: ValueKey('translated-save-${widget.segment.id}'),
              tooltip: context.strings.t('save'),
              onPressed: _saving ? null : _save,
              style: compactSegmentActionStyle(context),
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
            ),
          ],
        ),
      );
    }
    final repeatVisible =
        widget.groupHovered || _hovered || _actionFocused || widget.isRepeating;
    final lineActionsVisible = _hovered || _actionFocused;
    final actionCount =
        (widget.showRepeatAction ? 1 : 0) +
        1 +
        (widget.onRetranslate != null ? 1 : 0);
    return Focus(
      onFocusChange: (value) => setState(() => _actionFocused = value),
      child: SizedBox(
        width: actionCount * 32,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showRepeatAction)
              SegmentActionVisibility(
                opacityKey: ValueKey(
                  'segment-repeat-opacity-${widget.segment.id}',
                ),
                visible: repeatVisible,
                child: SentenceRepeatButton(
                  segmentId: widget.segment.id,
                  isRepeating: widget.isRepeating,
                  onPressed: widget.onToggleRepeat,
                ),
              ),
            SegmentActionVisibility(
              opacityKey: ValueKey(
                'translated-edit-opacity-${widget.segment.id}',
              ),
              visible: lineActionsVisible,
              child: IconButton(
                key: ValueKey('translated-edit-${widget.segment.id}'),
                tooltip: context.strings.t('edit_translation'),
                onPressed: widget.blindListening ? null : widget.onEdit,
                style: compactSegmentActionStyle(context),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
            ),
            if (widget.onRetranslate != null)
              SegmentActionVisibility(
                opacityKey: ValueKey(
                  'translated-retranslate-opacity-${widget.segment.id}',
                ),
                visible: lineActionsVisible,
                child: IconButton(
                  key: ValueKey('translated-retranslate-${widget.segment.id}'),
                  tooltip: context.strings.t('retranslate_segment_with_llm'),
                  onPressed: widget.blindListening
                      ? null
                      : widget.onRetranslate,
                  style: compactSegmentActionStyle(context),
                  icon: const Icon(Icons.translate_rounded, size: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class SegmentActionVisibility extends StatelessWidget {
  const SegmentActionVisibility({
    super.key,
    this.opacityKey,
    required this.visible,
    required this.child,
  });

  final Key? opacityKey;
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedOpacity(
      key: opacityKey,
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: child,
    ),
  );
}

class SentenceRepeatButton extends StatelessWidget {
  const SentenceRepeatButton({
    super.key,
    required this.segmentId,
    required this.isRepeating,
    required this.onPressed,
  });

  final String segmentId;
  final bool isRepeating;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: ValueKey('segment-repeat-$segmentId'),
    tooltip: context.strings.t(
      isRepeating ? 'stop_repeating_sentence' : 'repeat_sentence',
    ),
    onPressed: onPressed,
    isSelected: isRepeating,
    style: compactSegmentActionStyle(context, selected: isRepeating),
    icon: const Icon(Icons.repeat_one_rounded, size: 18),
  );
}

ButtonStyle compactSegmentActionStyle(
  BuildContext context, {
  bool selected = false,
}) => IconButton.styleFrom(
  foregroundColor: selected
      ? Theme.of(context).colorScheme.onPrimaryContainer
      : null,
  backgroundColor: selected
      ? Theme.of(context).colorScheme.primaryContainer
      : null,
  minimumSize: Size.zero,
  fixedSize: const Size.square(32),
  maximumSize: const Size.square(32),
  padding: EdgeInsets.zero,
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class MediaModeButton extends StatelessWidget {
  const MediaModeButton({
    super.key,
    required this.destination,
    required this.onPressed,
  });

  final ReviewMediaMode destination;
  final VoidCallback onPressed;

  static const size = 44.0;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('video-audio-mode-toggle'),
    tooltip: context.strings.t(
      destination == ReviewMediaMode.video
          ? 'switch_to_video_mode'
          : 'switch_to_audio_mode',
    ),
    onPressed: onPressed,
    style: const ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size.square(size)),
      maximumSize: WidgetStatePropertyAll(Size.square(size)),
      padding: WidgetStatePropertyAll(EdgeInsets.all(10)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    icon: AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: RotationTransition(
          turns: Tween(begin: -.08, end: 0.0).animate(animation),
          child: child,
        ),
      ),
      child: Icon(
        destination == ReviewMediaMode.video
            ? Icons.videocam_rounded
            : Icons.headphones_rounded,
        key: ValueKey(destination),
      ),
    ),
  );
}

class VideoMediaHeader extends StatelessWidget {
  const VideoMediaHeader({super.key, required this.job});

  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('video-media-header'),
    height: TranscriptReviewState.videoTitleHeaderHeight,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ReviewFilename(job: job),
      ),
    ),
  );
}

class ReviewFilename extends StatelessWidget {
  const ReviewFilename({super.key, required this.job});

  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: job.displayName,
    waitDuration: const Duration(milliseconds: 400),
    child: Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Text(
        job.displayName,
        key: const Key('review-filename'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
  );
}
