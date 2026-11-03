import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models.dart';
import '../../core/transcript_structure_editor.dart';
import '../../l10n/strings.dart';
import '../transcript_structure_cursor.dart';
import '../keyboard_shortcuts.dart';
import '../platform/platform_context.dart';
import '../transcript_review.dart';
import 'transcript_segments.dart';

class TranscriptSegmentEditor extends StatefulWidget {
  const TranscriptSegmentEditor({
    this.blindListening = false,
    this.blurred = false,
    super.key,
    required this.segment,
    required this.tokens,
    required this.positionMs,
    required this.isCurrent,
    required this.query,
    required this.speakerName,
    required this.showSpeaker,
    required this.showTimestamp,
    this.highlightTranslated = false,
    required this.isEditing,
    this.structureMode = false,
    this.splitTargets = const [],
    this.isRepeating = false,
    this.embedded = false,
    this.groupHovered = false,
    this.onToggleRepeat,
    required this.onSeek,
    required this.onEdit,
    required this.onCancel,
    required this.onSave,
    this.onSplit,
  });

  final bool blindListening;
  final bool blurred;
  final TranscriptSegment segment;
  final List<TranscriptToken> tokens;
  final int positionMs;
  final bool isCurrent;
  final String query;
  final String speakerName;
  final bool showSpeaker;
  final bool showTimestamp;
  final bool highlightTranslated;
  final bool isEditing;
  final bool structureMode;
  final List<TranscriptSplitTarget> splitTargets;
  final bool isRepeating;
  final bool embedded;
  final bool groupHovered;
  final VoidCallback? onToggleRepeat;
  final TranscriptSegmentSeekCallback onSeek;
  final VoidCallback onEdit;
  final VoidCallback onCancel;
  final Future<void> Function(String text) onSave;
  final Future<void> Function(int rightTokenIndex)? onSplit;

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

  void _seek() => widget.onSeek(reason: TranscriptSeekReason.sentenceClick);

  @override
  Widget build(BuildContext context) {
    final line = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTimestamp || _showsSpeaker)
          TranscriptSegmentMetadata(
            segment: widget.segment,
            query: widget.query,
            speakerName: widget.speakerName,
            showSpeaker: widget.showSpeaker,
            showTimestamp: widget.showTimestamp,
            onSeek: widget.onSeek,
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: BlindListeningBlur(
                key: ValueKey('blind-original-${widget.segment.id}'),
                blurred: widget.blurred,
                onHiddenTap: _seek,
                child: _buildContent(context),
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
              key: ValueKey('segment-original-line-${widget.segment.id}'),
              child: line,
            )
          : TranscriptSegmentSurface(
              surfaceKey: ValueKey('segment-card-${widget.segment.id}'),
              hovered: _hovered,
              isCurrent: widget.isCurrent,
              isEditing: widget.isEditing,
              highlightTranslated: widget.highlightTranslated,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: line,
            ),
    );
  }

  bool get _showsSpeaker => widget.showSpeaker && widget.speakerName.isNotEmpty;

  Widget _buildContent(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.isEditing)
        SelectionContainer.disabled(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _save,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _save,
              const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
              commandPeriod: widget.onCancel,
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
      else if (widget.structureMode)
        _TranscriptStructureSplitText(
          key: ValueKey('structure-split-${widget.segment.id}'),
          segmentId: widget.segment.id,
          text: widget.segment.text,
          targets: widget.splitTargets,
          tokens: widget.tokens,
          positionMs: widget.positionMs,
          segmentStartMs: widget.segment.startMs,
          segmentEndMs: widget.segment.endMs,
          isCurrent: widget.isCurrent,
          onSplit: widget.onSplit,
        )
      else
        InkWell(
          key: ValueKey('segment-text-${widget.segment.id}'),
          onTap: _seek,
          hoverColor: Colors.transparent,
          child: Padding(
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
        ),
    ],
  );

  Widget _buildActions(BuildContext context) {
    if (widget.isEditing) {
      final actionCount = (widget.isRepeating ? 1 : 0) + 2;
      return SizedBox(
        width: actionCount * segmentActionExtent(context),
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
              key: ValueKey('segment-cancel-${widget.segment.id}'),
              tooltip: context.strings.t('cancel'),
              onPressed: _saving ? null : widget.onCancel,
              style: compactSegmentActionStyle(context),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
            IconButton(
              key: ValueKey('segment-save-${widget.segment.id}'),
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
    // Fingers cannot hover: the sentence being listened to (a tap makes a
    // sentence current) shows its actions instead.
    final touchCurrent = context.touchActive && widget.isCurrent;
    final repeatVisible =
        widget.groupHovered ||
        _hovered ||
        _actionFocused ||
        widget.isRepeating ||
        touchCurrent;
    final editVisible = _hovered || _actionFocused || touchCurrent;
    return Focus(
      onFocusChange: (value) => setState(() => _actionFocused = value),
      child: SizedBox(
        width: 2 * segmentActionExtent(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
              opacityKey: ValueKey('segment-edit-opacity-${widget.segment.id}'),
              visible: editVisible,
              child: IconButton(
                key: ValueKey('segment-edit-${widget.segment.id}'),
                tooltip: context.strings.t('edit'),
                onPressed: widget.blindListening ? null : widget.onEdit,
                style: compactSegmentActionStyle(context),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TranscriptStructureSplitText extends StatefulWidget {
  const _TranscriptStructureSplitText({
    super.key,
    required this.segmentId,
    required this.text,
    required this.targets,
    required this.tokens,
    required this.positionMs,
    required this.segmentStartMs,
    required this.segmentEndMs,
    required this.isCurrent,
    required this.onSplit,
  });

  final String segmentId;
  final String text;
  final List<TranscriptSplitTarget> targets;
  final List<TranscriptToken> tokens;
  final int positionMs;
  final int segmentStartMs;
  final int segmentEndMs;
  final bool isCurrent;
  final Future<void> Function(int rightTokenIndex)? onSplit;

  @override
  State<_TranscriptStructureSplitText> createState() =>
      _TranscriptStructureSplitTextState();
}

class _TranscriptStructureSplitTextState
    extends State<_TranscriptStructureSplitText> {
  TranscriptSplitTarget? _hoveredTarget;

  @override
  void didUpdateWidget(covariant _TranscriptStructureSplitText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.targets.contains(_hoveredTarget)) _hoveredTarget = null;
  }

  TranscriptSplitTarget? _nearestTarget(
    BuildContext context,
    Offset localPosition,
    double width,
    TextStyle? style,
  ) {
    if (widget.targets.isEmpty || width <= 0) return null;
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.localeOf(context),
    )..layout(maxWidth: width);
    final position = painter.getPositionForOffset(localPosition).offset;
    return widget.targets.reduce(
      (best, candidate) =>
          (candidate.textOffset - position).abs() <
              (best.textOffset - position).abs()
          ? candidate
          : best,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge;
    final pending = context.touchActive ? _hoveredTarget : null;
    final text = LayoutBuilder(
      builder: (context, constraints) => MouseRegion(
        cursor: _hoveredTarget == null
            ? SystemMouseCursors.basic
            : TranscriptStructureCursors.split,
        onHover: (event) {
          final target = _nearestTarget(
            context,
            event.localPosition,
            constraints.maxWidth,
            style,
          );
          if (target != _hoveredTarget) {
            setState(() => _hoveredTarget = target);
          }
        },
        onExit: (_) => setState(() => _hoveredTarget = null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final target = _nearestTarget(
              context,
              details.localPosition,
              constraints.maxWidth,
              style,
            );
            if (target == null || widget.onSplit == null) return;
            // A finger cannot preview by hovering: the first tap places the
            // split, a second tap there (or the button) applies it.
            if (context.touchActive && target != _hoveredTarget) {
              setState(() => _hoveredTarget = target);
              return;
            }
            unawaited(widget.onSplit!(target.rightTokenIndex));
          },
          child: Stack(
            children: [
              PlaybackHighlightedText(
                text: widget.text,
                tokens: widget.tokens,
                positionMs: widget.positionMs,
                segmentStartMs: widget.segmentStartMs,
                segmentEndMs: widget.segmentEndMs,
                enabled: widget.isCurrent,
                style: style,
              ),
              if (_hoveredTarget case final target?)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      key: ValueKey(
                        'structure-split-preview-${widget.segmentId}',
                      ),
                      painter: _TranscriptSplitPreviewPainter(
                        text: widget.text,
                        textOffset: target.textOffset,
                        style: style,
                        textDirection: Directionality.of(context),
                        textScaler: MediaQuery.textScalerOf(context),
                        locale: Localizations.localeOf(context),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (pending == null || widget.onSplit == null) return text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        text,
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: FilledButton.tonalIcon(
            key: ValueKey('structure-split-confirm-${widget.segmentId}'),
            onPressed: () {
              setState(() => _hoveredTarget = null);
              unawaited(widget.onSplit!(pending.rightTokenIndex));
            },
            icon: const Icon(Icons.content_cut_rounded, size: 18),
            label: Text(context.strings.t('transcript_split_here')),
          ),
        ),
      ],
    );
  }
}

class _TranscriptSplitPreviewPainter extends CustomPainter {
  const _TranscriptSplitPreviewPainter({
    required this.text,
    required this.textOffset,
    required this.style,
    required this.textDirection,
    required this.textScaler,
    required this.locale,
    required this.color,
  });

  final String text;
  final int textOffset;
  final TextStyle? style;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final Locale locale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: size.width);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: textOffset),
      Rect.zero,
    );
    final height = painter.getFullHeightForCaret(
      TextPosition(offset: textOffset),
      Rect.zero,
    );
    canvas.drawLine(
      caret.translate(0, 1),
      caret.translate(0, max(2, height - 1)),
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _TranscriptSplitPreviewPainter oldDelegate) =>
      oldDelegate.text != text ||
      oldDelegate.textOffset != textOffset ||
      oldDelegate.style != style ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.locale != locale ||
      oldDelegate.color != color;
}

class TranscriptMergeBoundary extends StatefulWidget {
  const TranscriptMergeBoundary({
    super.key,
    required this.enabled,
    required this.onMerge,
  });

  final bool enabled;
  final Future<void> Function() onMerge;

  @override
  State<TranscriptMergeBoundary> createState() =>
      _TranscriptMergeBoundaryState();
}

class _TranscriptMergeBoundaryState extends State<TranscriptMergeBoundary> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Without hover the boundary stays visible and finger-sized.
    final touch = context.touchActive;
    return MouseRegion(
      cursor: widget.enabled
          ? TranscriptStructureCursors.merge
          : SystemMouseCursors.forbidden,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? () => unawaited(widget.onMerge()) : null,
        child: Semantics(
          button: true,
          enabled: widget.enabled,
          label: context.strings.t('transcript_merge_here'),
          child: SizedBox(
            height: touch ? 40 : 14,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 100),
              opacity: _hovered ? 1 : (touch ? .6 : 0),
              child: Row(
                children: [
                  Expanded(
                    child: Divider(
                      color: widget.enabled
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    widget.enabled
                        ? Icons.compress_rounded
                        : Icons.block_rounded,
                    size: touch ? 20 : 14,
                    color: widget.enabled
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Divider(
                      color: widget.enabled
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
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
