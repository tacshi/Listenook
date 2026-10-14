part of '../transcript_review.dart';

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

/// Finds a neighboring timed cue without assuming there is a cue in a gap.
int? sentenceNavigationTarget(
  List<TranscriptSegment> segments,
  int positionMs, {
  required bool forward,
}) {
  final current = currentListeningSegmentIndex(segments, positionMs);
  bool usable(int index) =>
      segments[index].startMs >= 0 &&
      segments[index].endMs > segments[index].startMs;
  if (current != null) {
    for (
      var index = current + (forward ? 1 : -1);
      index >= 0 && index < segments.length;
      index += forward ? 1 : -1
    ) {
      if (usable(index)) return index;
    }
    return null;
  }
  int? best;
  for (var index = 0; index < segments.length; index++) {
    if (!usable(index)) continue;
    final start = segments[index].startMs;
    if (forward ? start > positionMs : segments[index].endMs <= positionMs) {
      if (best == null ||
          (forward
              ? start < segments[best].startMs
              : start > segments[best].startMs)) {
        best = index;
      }
    }
  }
  return best;
}

class BlindListeningBlur extends StatelessWidget {
  const BlindListeningBlur({
    super.key,
    required this.blurred,
    required this.child,
    this.onHiddenTap,
  });
  final bool blurred;
  final Widget child;
  final VoidCallback? onHiddenTap;

  @override
  Widget build(BuildContext context) {
    final registrar = SelectionContainer.maybeOf(context);
    // Keep text elements and their inherited dependencies mounted across toggles.
    // Hidden text never registers with the enclosing selection area.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: blurred ? onHiddenTap : null,
      child: SelectionRegistrarScope(
        registrar: blurred
            ? const _BlindSelectionRegistrar()
            : registrar ?? const _BlindSelectionRegistrar(),
        child: ExcludeSemantics(
          excluding: blurred,
          child: IgnorePointer(
            ignoring: blurred,
            child: ClipRect(
              child: ImageFiltered(
                enabled: blurred,
                imageFilter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BlindSelectionRegistrar implements SelectionRegistrar {
  const _BlindSelectionRegistrar();

  @override
  void add(Selectable selectable) {}

  @override
  void remove(Selectable selectable) {}
}

class SentenceRevealButton extends StatelessWidget {
  const SentenceRevealButton({
    super.key,
    required this.revealed,
    required this.onPressed,
  });
  final bool revealed;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('reveal-current-sentence'),
    tooltip:
        '${context.strings.t(revealed ? 'blur_current_sentence' : 'reveal_current_sentence')} (S)',
    onPressed: onPressed,
    isSelected: revealed,
    constraints: const BoxConstraints.tightFor(width: 40, height: 40),
    padding: EdgeInsets.zero,
    icon: Icon(
      revealed ? Icons.visibility_rounded : Icons.visibility_off_rounded,
    ),
  );
}

class SentenceNavigationControls extends StatelessWidget {
  const SentenceNavigationControls({
    super.key,
    required this.onPrevious,
    required this.onNext,
    this.previousLabel = 'previous_sentence',
    this.nextLabel = 'next_sentence',
    this.altModifier = true,
  });
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String previousLabel;
  final String nextLabel;

  /// Whether the arrow shortcut needs Alt (review) or not (video player).
  final bool altModifier;

  String get _modifier => altModifier ? (Platform.isMacOS ? '⌥' : 'Alt+') : '';

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        key: const Key('previous-sentence'),
        tooltip: '${context.strings.t(previousLabel)} ($_modifier←)',
        onPressed: onPrevious,
        constraints: const BoxConstraints.tightFor(width: 32, height: 40),
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.skip_previous_rounded),
      ),
      IconButton(
        key: const Key('next-sentence'),
        tooltip: '${context.strings.t(nextLabel)} ($_modifier→)',
        onPressed: onNext,
        constraints: const BoxConstraints.tightFor(width: 32, height: 40),
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.skip_next_rounded),
      ),
    ],
  );
}

/// Uses the established overlap resolver, but treats gaps as no active cue.
int? currentListeningSegmentIndex(
  List<TranscriptSegment> segments,
  int positionMs,
) {
  final index = currentTranscriptSegmentIndex(segments, positionMs);
  if (index == null || positionMs >= segments[index].endMs) return null;
  return index;
}
