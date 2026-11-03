import 'package:material_ui/material_ui.dart';

import '../../l10n/strings.dart';
import '../platform/platform_context.dart';
import 'transcript_review_state.dart';

class ReviewSplitDivider extends StatelessWidget {
  const ReviewSplitDivider({
    super.key,
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
          width: TranscriptReviewState.reviewDividerWidthOf(context),
          child: Center(
            child: context.touchActive
                // A grip shows where to drag.
                ? Container(
                    width: 5,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outline,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  )
                : VerticalDivider(
                    width: 1,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
          ),
        ),
      ),
    ),
  );
}

class ReviewContentTabs extends StatelessWidget {
  const ReviewContentTabs({
    super.key,
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
