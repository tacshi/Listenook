import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../data/transcript_exporter.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'job_actions.dart';
import 'inbox_monitor_setup_dialog.dart';
import 'subtitle_import_review_dialog.dart';
import 'transcript_export_dialog.dart';

double? inboxJobProgressValue(TranscriptionJob job) {
  final fraction = job.progress.fraction;
  if (job.transcriptionProvider == TranscriptionProvider.mossLocal &&
      job.progress.stage == 'local_transcribing' &&
      (fraction == null || fraction <= 0.12)) {
    return null;
  }
  return fraction;
}

String? inboxJobProgressPercentage(TranscriptionJob job) {
  if (!job.status.isActive ||
      (job.transcriptionProvider != TranscriptionProvider.mossLocal &&
          job.transcriptionProvider != TranscriptionProvider.qwen3Local) ||
      job.progress.stage != 'local_transcribing' ||
      job.progress.fraction == null) {
    return null;
  }
  return '${(job.progress.fraction! * 100).clamp(0, 100).floor()}%';
}

class InboxPage extends StatefulWidget {
  const InboxPage({
    super.key,
    required this.onAddFiles,
    required this.onImportFolder,
  });

  final VoidCallback onAddFiles;
  final VoidCallback onImportFolder;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  bool _dragging = false;

  Future<void> _beginNewSession(AppController controller) async {
    await _startNewSession(context, controller);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        unawaited(
          reviewAndEnqueueSources(
            context,
            details.files.map((file) => file.path),
          ),
        );
      },
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _InboxMonitorPanel(),
              const SizedBox(height: 12),
              if (controller.inboxJobs.isNotEmpty) ...[
                _InboxActions(
                  onAddFiles: widget.onAddFiles,
                  onImportFolder: widget.onImportFolder,
                  onNewSession: () => _beginNewSession(controller),
                ),
                const SizedBox(height: 12),
              ],
              if (controller.inboxJobs.isEmpty)
                Expanded(
                  child: _EmptyDropZone(
                    dragging: _dragging,
                    onAddFiles: widget.onAddFiles,
                    onImportFolder: widget.onImportFolder,
                  ),
                )
              else
                Expanded(child: _InboxBody(dragging: _dragging)),
            ],
          ),
        ),
      ),
    );
  }
}

class _InboxMonitorPanel extends StatelessWidget {
  const _InboxMonitorPanel();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    if (!controller.inboxMonitorConfigured) {
      final colors = Theme.of(context).colorScheme;
      return Container(
        key: const Key('inbox-monitor-setup-card'),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            children: [
              Icon(
                Icons.folder_copy_outlined,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.strings.t('inbox_monitor_inline_hint'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                key: const Key('inbox-monitor-choose-folder'),
                onPressed: () => showInboxMonitorSetupDialog(context),
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: Text(context.strings.t('inbox_monitor_setup_action')),
              ),
            ],
          ),
        ),
      );
    }

    final config = controller.inboxMonitorConfig;
    final statusKey = switch (controller.inboxMonitorStatus) {
      InboxMonitorStatus.scanning => 'inbox_monitor_scanning',
      InboxMonitorStatus.paused => 'inbox_monitor_paused',
      InboxMonitorStatus.unavailable => 'inbox_monitor_unavailable',
      InboxMonitorStatus.error => 'inbox_monitor_error',
      _ => 'inbox_monitor_active',
    };
    final statusColor = switch (controller.inboxMonitorStatus) {
      InboxMonitorStatus.unavailable ||
      InboxMonitorStatus.error => Theme.of(context).colorScheme.error,
      InboxMonitorStatus.paused => Theme.of(context).colorScheme.tertiary,
      _ => Colors.green,
    };
    final folder = config.folderPath.replaceAll('\\', '/').split('/').last;
    final summary = context.strings
        .t('inbox_monitor_status_summary')
        .replaceFirst('{folder}', folder)
        .replaceFirst('{types}', '${config.extensions.length}')
        .replaceFirst('{count}', '${controller.monitoredWaitingCount}');
    return Card(
      key: const Key('inbox-monitor-status-card'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.circle, size: 11, color: statusColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.strings.t(statusKey),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              key: const Key('inbox-monitor-rescan'),
              tooltip: context.strings.t('inbox_monitor_rescan'),
              onPressed: config.paused ? null : controller.rescanInboxMonitor,
              icon: const Icon(Icons.refresh_rounded),
            ),
            TextButton.icon(
              key: const Key('inbox-monitor-pause-resume'),
              onPressed: () => controller.setInboxMonitorPaused(!config.paused),
              icon: Icon(
                config.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              ),
              label: Text(
                context.strings.t(
                  config.paused
                      ? 'inbox_monitor_resume'
                      : 'inbox_monitor_pause',
                ),
              ),
            ),
            TextButton(
              key: const Key('inbox-monitor-change'),
              onPressed: () => showInboxMonitorSetupDialog(context),
              child: Text(context.strings.t('inbox_monitor_change')),
            ),
            IconButton(
              key: const Key('inbox-monitor-remove-folder'),
              tooltip: context.strings.t('inbox_monitor_remove_folder'),
              onPressed: controller.clearInboxMonitor,
              icon: const Icon(Icons.folder_off_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

class _InboxActions extends StatelessWidget {
  const _InboxActions({
    required this.onAddFiles,
    required this.onImportFolder,
    required this.onNewSession,
  });
  final VoidCallback onAddFiles;
  final VoidCallback onImportFolder;
  final VoidCallback onNewSession;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final showFullLabels = MediaQuery.sizeOf(context).width >= 1180;
    final actions = <Widget>[
      if (controller.inboxJobs.isNotEmpty) ...[
        showFullLabels
            ? OutlinedButton.icon(
                key: const Key('new-inbox-batch'),
                onPressed: controller.canStartNewInboxBatch
                    ? onNewSession
                    : null,
                icon: const Icon(Icons.note_add_outlined),
                label: Text(context.strings.t('new_batch')),
              )
            : IconButton.outlined(
                key: const Key('new-inbox-batch'),
                onPressed: controller.canStartNewInboxBatch
                    ? onNewSession
                    : null,
                tooltip: context.strings.t('new_batch'),
                icon: const Icon(Icons.note_add_outlined),
              ),
        OutlinedButton.icon(
          key: const Key('header-import-folder'),
          onPressed: onImportFolder,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: Text(context.strings.t('import_folder')),
        ),
        OutlinedButton.icon(
          key: const Key('header-add-files'),
          onPressed: onAddFiles,
          icon: const Icon(Icons.add_rounded),
          label: Text(context.strings.t('add_media_subtitles')),
        ),
        FilledButton.icon(
          key: const Key('header-transcribe'),
          onPressed: controller.canStartReady ? controller.startReady : null,
          icon: controller.processing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome_rounded),
          label: Text(context.strings.t('transcribe')),
        ),
        if (controller.completedCount >= 2)
          _ExportCompletedButton(
            controller: controller,
            compact: !showFullLabels,
          ),
      ],
    ];
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: actions,
      ),
    );
  }
}

class _EmptyDropZone extends StatelessWidget {
  const _EmptyDropZone({
    required this.dragging,
    required this.onAddFiles,
    required this.onImportFolder,
  });

  final bool dragging;
  final VoidCallback onAddFiles;
  final VoidCallback onImportFolder;

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
                      SizedBox(height: compact ? 8 : 12),
                      Text(
                        context.strings.t('supported'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SizedBox(height: compact ? 16 : 22),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            key: const Key('empty-add-files'),
                            onPressed: onAddFiles,
                            icon: const Icon(Icons.add_rounded),
                            label: Text(
                              context.strings.t('add_media_subtitles'),
                            ),
                          ),
                          OutlinedButton.icon(
                            key: const Key('empty-import-folder'),
                            onPressed: onImportFolder,
                            icon: const Icon(Icons.create_new_folder_outlined),
                            label: Text(context.strings.t('import_folder')),
                          ),
                        ],
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
  if (!controller.canStartNewInboxBatch) return;
  if (controller.untranscribedInboxCount > 0) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.t('new_session_title')),
        content: Text(
          context.strings
              .t('new_session_body')
              .replaceFirst('{count}', '${controller.untranscribedInboxCount}'),
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
  await controller.startNewInboxBatch();
}

class _InboxBody extends StatelessWidget {
  const _InboxBody({required this.dragging});

  final bool dragging;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final split = constraints.maxWidth > 760;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const Key('inbox-queue-pane'),
            width: split ? 400 : constraints.maxWidth,
            child: _QueueList(dragging: dragging),
          ),
          if (split) ...[
            const SizedBox(width: 10),
            const Expanded(
              key: Key('inbox-detail-pane'),
              child: _BatchOptionsPanel(),
            ),
          ],
        ],
      );
    },
  );
}

class _BatchOptionsPanel extends StatefulWidget {
  const _BatchOptionsPanel();

  @override
  State<_BatchOptionsPanel> createState() => _BatchOptionsPanelState();
}

class _BatchOptionsPanelState extends State<_BatchOptionsPanel> {
  final _terms = TextEditingController();
  bool _seeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    final options = context.read<AppController>().sessionOptions;
    _terms.text = options.contextTerms.join(', ');
    _seeded = true;
  }

  @override
  void dispose() {
    _terms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final settings = controller.settings;
    final provider = controller.sessionTranscriptionProvider;
    final providerConfigured = controller.isTranscriptionProviderConfigured(
      provider,
    );
    final hasTranscriptionJobs = controller.inboxJobs.any(
      (job) =>
          job.transcriptAcquisitionMode !=
          TranscriptAcquisitionMode.importedSubtitles,
    );
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
          if (hasTranscriptionJobs) ...[
            DropdownButtonFormField<TranscriptionProvider>(
              key: const Key('session-transcription-provider'),
              initialValue: provider,
              decoration: InputDecoration(
                labelText: context.strings.t('transcription_provider'),
                prefixIcon: const Icon(Icons.hub_outlined),
              ),
              items: [
                for (final item in controller.availableTranscriptionProviders)
                  DropdownMenuItem(
                    value: item,
                    child: Text(
                      context.strings.transcriptionProviderName(item),
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  controller.updateSessionTranscriptionProvider(value);
                }
              },
            ),
            if (!providerConfigured) ...[
              const SizedBox(height: 12),
              _ReviewLine(
                icon: Icons.key_off_rounded,
                title: provider == TranscriptionProvider.soniox
                    ? context.strings.t('soniox_key')
                    : provider == TranscriptionProvider.mossPro
                    ? context.strings.t('moss_key')
                    : context.strings.t(
                        provider == TranscriptionProvider.qwen3Local
                            ? 'local_qwen_model'
                            : 'local_moss_model',
                      ),
                value: context.strings.t(
                  provider == TranscriptionProvider.qwen3Local
                      ? 'local_qwen_model_missing'
                      : provider == TranscriptionProvider.mossLocal
                      ? 'local_model_missing'
                      : 'provider_key_missing',
                ),
                action: () =>
                    controller.setDestination(AppDestination.settings),
              ),
              const Divider(height: 20),
            ] else
              const SizedBox(height: 12),
            if (provider != TranscriptionProvider.mossPro) ...[
              _LanguageHintsPicker(
                selectedCodes: controller.sessionOptions.languageHints,
                onChanged: (languageHints) => controller.updateSessionOptions(
                  controller.sessionOptions.copyWith(
                    languageHints: languageHints,
                  ),
                ),
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
            ] else
              _ReviewLine(
                icon: Icons.auto_awesome_outlined,
                title: context.strings.t('moss_pro'),
                value: context.strings.t('moss_options_automatic'),
              ),
            const Divider(height: 20),
          ],
          if (hasTranscriptionJobs &&
              provider == TranscriptionProvider.soniox &&
              settings.sonioxTranslation.enabled)
            KeyedSubtree(
              key: const Key('soniox-translation-summary'),
              child: _ReviewLine(
                icon: Icons.translate_rounded,
                title: context.strings.t('soniox_translation'),
                value: context.strings.translationLanguageName(
                  settings.sonioxTranslation.targetLanguage,
                ),
                action: () =>
                    controller.setDestination(AppDestination.settings),
              ),
            )
          else ...[
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
                  : () => controller.setDestination(AppDestination.settings),
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
                      settings.translationSettings.copyWith(
                        autoTranslate: value,
                      ),
                    )
                  : null,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _saveSessionOptions(AppController controller) =>
      controller.updateSessionOptions(
        controller.sessionOptions.copyWith(contextTerms: _split(_terms.text)),
      );

  List<String> _split(String value) => value
      .split(RegExp(r'[,\n]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList();
}

class _LanguageHintsPicker extends StatefulWidget {
  const _LanguageHintsPicker({
    required this.selectedCodes,
    required this.onChanged,
  });

  final List<String> selectedCodes;
  final Future<void> Function(List<String> languageHints) onChanged;

  @override
  State<_LanguageHintsPicker> createState() => _LanguageHintsPickerState();
}

class _LanguageHintsPickerState extends State<_LanguageHintsPicker> {
  late List<String> _selectedCodes;
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    _selectedCodes = [...widget.selectedCodes];
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedCodes.toSet();
    final summary = _selectedCodes.isEmpty
        ? context.strings.t('automatic')
        : _selectedCodes
              .map(context.strings.translationLanguageName)
              .join(', ');

    return MenuAnchor(
      key: const Key('session-language-hints-menu'),
      style: const MenuStyle(
        minimumSize: WidgetStatePropertyAll(Size(300, 0)),
        maximumSize: WidgetStatePropertyAll(Size(360, 400)),
      ),
      onOpen: () => setState(() => _menuOpen = true),
      onClose: () => setState(() => _menuOpen = false),
      menuChildren: [
        MenuItemButton(
          key: const Key('language-hints-automatic'),
          closeOnActivate: false,
          leadingIcon: Icon(
            _selectedCodes.isEmpty ? Icons.check_rounded : null,
          ),
          onPressed: _clear,
          child: Text(context.strings.t('automatic')),
        ),
        const Divider(height: 1),
        for (final code in supportedSonioxTranslationLanguageCodes)
          MenuItemButton(
            key: ValueKey('language-hint-$code'),
            closeOnActivate: false,
            leadingIcon: Checkbox(
              value: selected.contains(code),
              visualDensity: VisualDensity.compact,
              onChanged: (_) => _toggle(code),
            ),
            onPressed: () => _toggle(code),
            child: Text(
              '${context.strings.translationLanguageName(code)}  ·  $code',
            ),
          ),
      ],
      builder: (context, menuController, child) => InkWell(
        key: const Key('session-language-hints-picker'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => menuController.isOpen
            ? menuController.close()
            : menuController.open(),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: context.strings.t('language_hints'),
            prefixIcon: const Icon(Icons.translate_rounded),
            suffixIcon: Icon(
              _menuOpen
                  ? Icons.arrow_drop_up_rounded
                  : Icons.arrow_drop_down_rounded,
            ),
          ),
          child: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }

  Future<void> _toggle(String code) async {
    setState(() {
      if (!_selectedCodes.remove(code)) {
        _selectedCodes.add(code);
      }
    });
    await _save();
  }

  Future<void> _clear() async {
    if (_selectedCodes.isEmpty) return;
    setState(_selectedCodes.clear);
    await _save();
  }

  Future<void> _save() => widget.onChanged([..._selectedCodes]);
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
  const _QueueList({required this.dragging});

  final bool dragging;

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
              itemCount: controller.inboxJobs.length,
              onReorderItem: controller.reorderInbox,
              itemBuilder: (context, index) {
                final job = controller.inboxJobs[index];
                return _JobTile(key: ValueKey(job.id), job: job, index: index);
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
                          key: const Key('queue-processing-status'),
                          value: controller.processingCount,
                          label: context.strings.t('processing'),
                        ),
                        const SizedBox(width: 16),
                        _QueueStat(
                          key: const Key('queue-completed-status'),
                          value: controller.completedCount,
                          label: context.strings.t('completed'),
                        ),
                        if (controller.failedCount > 0) ...[
                          const SizedBox(width: 16),
                          _QueueStat(
                            key: const Key('queue-failed-status'),
                            value: controller.failedCount,
                            label: context.strings.t('failed'),
                            color: colors.error,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QueueStat extends StatelessWidget {
  const _QueueStat({
    super.key,
    required this.value,
    required this.label,
    this.color,
  });

  final int value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label: $value',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    ),
  );
}

class _JobTile extends StatelessWidget {
  const _JobTile({super.key, required this.job, required this.index});

  final TranscriptionJob job;
  final int index;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
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
            _StatusIcon(job: job),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          job.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (job.sourceOrigin == JobSourceOrigin.podcast) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: context.strings.t('podcast_source'),
                          child: Icon(
                            Icons.podcasts_rounded,
                            key: ValueKey('podcast-source-${job.id}'),
                            size: 16,
                            color: color.primary,
                          ),
                        ),
                      ],
                      if (job.sourceOrigin ==
                          JobSourceOrigin.monitoredFolder) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: context.strings.t('inbox_monitor_source'),
                          child: Icon(
                            Icons.folder_special_outlined,
                            key: ValueKey('monitored-source-${job.id}'),
                            size: 16,
                            color: color.primary,
                          ),
                        ),
                      ],
                    ],
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
                  if (_canOfferPublisherCaptions(job)) ...[
                    const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: ValueKey('podcast-caption-mode-${job.id}'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => context
                            .read<AppController>()
                            .setTranscriptAcquisitionMode(
                              job.id,
                              job.transcriptAcquisitionMode ==
                                      TranscriptAcquisitionMode
                                          .publisherCaptions
                                  ? (job.transcriptionProvider ==
                                            TranscriptionProvider.mossPro
                                        ? TranscriptAcquisitionMode.mossPro
                                        : TranscriptAcquisitionMode.soniox)
                                  : TranscriptAcquisitionMode.publisherCaptions,
                            ),
                        child: Text(
                          job.transcriptAcquisitionMode ==
                                  TranscriptAcquisitionMode.publisherCaptions
                              ? context.strings
                                    .t('podcast_use_provider')
                                    .replaceFirst(
                                      '{provider}',
                                      context.strings.transcriptionProviderName(
                                        job.transcriptionProvider,
                                      ),
                                    )
                              : context.strings.t('podcast_use_captions'),
                        ),
                      ),
                    ),
                  ],
                  if (job.status.isActive) ...[
                    const SizedBox(height: 5),
                    LinearProgressIndicator(
                      value: inboxJobProgressValue(job),
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
            if (job.document != null) ...[
              IconButton(
                key: ValueKey('open-inbox-job-${job.id}'),
                tooltip: context.strings.t('open'),
                onPressed: () =>
                    context.read<AppController>().openInWorkspace(job.id),
                icon: const Icon(Icons.open_in_new_rounded),
              ),
              IconButton(
                key: ValueKey('export-inbox-job-${job.id}'),
                tooltip: context.strings.t('export'),
                onPressed: () =>
                    showTranscriptExportDialog(context, jobIds: [job.id]),
                icon: const Icon(Icons.ios_share_rounded),
              ),
            ],
            _JobMenu(job: job),
          ],
        ),
      ),
    );
  }

  String _jobSubtitle(BuildContext context, TranscriptionJob job) {
    if (job.errorCode != null || job.errorMessage != null) {
      if (job.errorCode == null || job.errorCode == 'unexpected') {
        return context.strings.t('error_transcription_unknown');
      }
      return context.strings.error(
        job.errorCode,
        englishFallback: job.errorMessage,
      );
    }
    final duration = job.metadata == null
        ? ''
        : formatClock(job.metadata!.durationMs);
    final transcript = switch (job.transcriptAcquisitionMode) {
      TranscriptAcquisitionMode.publisherCaptions => context.strings.t(
        'podcast_captions_selected',
      ),
      TranscriptAcquisitionMode.soniox
          when job.podcastProvenance?.transcriptTiming !=
                  PodcastTranscriptTiming.none &&
              job.podcastProvenance?.transcriptTiming != null =>
        context.strings.t('podcast_has_captions'),
      _ => '',
    };
    final progress = inboxJobProgressPercentage(job) ?? '';
    return [
      context.strings.t('job_${job.status.name}'),
      progress,
      duration,
      transcript,
    ].where((part) => part.trim().isNotEmpty).join(' · ');
  }
}

bool _canOfferPublisherCaptions(TranscriptionJob job) {
  if (job.sourceOrigin != JobSourceOrigin.podcast) return false;
  if (!job.status.canTranscribe &&
      job.status != JobStatus.failed &&
      job.status != JobStatus.cancelled) {
    return false;
  }
  final provenance = job.podcastProvenance;
  if (provenance == null) return false;
  return provenance.transcripts.isNotEmpty ||
      provenance.transcriptTiming != PodcastTranscriptTiming.none;
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.job});
  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final (icon, tint) = switch (job.status) {
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

enum _JobAction { retry, replaceSubtitle, cancel, relink, remove }

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
      if (job.transcriptAcquisitionMode ==
              TranscriptAcquisitionMode.importedSubtitles &&
          !job.isBusy)
        PopupMenuItem(
          value: _JobAction.replaceSubtitle,
          child: Text(context.strings.t('replace_subtitle')),
        ),
      if (job.isBusy)
        PopupMenuItem(
          value: _JobAction.cancel,
          child: Text(context.strings.t('cancel')),
        ),
      if (job.status == JobStatus.missingSource &&
          job.sourceOrigin != JobSourceOrigin.podcast)
        PopupMenuItem(
          value: _JobAction.relink,
          child: Text(context.strings.t('relink')),
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
      case _JobAction.replaceSubtitle:
        await chooseAndReplaceSubtitle(context, job);
        return;
      case _JobAction.cancel:
        await controller.cancelJob(job.id);
        return;
      case _JobAction.relink:
        await chooseAndRelink(context, job.id);
        return;
      case _JobAction.remove:
        await controller.removeFromInbox(job.id);
        return;
    }
  }
}

class _ExportCompletedButton extends StatelessWidget {
  const _ExportCompletedButton({
    required this.controller,
    required this.compact,
  });

  final AppController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final completedIds = controller.inboxJobs
        .where((job) => job.document != null)
        .map((job) => job.id)
        .toList(growable: false);
    final label = context.strings
        .t('export_completed_count')
        .replaceFirst('{count}', '${completedIds.length}');
    void onPressed() =>
        showTranscriptExportDialog(context, jobIds: completedIds);
    if (compact) {
      return IconButton.outlined(
        key: const Key('export-inbox-completed'),
        tooltip: label,
        onPressed: onPressed,
        icon: const Icon(Icons.ios_share_rounded),
      );
    }
    return OutlinedButton.icon(
      key: const Key('export-inbox-completed'),
      onPressed: onPressed,
      icon: const Icon(Icons.ios_share_rounded),
      label: Text(label),
    );
  }
}
