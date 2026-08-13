import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
            : TranscriptReview(
                key: ValueKey('workspace-review-${job.id}'),
                jobId: job.id,
                fullscreenController: _fullscreenController,
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
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('workspace-go-to-inbox'),
                    onPressed: () => context
                        .read<AppController>()
                        .setDestination(AppDestination.inbox),
                    icon: const Icon(Icons.inbox_rounded),
                    label: Text(context.strings.t('go_to_inbox')),
                  ),
                  OutlinedButton.icon(
                    key: const Key('workspace-go-to-library'),
                    onPressed: () => context
                        .read<AppController>()
                        .setDestination(AppDestination.library),
                    icon: const Icon(Icons.library_books_outlined),
                    label: Text(context.strings.t('browse_library')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
