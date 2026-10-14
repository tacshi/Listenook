import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../data/timed_subtitle_import.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'app_notice.dart';

Future<void> reviewAndEnqueueSources(
  BuildContext context,
  Iterable<String> paths,
) async {
  final values = paths.toList(growable: false);
  if (values.isEmpty) return;
  final controller = context.read<AppController>();
  SubtitleImportReview? review;
  try {
    review = await controller.previewSourceImports(values);
  } on Object {
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: context.strings.t('subtitle_import_failed'),
      tone: AppNoticeTone.error,
    );
    return;
  }
  if (!context.mounted) return;
  if (review == null) {
    await controller.enqueueSources(values, allowLocalAutoStart: false);
    return;
  }
  final selections = await showSubtitleImportReviewDialog(context, review);
  if (selections == null || !context.mounted) return;
  try {
    await controller.enqueueReviewedImports(selections);
  } on Object {
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: context.strings.t('subtitle_import_failed'),
      tone: AppNoticeTone.error,
    );
  }
}

Future<List<SubtitleImportSelection>?> showSubtitleImportReviewDialog(
  BuildContext context,
  SubtitleImportReview review,
) => showDialog<List<SubtitleImportSelection>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _SubtitleImportReviewDialog(review: review),
);

class _SubtitleImportReviewDialog extends StatefulWidget {
  const _SubtitleImportReviewDialog({required this.review});

  final SubtitleImportReview review;

  @override
  State<_SubtitleImportReviewDialog> createState() =>
      _SubtitleImportReviewDialogState();
}

class _SubtitleImportReviewDialogState
    extends State<_SubtitleImportReviewDialog> {
  final Map<String, String?> _selectedPaths = {};
  final Set<String> _decidedMedia = {};

  List<SubtitleFileCandidate> get _allCandidates {
    final result = <String, SubtitleFileCandidate>{};
    for (final match in widget.review.media) {
      for (final candidate in match.candidates) {
        result[candidate.path] = candidate;
      }
    }
    for (final candidate in widget.review.unmatchedSubtitles) {
      result[candidate.path] = candidate;
    }
    return result.values.toList(growable: false)
      ..sort((left, right) => left.displayName.compareTo(right.displayName));
  }

  @override
  void initState() {
    super.initState();
    for (final match in widget.review.media) {
      final automatic = match.automaticCandidate;
      _selectedPaths[match.media.path] = automatic?.path;
      if (automatic != null || match.candidates.isEmpty) {
        _decidedMedia.add(match.media.path);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final duplicates = _selectedPaths.values.whereType<String>().toList();
    final hasDuplicateSelection =
        duplicates.toSet().length != duplicates.length;
    final unresolved = widget.review.media.any(
      (match) => !_decidedMedia.contains(match.media.path),
    );
    final canSubmit =
        widget.review.media.isNotEmpty && !hasDuplicateSelection && !unresolved;
    return AlertDialog(
      key: const Key('subtitle-import-review-dialog'),
      title: Text(context.strings.t('subtitle_import_review_title')),
      content: SizedBox(
        width: 760,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _BenefitChip(
                  icon: Icons.laptop_mac_rounded,
                  label: context.strings.t('subtitle_import_stays_local'),
                ),
                _BenefitChip(
                  icon: Icons.savings_outlined,
                  label: context.strings.t('subtitle_import_no_stt_charge'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              context.strings.t('subtitle_import_translation_disclosure'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 24),
            Expanded(
              child: widget.review.media.isEmpty
                  ? Center(
                      child: Text(
                        context.strings.t('subtitle_import_media_required'),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: widget.review.media.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) =>
                          _buildMediaRow(widget.review.media[index]),
                    ),
            ),
            if (widget.review.unmatchedSubtitles.isNotEmpty) ...[
              const SizedBox(height: 8),
              _WarningLine(
                text: context.strings
                    .t('subtitle_import_unmatched_count')
                    .replaceFirst(
                      '{count}',
                      '${widget.review.unmatchedSubtitles.length}',
                    ),
              ),
            ],
            if (hasDuplicateSelection) ...[
              const SizedBox(height: 8),
              _WarningLine(
                text: context.strings.t('subtitle_import_duplicate_selection'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.strings.t('cancel')),
        ),
        FilledButton(
          key: const Key('subtitle-import-confirm'),
          onPressed: canSubmit ? _submit : null,
          child: Text(
            context.strings
                .t('subtitle_import_add_count')
                .replaceFirst('{count}', '${widget.review.media.length}'),
          ),
        ),
      ],
    );
  }

  Widget _buildMediaRow(MediaSubtitleMatch match) {
    final candidates = _allCandidates;
    final selectedPath = _selectedPaths[match.media.path];
    final selected = candidates
        .where((candidate) => candidate.path == selectedPath)
        .firstOrNull;
    final reviewedCandidate =
        selected ??
        (match.candidates.length == 1 ? match.candidates.single : null);
    final result = reviewedCandidate?.parseResult;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.movie_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    match.media.path.replaceAll('\\', '/').split('/').last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              key: ValueKey('subtitle-choice-${match.media.path}'),
              isExpanded: true,
              initialValue: selectedPath,
              decoration: InputDecoration(
                labelText: context.strings.t('subtitle_file'),
                prefixIcon: const Icon(Icons.subtitles_outlined),
              ),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(
                    context.strings.t('subtitle_import_transcribe_normally'),
                  ),
                ),
                for (final candidate in candidates)
                  DropdownMenuItem<String?>(
                    value: candidate.path,
                    enabled: candidate.isValid,
                    child: Text(
                      candidate.isValid
                          ? candidate.displayName
                          : '${candidate.displayName} · ${context.strings.t('invalid')}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (path) {
                setState(() {
                  _selectedPaths[match.media.path] = path;
                  _decidedMedia.add(match.media.path);
                });
              },
            ),
            if (result != null) ...[
              const SizedBox(height: 8),
              Text(
                context.strings
                    .t('subtitle_import_cue_summary')
                    .replaceFirst('{format}', result.format.label)
                    .replaceFirst(
                      '{count}',
                      '${result.document.segments.length}',
                    ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (result.ignoredCueCount > 0)
                _WarningLine(
                  text: context.strings
                      .t('subtitle_import_ignored_cues')
                      .replaceFirst('{count}', '${result.ignoredCueCount}'),
                ),
              if (reviewedCandidate?.errorCode case final errorCode?)
                _WarningLine(text: context.strings.error(errorCode)),
            ],
          ],
        ),
      ),
    );
  }

  void _submit() {
    final candidates = _allCandidates;
    Navigator.pop(context, [
      for (final match in widget.review.media)
        SubtitleImportSelection(
          media: match.media,
          subtitle: candidates
              .where(
                (candidate) =>
                    candidate.path == _selectedPaths[match.media.path],
              )
              .firstOrNull,
        ),
    ]);
  }
}

class _BenefitChip extends StatelessWidget {
  const _BenefitChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: Icon(icon, size: 18),
    label: Text(label),
    visualDensity: VisualDensity.compact,
  );
}

class _WarningLine extends StatelessWidget {
  const _WarningLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 17,
          color: Theme.of(context).colorScheme.tertiary,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
