import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

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

  ReviewFullscreenController get _fullscreenController =>
      widget.fullscreenController ?? _localFullscreenController;

  @override
  void initState() {
    super.initState();
    _localFullscreenController = ReviewFullscreenController();
  }

  @override
  Widget build(BuildContext context) {
    final job = context.watch<AppController>().activeWorkspaceJob;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: job == null
            ? const _EmptyWorkspace()
            : Column(
                children: [
                  if (job.podcastProvenance != null) ...[
                    _PodcastProvenanceBar(job: job),
                    const SizedBox(height: 10),
                  ],
                  Expanded(
                    child: TranscriptReview(
                      key: ValueKey('workspace-review-${job.id}'),
                      jobId: job.id,
                      fullscreenController: _fullscreenController,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _PodcastProvenanceBar extends StatelessWidget {
  const _PodcastProvenanceBar({required this.job});

  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) {
    final provenance = job.podcastProvenance!;
    final sourceKey =
        job.transcriptSource == TranscriptSource.publisher ||
            job.transcriptAcquisitionMode.usesPublisherTranscript
        ? 'podcast_source_publisher_captions'
        : 'podcast_source_soniox_words';
    final rawLink =
        provenance.episodeUrl ?? provenance.showUrl ?? provenance.feedUrl;
    final link = Uri.tryParse(rawLink);
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const Key('podcast-workspace-provenance'),
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.podcasts_rounded, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                provenance.showTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              context.strings.t(sourceKey),
              key: const Key('podcast-workspace-transcript-source'),
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (link != null && link.hasScheme) ...[
              const SizedBox(width: 6),
              IconButton(
                key: const Key('podcast-workspace-open-episode'),
                tooltip: context.strings.t('podcast_open_episode_page'),
                onPressed: () => launchUrl(link),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
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
      constraints: const BoxConstraints(maxWidth: 520),
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
  );
}
