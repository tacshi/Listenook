import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../data/transcript_exporter.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'transcript_review.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.onAddFiles,
    required this.onAddFolder,
  });

  final VoidCallback onAddFiles;
  final VoidCallback onAddFolder;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        controller.addSources(details.files.map((file) => file.path));
      },
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                onAddFiles: widget.onAddFiles,
                onAddFolder: widget.onAddFolder,
                onNewSession: () => _startNewSession(context, controller),
              ),
              const SizedBox(height: 12),
              if (controller.workspaceJobs.isEmpty)
                Expanded(
                  child: _EmptyDropZone(
                    dragging: _dragging,
                    onAddFiles: widget.onAddFiles,
                  ),
                )
              else
                Expanded(child: _WorkspaceBody(dragging: _dragging)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.onAddFiles,
    required this.onAddFolder,
    required this.onNewSession,
  });
  final VoidCallback onAddFiles;
  final VoidCallback onAddFolder;
  final VoidCallback onNewSession;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final showFullLabels = MediaQuery.sizeOf(context).width >= 1180;
    final isNewTranscription = controller.selectedJob?.document == null;
    final actions = <Widget>[
      if (controller.workspaceJobs.isNotEmpty)
        showFullLabels
            ? OutlinedButton.icon(
                key: const Key('new-transcription'),
                onPressed: controller.canStartNewSession ? onNewSession : null,
                icon: const Icon(Icons.note_add_outlined),
                label: Text(context.strings.t('new_transcription')),
              )
            : IconButton.outlined(
                key: const Key('new-transcription'),
                onPressed: controller.canStartNewSession ? onNewSession : null,
                tooltip: context.strings.t('new_transcription'),
                icon: const Icon(Icons.note_add_outlined),
              ),
      if (isNewTranscription) ...[
        OutlinedButton.icon(
          key: const Key('header-add-folder'),
          onPressed: onAddFolder,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: Text(context.strings.t('add_folder')),
        ),
        OutlinedButton.icon(
          key: const Key('header-add-files'),
          onPressed: onAddFiles,
          icon: const Icon(Icons.add_rounded),
          label: Text(context.strings.t('add_files')),
        ),
      ],
      FilledButton.icon(
        onPressed:
            controller.readyCount > 0 &&
                controller.keyConfigured &&
                !controller.processing
            ? controller.startReady
            : null,
        icon: controller.processing
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.auto_awesome_rounded),
        label: Text(context.strings.t('transcribe')),
      ),
      if (controller.workspaceJobs.isNotEmpty)
        _ExportAllButton(controller: controller, compact: !showFullLabels),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: constraints.maxWidth >= 1180 ? 280 : 220,
            child: Text(
              context.strings.t('workspace'),
              key: const Key('workspace-page-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyDropZone extends StatelessWidget {
  const _EmptyDropZone({required this.dragging, required this.onAddFiles});

  final bool dragging;
  final VoidCallback onAddFiles;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 470),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onAddFiles,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: dragging
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
                width: dragging ? 2 : 1,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 400;
                return SingleChildScrollView(
                  padding: EdgeInsets.all(compact ? 24 : 48),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        dragging
                            ? Icons.file_download_rounded
                            : Icons.graphic_eq_rounded,
                        size: compact ? 56 : 78,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      SizedBox(height: compact ? 16 : 24),
                      Text(
                        context.strings.t('drop_title'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: compact ? 8 : 10),
                      Text(
                        context.strings.t('drop_subtitle'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.strings.t('supported'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SizedBox(height: compact ? 16 : 22),
                      FilledButton.icon(
                        key: const Key('empty-add-files'),
                        onPressed: onAddFiles,
                        icon: const Icon(Icons.add_rounded),
                        label: Text(context.strings.t('add_files')),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _startNewSession(
  BuildContext context,
  AppController controller,
) async {
  if (!controller.canStartNewSession) return;
  if (controller.untranscribedWorkspaceCount > 0) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.t('new_session_title')),
        content: Text(
          context.strings
              .t('new_session_body')
              .replaceFirst(
                '{count}',
                '${controller.untranscribedWorkspaceCount}',
              ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.t('start_new')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
  }
  await controller.startNewSession();
}

class _WorkspaceBody extends StatefulWidget {
  const _WorkspaceBody({required this.dragging});

  final bool dragging;

  @override
  State<_WorkspaceBody> createState() => _WorkspaceBodyState();
}

class _WorkspaceBodyState extends State<_WorkspaceBody> {
  static const _queueWidth = 300.0;
  static const _queueGap = 10.0;
  static const _queueAnimationDuration = Duration(milliseconds: 240);
  static const _queueAnimationCurve = Curves.easeInOutCubic;

  bool _queueExpanded = true;
  bool _autoCollapseApplied = false;
  bool _queueManuallyChanged = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reviewing =
        context.watch<AppController>().selectedJob?.document != null;
    if (reviewing && !_autoCollapseApplied && !_queueManuallyChanged) {
      _queueExpanded = false;
      _autoCollapseApplied = true;
    }
  }

  void _setQueueExpanded(bool expanded) {
    setState(() {
      _queueExpanded = expanded;
      _queueManuallyChanged = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    return LayoutBuilder(
      builder: (context, constraints) {
        final editor = controller.selectedJob?.document != null;
        final split = constraints.maxWidth > 760;
        final canCollapse = split && editor;
        if (canCollapse) {
          return Stack(
            key: const Key('workspace-review-layout'),
            clipBehavior: Clip.hardEdge,
            children: [
              AnimatedPositioned(
                key: const Key('file-queue-position'),
                duration: _queueAnimationDuration,
                curve: _queueAnimationCurve,
                left: _queueExpanded ? 0 : -(_queueWidth + _queueGap),
                top: 0,
                bottom: 0,
                width: _queueWidth,
                child: _QueueList(
                  dragging: widget.dragging,
                  onCollapse: () => _setQueueExpanded(false),
                ),
              ),
              AnimatedPositioned(
                key: const Key('review-pane-position'),
                duration: _queueAnimationDuration,
                curve: _queueAnimationCurve,
                left: _queueExpanded ? _queueWidth + _queueGap : 0,
                top: 0,
                right: 0,
                bottom: 0,
                child: TranscriptReview(jobId: controller.selectedJob!.id),
              ),
              Positioned(
                left: 16,
                bottom: 16,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  reverseDuration: const Duration(milliseconds: 140),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween(begin: .85, end: 1.0).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _queueExpanded
                      ? const SizedBox.shrink(
                          key: Key('file-queue-button-hidden'),
                        )
                      : _QueueFloatingButton(
                          onExpand: () => _setQueueExpanded(true),
                        ),
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: const Key('workspace-queue-pane'),
              width: split
                  ? editor
                        ? _queueWidth
                        : 400
                  : constraints.maxWidth,
              child: _QueueList(
                dragging: widget.dragging,
                onCollapse: canCollapse ? () => _setQueueExpanded(false) : null,
              ),
            ),
            if (split) ...[
              const SizedBox(width: 10),
              Expanded(
                key: const Key('workspace-detail-pane'),
                child: editor
                    ? TranscriptReview(jobId: controller.selectedJob!.id)
                    : const _BatchOptionsPanel(),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _BatchOptionsPanel extends StatefulWidget {
  const _BatchOptionsPanel();

  @override
  State<_BatchOptionsPanel> createState() => _BatchOptionsPanelState();
}

class _BatchOptionsPanelState extends State<_BatchOptionsPanel> {
  final _languages = TextEditingController();
  final _terms = TextEditingController();
  bool _seeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    final options = context.read<AppController>().sessionOptions;
    _languages.text = options.languageHints.join(', ');
    _terms.text = options.contextTerms.join(', ');
    _seeded = true;
  }

  @override
  void dispose() {
    _languages.dispose();
    _terms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final settings = controller.settings;
    return Card(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Icon(
                Icons.tune_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.strings.t('details'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ReviewLine(
            icon: controller.keyConfigured
                ? Icons.key_rounded
                : Icons.key_off_rounded,
            title: context.strings.t('soniox_key'),
            value: controller.keyConfigured
                ? context.strings.t('key_configured')
                : context.strings.t('key_missing'),
            action: controller.keyConfigured
                ? null
                : () => controller.setDestination(2),
          ),
          const Divider(height: 20),
          Text(
            context.strings.t('concurrency'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 10),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('1')),
              ButtonSegment(value: 2, label: Text('2')),
              ButtonSegment(value: 3, label: Text('3')),
              ButtonSegment(value: 4, label: Text('4')),
            ],
            selected: {settings.concurrency},
            onSelectionChanged: (value) => controller.updateSettings(
              settings.copyWith(concurrency: value.first),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('session-language-hints-field'),
            controller: _languages,
            decoration: InputDecoration(
              labelText: context.strings.t('language_hints'),
              hintText: context.strings.t('language_hints_hint'),
              prefixIcon: const Icon(Icons.translate_rounded),
            ),
            onSubmitted: (_) => _saveSessionOptions(controller),
            onTapOutside: (_) => _saveSessionOptions(controller),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('session-context-terms-field'),
            controller: _terms,
            decoration: InputDecoration(
              labelText: context.strings.t('context_terms'),
              hintText: context.strings.t('context_terms_hint'),
              prefixIcon: const Icon(Icons.spellcheck_rounded),
            ),
            onSubmitted: (_) => _saveSessionOptions(controller),
            onTapOutside: (_) => _saveSessionOptions(controller),
          ),
          const Divider(height: 20),
          _ReviewLine(
            icon: controller.translationConfigured
                ? Icons.translate_rounded
                : Icons.g_translate_outlined,
            title: context.strings.t('llm_translation'),
            value: controller.translationConfigured
                ? settings.translationSettings.model
                : context.strings.t('translation_not_configured'),
            action: controller.translationConfigured
                ? null
                : () => controller.setDestination(2),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: const Key('translation-target-language'),
            initialValue:
                supportedTranslationLanguageCodes.contains(
                  settings.translationSettings.targetLanguage,
                )
                ? settings.translationSettings.targetLanguage
                : 'en',
            decoration: InputDecoration(
              labelText: context.strings.t('target_language'),
              prefixIcon: const Icon(Icons.language_rounded),
            ),
            items: [
              for (final code in supportedTranslationLanguageCodes)
                DropdownMenuItem(
                  value: code,
                  child: Text(context.strings.translationLanguageName(code)),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              controller.updateTranslationDefaults(
                settings.translationSettings.copyWith(targetLanguage: value),
              );
            },
          ),
          SwitchListTile(
            key: const Key('auto-translate-switch'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(context.strings.t('auto_translate')),
            subtitle: controller.translationConfigured
                ? null
                : Text(context.strings.t('auto_translate_requires_config')),
            value: settings.translationSettings.autoTranslate,
            onChanged: controller.translationConfigured
                ? (value) => controller.updateTranslationDefaults(
                    settings.translationSettings.copyWith(autoTranslate: value),
                  )
                : null,
          ),
          const Divider(height: 20),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(context.strings.t('speaker_labels')),
            subtitle: Text(context.strings.t('diarization_reversible')),
            value: settings.showSpeakers,
            onChanged: (value) => controller.updateSettings(
              settings.copyWith(showSpeakers: value),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(context.strings.t('timestamps')),
            subtitle: Text(context.strings.t('subtitle_timing_kept')),
            value: settings.showTimestamps,
            onChanged: (value) => controller.updateSettings(
              settings.copyWith(showTimestamps: value),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveSessionOptions(AppController controller) =>
      controller.updateSessionOptions(
        TranscriptionOptions(
          languageHints: _split(_languages.text),
          contextTerms: _split(_terms.text),
        ),
      );

  List<String> _split(String value) => value
      .split(RegExp(r'[,\n]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList();
}

class _ReviewLine extends StatelessWidget {
  const _ReviewLine({
    required this.icon,
    required this.title,
    required this.value,
    this.action,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: action,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (action != null) const Icon(Icons.chevron_right_rounded),
        ],
      ),
    ),
  );
}

class _QueueList extends StatelessWidget {
  const _QueueList({required this.dragging, this.onCollapse});

  final bool dragging;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const Key('file-queue-panel'),
      color: dragging ? colors.primaryContainer.withValues(alpha: .45) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: dragging
            ? BorderSide(color: colors.primary, width: 2)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              buildDefaultDragHandles: false,
              itemCount: controller.workspaceJobs.length,
              onReorderItem: controller.reorderWorkspace,
              itemBuilder: (context, index) {
                final job = controller.workspaceJobs[index];
                return _JobTile(
                  key: ValueKey(job.id),
                  job: job,
                  selected: controller.selectedJobId == job.id,
                  index: index,
                );
              },
            ),
          ),
          const Divider(height: 1),
          Row(
            key: const Key('file-queue-status-summary'),
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 8),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _QueueStat(
                          key: const Key('queue-ready-status'),
                          value: controller.readyCount,
                          label: context.strings.t('ready'),
                        ),
                        const SizedBox(width: 16),
                        _QueueStat(
                          key: const Key('queue-completed-status'),
                          value: controller.completedCount,
                          label: context.strings.t('completed'),
                        ),
                        const SizedBox(width: 16),
                        _QueueStat(
                          key: const Key('queue-failed-status'),
                          value: controller.failedCount,
                          label: context.strings.t('failed'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (onCollapse != null)
                IconButton(
                  key: const Key('collapse-file-queue'),
                  tooltip: context.strings.t('collapse_file_queue'),
                  onPressed: onCollapse,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QueueStat extends StatelessWidget {
  const _QueueStat({super.key, required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label: $value',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _QueueFloatingButton extends StatelessWidget {
  const _QueueFloatingButton({required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final colors = Theme.of(context).colorScheme;
    return Badge.count(
      key: const Key('file-queue-floating-button'),
      count: controller.workspaceJobs.length,
      backgroundColor: colors.primary,
      textColor: colors.onPrimary,
      child: FloatingActionButton.small(
        key: const Key('expand-file-queue'),
        heroTag: null,
        tooltip: context.strings.t('expand_file_queue'),
        onPressed: onExpand,
        backgroundColor: colors.surfaceContainerHigh,
        foregroundColor: colors.onSurface,
        child: const Icon(Icons.view_list_rounded),
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({
    super.key,
    required this.job,
    required this.selected,
    required this.index,
  });

  final TranscriptionJob job;
  final bool selected;
  final int index;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final color = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? color.secondaryContainer.withValues(alpha: .55)
          : Colors.transparent,
      child: InkWell(
        onTap: () => controller.selectJob(job.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.drag_indicator, size: 20),
                ),
              ),
              _StatusIcon(status: job.status),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _jobSubtitle(context, job),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: job.status == JobStatus.failed
                            ? color.error
                            : color.onSurfaceVariant,
                      ),
                    ),
                    if (job.status.isActive) ...[
                      const SizedBox(height: 5),
                      LinearProgressIndicator(
                        value: job.progress.fraction,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ],
                    if (job.translationState.status.isActive) ...[
                      const SizedBox(height: 5),
                      LinearProgressIndicator(
                        value: job.translationState.progress,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ],
                  ],
                ),
              ),
              _JobMenu(job: job),
            ],
          ),
        ),
      ),
    );
  }

  String _jobSubtitle(BuildContext context, TranscriptionJob job) {
    if (job.errorCode != null || job.errorMessage != null) {
      return context.strings.error(
        job.errorCode,
        englishFallback: job.errorMessage,
      );
    }
    final duration = job.metadata == null
        ? ''
        : formatClock(job.metadata!.durationMs);
    return '${context.strings.t('job_${job.status.name}')} $duration'.trim();
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});
  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final (icon, tint) = switch (status) {
      JobStatus.completed => (Icons.check_circle_rounded, Colors.green),
      JobStatus.failed ||
      JobStatus.missingSource => (Icons.error_rounded, color.error),
      JobStatus.cancelled => (Icons.cancel_rounded, color.outline),
      JobStatus.ready => (Icons.schedule_rounded, color.primary),
      JobStatus.paused => (Icons.pause_circle_filled_rounded, color.tertiary),
      JobStatus.empty => (Icons.comments_disabled_rounded, color.outline),
      _ => (Icons.graphic_eq_rounded, color.primary),
    };
    return Icon(icon, color: tint, size: 25);
  }
}

enum _JobAction { retry, cancel, relink, export, remove }

class _JobMenu extends StatelessWidget {
  const _JobMenu({required this.job});
  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) => PopupMenuButton<_JobAction>(
    tooltip: context.strings.t('more_actions'),
    onSelected: (action) => _handle(context, action),
    itemBuilder: (context) => [
      if (job.status.canRetry)
        PopupMenuItem(
          value: _JobAction.retry,
          child: Text(context.strings.t('retry')),
        ),
      if (job.isBusy)
        PopupMenuItem(
          value: _JobAction.cancel,
          child: Text(context.strings.t('cancel')),
        ),
      if (job.status == JobStatus.missingSource)
        PopupMenuItem(
          value: _JobAction.relink,
          child: Text(context.strings.t('relink')),
        ),
      if (job.document != null)
        PopupMenuItem(
          value: _JobAction.export,
          child: Text(context.strings.t('export')),
        ),
      if (!job.isBusy)
        PopupMenuItem(
          value: _JobAction.remove,
          child: Text(context.strings.t('remove')),
        ),
    ],
  );

  Future<void> _handle(BuildContext context, _JobAction action) async {
    final controller = context.read<AppController>();
    switch (action) {
      case _JobAction.retry:
        await controller.retry(job.id);
        return;
      case _JobAction.cancel:
        await controller.cancelJob(job.id);
        return;
      case _JobAction.relink:
        await chooseAndRelink(context, job.id);
        return;
      case _JobAction.export:
        await showExportDialog(context, jobId: job.id);
        return;
      case _JobAction.remove:
        await controller.removeFromWorkspace(job.id);
        return;
    }
  }
}

Future<bool> chooseAndRelink(BuildContext context, String jobId) async {
  final file = await openFile();
  if (file == null || !context.mounted) return false;
  final errorCode = await context.read<AppController>().relink(
    jobId,
    file.path,
  );
  if (!context.mounted) return errorCode == null;
  if (errorCode != null) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.strings.error(errorCode))));
    return false;
  }
  return true;
}

class _ExportAllButton extends StatelessWidget {
  const _ExportAllButton({required this.controller, required this.compact});
  final AppController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final onPressed = controller.completedCount == 0
        ? null
        : () => showExportDialog(context);
    if (compact) {
      return IconButton.outlined(
        key: const Key('export-all'),
        tooltip: context.strings.t('export_all'),
        onPressed: onPressed,
        icon: const Icon(Icons.ios_share_rounded),
      );
    }
    return OutlinedButton.icon(
      key: const Key('export-all'),
      onPressed: onPressed,
      icon: const Icon(Icons.ios_share_rounded),
      label: Text(context.strings.t('export_all')),
    );
  }
}

Future<void> showExportDialog(BuildContext context, {String? jobId}) async {
  final controller = context.read<AppController>();
  var options = controller.settings.exportOptions.copyWith(
    localeCode: Localizations.localeOf(context).languageCode,
  );
  var zip = false;
  final selected = await showDialog<({ExportOptions options, bool zip})>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(context.strings.t('export')),
        content: SizedBox(
          width: 410,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<ExportFormat>(
                initialValue: options.format,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.description_outlined),
                ),
                items: [
                  DropdownMenuItem(
                    value: ExportFormat.txt,
                    child: Text(context.strings.t('plain_text')),
                  ),
                  DropdownMenuItem(
                    value: ExportFormat.markdown,
                    child: Text(context.strings.t('markdown')),
                  ),
                  DropdownMenuItem(
                    value: ExportFormat.srt,
                    child: Text(context.strings.t('srt')),
                  ),
                  DropdownMenuItem(
                    value: ExportFormat.webVtt,
                    child: Text(context.strings.t('vtt')),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => options = options.copyWith(format: value)),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ExportContentMode>(
                key: const Key('export-content-mode'),
                initialValue: options.contentMode,
                decoration: InputDecoration(
                  labelText: context.strings.t('export_content'),
                  prefixIcon: const Icon(Icons.translate_rounded),
                ),
                items: [
                  DropdownMenuItem(
                    value: ExportContentMode.original,
                    child: Text(context.strings.t('original')),
                  ),
                  DropdownMenuItem(
                    value: ExportContentMode.translated,
                    child: Text(context.strings.t('translated')),
                  ),
                  DropdownMenuItem(
                    value: ExportContentMode.bilingual,
                    child: Text(context.strings.t('bilingual')),
                  ),
                ],
                onChanged: (value) => setState(
                  () => options = options.copyWith(contentMode: value),
                ),
              ),
              if (options.contentMode != ExportContentMode.original &&
                  _hasIncompleteTranslations(controller, jobId))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.strings.t('partial_export_warning'),
                        ),
                      ),
                    ],
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.strings.t('speaker_labels')),
                value: options.showSpeakers,
                onChanged: (value) => setState(
                  () => options = options.copyWith(showSpeakers: value),
                ),
              ),
              if (jobId == null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.strings.t('batch_zip')),
                  value: zip,
                  onChanged: (value) => setState(() => zip = value),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.strings.t('timestamps')),
                subtitle:
                    options.format == ExportFormat.srt ||
                        options.format == ExportFormat.webVtt
                    ? Text(context.strings.t('subtitle_timing_required'))
                    : null,
                value:
                    options.format == ExportFormat.srt ||
                        options.format == ExportFormat.webVtt
                    ? true
                    : options.showTimestamps,
                onChanged:
                    options.format == ExportFormat.srt ||
                        options.format == ExportFormat.webVtt
                    ? null
                    : (value) => setState(
                        () => options = options.copyWith(showTimestamps: value),
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, (options: options, zip: zip)),
            child: Text(context.strings.t('export')),
          ),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  if (selected.zip) {
    final destination = await getSaveLocation(
      suggestedName: 'MeowSTT-transcripts.zip',
      acceptedTypeGroups: [
        XTypeGroup(
          label: context.strings.t('zip_archive'),
          extensions: const ['zip'],
        ),
      ],
    );
    if (destination == null || !context.mounted) return;
    await controller.exportCompletedZip(destination.path, selected.options);
  } else {
    final directory = await getDirectoryPath(
      confirmButtonText: context.strings.t('export'),
    );
    if (directory == null || !context.mounted) return;
    if (jobId != null) {
      await controller.exportJob(jobId, directory, selected.options);
    } else {
      await controller.exportCompleted(directory, selected.options);
    }
  }
  await controller.updateSettings(
    controller.settings.copyWith(exportOptions: selected.options),
  );
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.strings.t('exported'))));
  }
}

bool _hasIncompleteTranslations(AppController controller, String? jobId) {
  final jobs = jobId == null
      ? controller.workspaceJobs.where((job) => job.document != null)
      : controller.allJobs.where((job) => job.id == jobId);
  return jobs.any(
    (job) =>
        job.document?.segments.any((segment) => !segment.hasTranslation) ??
        false,
  );
}
