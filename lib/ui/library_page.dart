import 'package:file_selector/file_selector.dart';
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
        padding: const EdgeInsets.fromLTRB(28, 22, 28, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.strings.t('library'),
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
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
                      value: 'failed',
                      child: Text(context.strings.t('failed')),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _status = value ?? 'all'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
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
            const SizedBox(height: 14),
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
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) =>
                          _HistoryCard(job: jobs[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  bool _matches(TranscriptionJob job) {
    if (_query.isNotEmpty &&
        !job.fileName.toLowerCase().contains(_query.toLowerCase())) {
      return false;
    }
    if (_status == 'completed' && job.status != JobStatus.completed) {
      return false;
    }
    if (_status == 'failed' &&
        job.status != JobStatus.failed &&
        job.status != JobStatus.missingSource) {
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
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
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
            const SizedBox(width: 14),
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
                onPressed: () async {
                  final file = await openFile();
                  if (file != null) await controller.relink(job.id, file.path);
                },
                icon: const Icon(Icons.link_rounded),
                label: Text(context.strings.t('relink')),
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
