import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../data/transcript_exporter.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'workspace_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _query = '';
  String _status = 'all';
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final jobs = controller.allJobs.where(_matches).toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  context.strings.t('library'),
                  key: const Key('library-page-title'),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      hintText: context.strings.t('search_library'),
                      prefixIcon: const Icon(Icons.search_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _status,
                  items: [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text(context.strings.t('all')),
                    ),
                    DropdownMenuItem(
                      value: 'completed',
                      child: Text(context.strings.t('completed')),
                    ),
                    DropdownMenuItem(
                      value: 'attention',
                      child: Text(context.strings.t('failed')),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _status = value ?? 'all'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: Text(context.strings.t('all')),
                        selected: _filter == 'all',
                        onSelected: (_) => setState(() => _filter = 'all'),
                      ),
                      ChoiceChip(
                        label: Text(context.strings.t('last_7_days')),
                        selected: _filter == 'recent',
                        onSelected: (_) => setState(() => _filter = 'recent'),
                      ),
                      ChoiceChip(
                        label: Text(context.strings.t('under_30m')),
                        selected: _filter == 'short',
                        onSelected: (_) => setState(() => _filter = 'short'),
                      ),
                      ChoiceChip(
                        label: Text(context.strings.t('over_30m')),
                        selected: _filter == 'long',
                        onSelected: (_) => setState(() => _filter = 'long'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  key: const Key('clear-all-history'),
                  onPressed: controller.inactiveHistoryCount == 0
                      ? null
                      : () => _confirmClearAll(context, controller),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: Text(context.strings.t('clear_all')),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: jobs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.library_books_outlined,
                            size: 64,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 16),
                          Text(context.strings.t('no_history')),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: jobs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _HistoryCard(job: jobs[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearAll(
    BuildContext context,
    AppController controller,
  ) async {
    final count = controller.inactiveHistoryCount;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.t('clear_history_title')),
        content: Text(
          context.strings
              .t('clear_history_body')
              .replaceFirst('{count}', '$count'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            key: const Key('confirm-clear-all-history'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.t('clear_all')),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.clearInactiveHistory();
  }

  bool _matches(TranscriptionJob job) {
    if (_query.isNotEmpty &&
        !job.fileName.toLowerCase().contains(_query.toLowerCase())) {
      return false;
    }
    if (_status == 'completed' && job.status != JobStatus.completed) {
      return false;
    }
    if (_status == 'attention' &&
        !job.status.canTranscribe &&
        !job.status.canRetry) {
      return false;
    }
    if (_filter == 'recent' &&
        job.createdAt.isBefore(
          DateTime.now().subtract(const Duration(days: 7)),
        )) {
      return false;
    }
    final duration = job.metadata?.durationMs ?? 0;
    if (_filter == 'short' && duration >= 30 * 60 * 1000) return false;
    if (_filter == 'long' && duration < 30 * 60 * 1000) return false;
    return true;
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.job});
  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                job.metadata?.hasVideo ?? false
                    ? Icons.movie_outlined
                    : Icons.audio_file_outlined,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.fileName,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${job.createdAt.toLocal().toString().substring(0, 16)} · '
                    '${formatClock(job.metadata?.durationMs ?? 0)} · '
                    '${context.strings.t('job_${job.status.name}')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (job.status == JobStatus.missingSource)
              TextButton.icon(
                onPressed: () => chooseAndRelink(context, job.id),
                icon: const Icon(Icons.link_rounded),
                label: Text(context.strings.t('relink')),
              ),
            if (job.status == JobStatus.ready)
              OutlinedButton.icon(
                key: Key('continue-ready-job-${job.id}'),
                onPressed: () => controller.continueReadyJob(job.id),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(context.strings.t('continue')),
              ),
            if (job.document != null) ...[
              TextButton.icon(
                onPressed: () => showExportDialog(context, jobId: job.id),
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(context.strings.t('export')),
              ),
              FilledButton.tonalIcon(
                onPressed: () => controller.reopen(job.id),
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(context.strings.t('open')),
              ),
            ],
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'delete') controller.deleteHistory(job.id);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'delete',
                  child: Text(context.strings.t('delete_history')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
