part of '../transcript_review.dart';

class _ReviewSplitDivider extends StatelessWidget {
  const _ReviewSplitDivider({
    this.dividerKey = const Key('video-transcript-divider'),
    required this.onDragUpdate,
  });

  final Key dividerKey;
  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.strings.t('resize_review_panels'),
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: dividerKey,
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDragUpdate(details.delta.dx),
        child: SizedBox(
          width: _TranscriptReviewState._reviewDividerWidth,
          child: Center(
            child: VerticalDivider(
              width: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ReviewContentTabs extends StatelessWidget {
  const _ReviewContentTabs({
    required this.width,
    this.aiBriefEnabled = true,
    required this.showAiBrief,
    required this.onChanged,
  });

  final double width;
  final bool aiBriefEnabled;
  final bool showAiBrief;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: SegmentedButton<bool>(
      key: const Key('review-content-tabs'),
      showSelectedIcon: false,
      style: const ButtonStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
      ),
      segments: [
        ButtonSegment(
          value: false,
          label: Text(
            context.strings.t('transcript'),
            maxLines: 1,
            softWrap: false,
          ),
        ),
        ButtonSegment(
          value: true,
          enabled: aiBriefEnabled,
          label: Text(
            context.strings.t('ai_brief'),
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ],
      selected: {showAiBrief},
      onSelectionChanged: (values) => onChanged(values.first),
    ),
  );
}

