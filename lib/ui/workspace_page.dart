import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'review_fullscreen_controller.dart';
import 'transcript_review.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key, this.fullscreenController});

  final ReviewFullscreenController? fullscreenController;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  late final ReviewFullscreenController _localFullscreenController;
  final Map<String, ForcedAlignmentStatus> _observedAlignmentStatuses =
      <String, ForcedAlignmentStatus>{};
  final Set<String> _visibleAlignmentNotices = <String>{};
  String? _observedWorkspaceJobId;

  ReviewFullscreenController get _fullscreenController =>
      widget.fullscreenController ?? _localFullscreenController;

  @override
  void initState() {
    super.initState();
    _localFullscreenController = ReviewFullscreenController();
  }

  @override
  Widget build(BuildContext context) {
    final job = context.select((AppController c) => c.activeWorkspaceJob);
    final showAlignmentNotice = _shouldShowAlignmentNotice(job);
    return SafeArea(
      child: job == null
          ? const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 18),
              child: _EmptyWorkspace(),
            )
          : Stack(
              key: const Key('workspace-active-review'),
              children: [
                Positioned.fill(
                  child: TranscriptReview(
                    key: ValueKey('workspace-review-${job.id}'),
                    jobId: job.id,
                    fullscreenController: _fullscreenController,
                  ),
                ),
                if (showAlignmentNotice)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: _MossTimingBar(
                          job: job,
                          onDismiss: () => setState(
                            () => _visibleAlignmentNotices.remove(job.id),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  bool _showsAlignment(TranscriptionJob job) => job.supportsLocalWordAlignment;

  bool _shouldShowAlignmentNotice(TranscriptionJob? job) {
    final jobId = job?.id;
    if (_observedWorkspaceJobId != jobId) {
      if (_observedWorkspaceJobId case final previousJobId?) {
        _visibleAlignmentNotices.remove(previousJobId);
      }
      _observedWorkspaceJobId = jobId;
    }
    if (job == null || !_showsAlignment(job)) return false;

    final current = job.forcedAlignment.status;
    final previous = _observedAlignmentStatuses[job.id];
    _observedAlignmentStatuses[job.id] = current;
    if (_isAlignmentActive(current)) {
      _visibleAlignmentNotices.add(job.id);
    } else if (previous != null &&
        _isAlignmentActive(previous) &&
        _isAlignmentResult(current)) {
      _visibleAlignmentNotices.add(job.id);
    }
    return _visibleAlignmentNotices.contains(job.id);
  }

  bool _isAlignmentActive(ForcedAlignmentStatus status) =>
      status == ForcedAlignmentStatus.queued ||
      status == ForcedAlignmentStatus.running;

  bool _isAlignmentResult(ForcedAlignmentStatus status) => switch (status) {
    ForcedAlignmentStatus.completed ||
    ForcedAlignmentStatus.partial ||
    ForcedAlignmentStatus.unavailable ||
    ForcedAlignmentStatus.failed ||
    ForcedAlignmentStatus.cancelled ||
    ForcedAlignmentStatus.interrupted => true,
    _ => false,
  };
}

class _MossTimingBar extends StatelessWidget {
  const _MossTimingBar({required this.job, required this.onDismiss});

  final TranscriptionJob job;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final alignment = job.forcedAlignment;
    final active =
        alignment.status == ForcedAlignmentStatus.queued ||
        alignment.status == ForcedAlignmentStatus.running;
    final local =
        job.transcriptSource == TranscriptSource.mossLocal ||
        job.transcriptionProvider == TranscriptionProvider.mossLocal;
    final qwen =
        job.transcriptSource == TranscriptSource.qwen3Local ||
        job.transcriptionProvider == TranscriptionProvider.qwen3Local;
    final labelKey = switch (alignment.status) {
      ForcedAlignmentStatus.completed =>
        qwen
            ? 'qwen_local_word_level'
            : local
            ? 'moss_local_word_level'
            : 'moss_pro_local_alignment',
      ForcedAlignmentStatus.partial =>
        qwen
            ? 'qwen_local_partial_alignment'
            : local
            ? 'moss_local_partial_alignment'
            : 'moss_pro_partial_alignment',
      ForcedAlignmentStatus.queued ||
      ForcedAlignmentStatus.running => 'moss_alignment_running',
      _ =>
        qwen
            ? 'qwen_local_segment_level'
            : local
            ? 'moss_local_segment_level'
            : 'moss_pro_segment_level',
    };
    final colors = Theme.of(context).colorScheme;
    final usefulPartial =
        alignment.status == ForcedAlignmentStatus.partial &&
        alignment.alignedSegments > 0 &&
        alignment.totalSegments > 0;
    final coverage = usefulPartial
        ? context.strings
              .t('alignment_segment_coverage')
              .replaceFirst('{aligned}', '${alignment.alignedSegments}')
              .replaceFirst('{total}', '${alignment.totalSegments}')
        : null;
    final visibleWarning = alignment.warningCode;
    final provenanceLabel = context.strings.t(labelKey);
    return Material(
      key: const Key('workspace-moss-timing-status'),
      color: colors.surfaceContainerHigh,
      elevation: 6,
      shadowColor: colors.shadow.withValues(alpha: 0.22),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (active)
              SizedBox.square(
                key: const Key('workspace-alignment-processing'),
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              )
            else
              Icon(
                alignment.hasWordTiming
                    ? Icons.graphic_eq_rounded
                    : Icons.segment_rounded,
                size: 18,
                color: colors.primary,
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  provenanceLabel,
                  if (coverage case final value?) value,
                ].join(' · '),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            if (visibleWarning case final warning?)
              Tooltip(
                message:
                    alignment.warningMessage ?? context.strings.error(warning),
                child: const Icon(Icons.warning_amber_rounded, size: 18),
              ),
            if (!active) ...[
              const SizedBox(width: 4),
              IconButton(
                key: const Key('dismiss-alignment-notification'),
                tooltip: context.strings.t('close'),
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyWorkspace extends StatelessWidget {
  const _EmptyWorkspace();

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: SizedBox(
        width: double.infinity,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.edit_note_rounded,
                  size: 68,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  context.strings.t('no_transcript_open'),
                  key: const Key('workspace-empty-title'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  context.strings.t('open_transcript_hint'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 22),
                OutlinedButton.icon(
                  key: const Key('workspace-go-to-library'),
                  onPressed: () => context.read<AppController>().setDestination(
                    AppDestination.library,
                  ),
                  icon: const Icon(Icons.library_books_outlined),
                  label: Text(context.strings.t('browse_library')),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
