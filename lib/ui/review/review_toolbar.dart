import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../../state/app_controller.dart';
import '../app_notice.dart';
import '../transcript_export_dialog.dart';
import '../keyboard_shortcuts.dart';
import '../transcript_review.dart';
import 'ai_brief_pane.dart';
import 'listening_widgets.dart';
import 'review_scaffold.dart';
import 'transcript_segments.dart';

enum _TranscriptMoreAction {
  toggleMimic,
  toggleBlindListening,
  toggleStructure,
  toggleSpeakers,
  toggleTimestamps,
  original,
  translated,
  bilingual,
  addBackToInbox,
  retryAlignment,
  translate,
  copy,
  export,
}

enum ReviewToolbarRole { global, transcript, aiBrief }

class UnifiedReviewToolbar extends StatelessWidget {
  const UnifiedReviewToolbar({
    super.key,
    required this.role,
    required this.job,
    required this.viewMode,
    required this.showAiBrief,
    required this.search,
    required this.searchVisible,
    required this.onTabChanged,
    required this.onViewModeChanged,
    required this.onOpenSearch,
    required this.onCloseSearch,
    required this.onSearch,
    required this.onFocusCurrentSentence,
    required this.onGenerateAiBrief,
    this.blindListening = false,
    this.sentenceRevealed = false,
    this.onReveal,
    this.onToggleBlindListening,
    this.dictationOpen = false,
    this.onToggleDictation,
    this.mimicOpen = false,
    this.onToggleMimic,
    this.showFilename = true,
    this.structureMode = false,
    this.structureEnabled = false,
    this.onToggleStructure,
    this.onUndoStructure,
    this.onRedoStructure,
  });

  static const _fullBreakpoint = 900.0;
  static const _mediumBreakpoint = 700.0;
  static const _paneFullBreakpoint = 700.0;
  static const _paneMediumBreakpoint = 520.0;
  static const _paneDirectActionsBreakpoint = 400.0;

  final bool blindListening;
  final bool sentenceRevealed;
  final VoidCallback? onReveal;
  final VoidCallback? onToggleBlindListening;
  final bool dictationOpen;
  final VoidCallback? onToggleDictation;
  final bool mimicOpen;
  final VoidCallback? onToggleMimic;
  final ReviewToolbarRole role;
  final TranscriptionJob job;
  final TranslationViewMode viewMode;
  final bool showAiBrief;
  final TextEditingController search;
  final bool searchVisible;
  final ValueChanged<bool> onTabChanged;
  final ValueChanged<TranslationViewMode> onViewModeChanged;
  final VoidCallback onOpenSearch;
  final VoidCallback onCloseSearch;
  final VoidCallback onSearch;
  final VoidCallback? onFocusCurrentSentence;
  final VoidCallback onGenerateAiBrief;
  final bool showFilename;
  final bool structureMode;
  final bool structureEnabled;
  final VoidCallback? onToggleStructure;

  /// Structure edits can be undone with ⌘Z / Ctrl+Z; these buttons are for
  /// touch. Null when there is nothing to undo or redo.
  final VoidCallback? onUndoStructure;
  final VoidCallback? onRedoStructure;

  bool get _translationStarted =>
      job.translationState.status != TranslationStatus.idle ||
      (job.document?.segments.any((segment) => segment.hasTranslation) ??
          false);

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    return switch (role) {
      ReviewToolbarRole.global => _buildGlobalHeader(context),
      ReviewToolbarRole.transcript => _buildTranscriptPaneHeader(
        context,
        controller,
      ),
      ReviewToolbarRole.aiBrief => _buildAiBriefPaneHeader(context, controller),
    };
  }

  Widget _buildGlobalHeader(BuildContext context) {
    return SizedBox(
      key: const Key('review-header'),
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final full = constraints.maxWidth >= _fullBreakpoint;
            final medium = constraints.maxWidth >= _mediumBreakpoint;
            final tabWidth = full ? 256.0 : (medium ? 228.0 : 196.0);
            final sideWidth = (constraints.maxWidth - tabWidth) / 2;
            return Row(
              key: const Key('review-toolbar-row'),
              children: [
                SizedBox(width: sideWidth),
                _tabs(tabWidth),
                SizedBox(width: sideWidth),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTranscriptPaneHeader(
    BuildContext context,
    AppController controller,
  ) => SizedBox(
    key: const Key('transcript-pane-header'),
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (searchVisible) return _buildPaneSearchRow(context);
          final full = constraints.maxWidth >= _paneFullBreakpoint;
          final medium = constraints.maxWidth >= _paneMediumBreakpoint;
          final showDirectActions =
              constraints.maxWidth >= _paneDirectActionsBreakpoint;
          return Row(
            key: const Key('transcript-pane-toolbar-row'),
            children: [
              if (showFilename)
                Expanded(child: ReviewFilename(job: job))
              else
                const Spacer(),
              if (_translationStarted && medium)
                _TranslationViewDropdown(
                  value: viewMode,
                  compact: !full,
                  onChanged: onViewModeChanged,
                ),
              _buildTranscriptActions(
                context,
                controller,
                medium: medium,
                showDirectActions: showDirectActions,
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _buildAiBriefPaneHeader(
    BuildContext context,
    AppController controller,
  ) => SizedBox(
    key: const Key('ai-brief-pane-header'),
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        key: const Key('ai-brief-pane-toolbar-row'),
        children: [
          Expanded(
            child: Text(
              context.strings.t('ai_brief'),
              key: const Key('ai-brief-pane-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          _buildAiBriefActions(context, controller),
        ],
      ),
    ),
  );

  Widget _tabs(double width) => ReviewContentTabs(
    width: width,
    showAiBrief: showAiBrief,
    onChanged: onTabChanged,
    aiBriefEnabled: !blindListening,
  );

  Widget _buildPaneSearchRow(BuildContext context) => Row(
    key: const Key('review-toolbar-search-row'),
    children: [
      IconButton(
        key: const Key('close-transcript-search'),
        tooltip: context.strings.t('close_search'),
        onPressed: onCloseSearch,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      const SizedBox(width: 4),
      Expanded(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): onCloseSearch,
            commandPeriod: onCloseSearch,
          },
          child: TextField(
            key: const Key('transcript-search-field'),
            autofocus: true,
            controller: search,
            onChanged: (_) => onSearch(),
            decoration: InputDecoration(
              isDense: true,
              hintText: context.strings.t('search_transcript'),
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
              suffixIconConstraints: const BoxConstraints(minWidth: 36),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      key: const Key('clear-transcript-search'),
                      tooltip: context.strings.t('clear_search'),
                      onPressed: () {
                        search.clear();
                        onSearch();
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _buildTranscriptActions(
    BuildContext context,
    AppController controller, {
    required bool medium,
    required bool showDirectActions,
  }) {
    final settings = controller.settings;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('open-transcript-search'),
          tooltip: context.strings.t('search_transcript'),
          onPressed: blindListening ? null : onOpenSearch,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.search_rounded),
        ),
        if (onToggleStructure != null && showDirectActions)
          IconButton(
            key: const Key('toggle-transcript-structure'),
            tooltip: context.strings.t(
              structureEnabled || structureMode
                  ? 'edit_subtitle_structure'
                  : 'edit_subtitle_structure_unavailable',
            ),
            isSelected: structureMode,
            onPressed: structureEnabled || structureMode
                ? onToggleStructure
                : null,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.call_split_rounded),
            selectedIcon: const Icon(Icons.call_split_rounded),
          ),
        if (structureMode) ...[
          IconButton(
            key: const Key('undo-transcript-structure'),
            tooltip: context.strings.t('undo'),
            onPressed: onUndoStructure,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            key: const Key('redo-transcript-structure'),
            tooltip: context.strings.t('redo'),
            onPressed: onRedoStructure,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.redo_rounded),
          ),
        ],
        if (showDirectActions) ...[
          IconButton(
            key: const Key('toggle-speaker-labels'),
            tooltip: context.strings.t('speaker_labels'),
            isSelected: settings.showSpeakers,
            onPressed: () => unawaited(
              controller.updateSettings(
                settings.copyWith(showSpeakers: !settings.showSpeakers),
              ),
            ),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.person_outline_rounded),
            selectedIcon: const Icon(Icons.person_rounded),
          ),
          IconButton(
            key: const Key('toggle-timestamps'),
            tooltip: context.strings.t('timestamps'),
            isSelected: settings.showTimestamps,
            onPressed: () => unawaited(
              controller.updateSettings(
                settings.copyWith(showTimestamps: !settings.showTimestamps),
              ),
            ),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.schedule_outlined),
            selectedIcon: const Icon(Icons.schedule_rounded),
          ),
        ],
        if (blindListening) ...[
          SentenceRevealButton(revealed: sentenceRevealed, onPressed: onReveal),
          IconButton(
            key: const Key('toggle-dictation'),
            tooltip: context.strings.t('dictation_type_answer'),
            isSelected: dictationOpen,
            onPressed: onToggleDictation,
            constraints: const BoxConstraints.tightFor(width: 32, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.keyboard_outlined),
          ),
        ],
        _focusButton(context),
        if (showDirectActions) ...[
          IconButton(
            key: const Key('copy-transcript-toolbar'),
            tooltip: context.strings.t('copy'),
            onPressed: () => _runTranscriptMoreAction(
              context,
              controller,
              settings,
              _TranscriptMoreAction.copy,
            ),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            key: const Key('export-transcript-toolbar'),
            tooltip: context.strings.t('export'),
            onPressed: () => _runTranscriptMoreAction(
              context,
              controller,
              settings,
              _TranscriptMoreAction.export,
            ),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
        _transcriptMoreMenu(
          context,
          controller,
          includeStructureToggle: !showDirectActions,
          includeViewToggles: !showDirectActions,
          includeViewMode: !medium,
          includeDocumentActions: !showDirectActions,
        ),
      ],
    );
  }

  Widget _focusButton(BuildContext context) => IconButton(
    key: const Key('focus-current-sentence'),
    tooltip: context.strings.t('focus_current_sentence'),
    onPressed: onFocusCurrentSentence,
    constraints: const BoxConstraints.tightFor(width: 40, height: 40),
    padding: EdgeInsets.zero,
    icon: const Icon(Icons.center_focus_strong_rounded),
  );

  Widget _transcriptMoreMenu(
    BuildContext context,
    AppController controller, {
    required bool includeStructureToggle,
    required bool includeViewToggles,
    required bool includeViewMode,
    required bool includeDocumentActions,
  }) {
    final settings = controller.settings;
    final translationAction = _translationToolbarAction(
      job.translationState.status,
    );
    final translateLabel = _translationStarted
        ? _translationToolbarActionLabel(context, translationAction)
        : context.strings.t('translate_with_llm');
    final translateIcon = _translationStarted
        ? _translationToolbarActionIcon(translationAction)
        : Icons.translate_rounded;
    final alignment = job.forcedAlignment;
    final supportsLocalAlignment = job.supportsLocalWordAlignment;
    final entries = <PopupMenuEntry<_TranscriptMoreAction>>[
      CheckedPopupMenuItem(
        key: const Key('toggle-blind-listening'),
        value: _TranscriptMoreAction.toggleBlindListening,
        checked: blindListening,
        enabled: onToggleBlindListening != null,
        child: Text(context.strings.t('blind_listening')),
      ),
      CheckedPopupMenuItem(
        key: const Key('more-toggle-mimic'),
        value: _TranscriptMoreAction.toggleMimic,
        checked: mimicOpen,
        enabled: onToggleMimic != null,
        child: Text(context.strings.t('mimic')),
      ),
    ];
    void addSection(List<PopupMenuEntry<_TranscriptMoreAction>> section) {
      if (section.isEmpty) return;
      if (entries.isNotEmpty) entries.add(const PopupMenuDivider());
      entries.addAll(section);
    }

    if (includeStructureToggle && onToggleStructure != null) {
      addSection(<PopupMenuEntry<_TranscriptMoreAction>>[
        CheckedPopupMenuItem(
          key: const Key('more-toggle-transcript-structure'),
          value: _TranscriptMoreAction.toggleStructure,
          checked: structureMode,
          enabled: structureEnabled || structureMode,
          child: Text(
            context.strings.t(
              structureEnabled || structureMode
                  ? 'edit_subtitle_structure'
                  : 'edit_subtitle_structure_unavailable',
            ),
          ),
        ),
      ]);
    }

    if (includeViewToggles) {
      addSection(<PopupMenuEntry<_TranscriptMoreAction>>[
        CheckedPopupMenuItem(
          key: const Key('more-toggle-speakers'),
          value: _TranscriptMoreAction.toggleSpeakers,
          checked: settings.showSpeakers,
          child: Text(context.strings.t('speaker_labels')),
        ),
        CheckedPopupMenuItem(
          key: const Key('more-toggle-timestamps'),
          value: _TranscriptMoreAction.toggleTimestamps,
          checked: settings.showTimestamps,
          child: Text(context.strings.t('timestamps')),
        ),
      ]);
    }
    if (includeViewMode && _translationStarted) {
      addSection(<PopupMenuEntry<_TranscriptMoreAction>>[
        CheckedPopupMenuItem(
          key: const Key('translation-mode-original-menu'),
          value: _TranscriptMoreAction.original,
          checked: viewMode == TranslationViewMode.original,
          child: Text(context.strings.t('original')),
        ),
        CheckedPopupMenuItem(
          key: const Key('translation-mode-translated-menu'),
          value: _TranscriptMoreAction.translated,
          checked: viewMode == TranslationViewMode.translated,
          child: Text(context.strings.t('translated')),
        ),
        CheckedPopupMenuItem(
          key: const Key('translation-mode-bilingual-menu'),
          value: _TranscriptMoreAction.bilingual,
          checked: viewMode == TranslationViewMode.bilingual,
          child: Text(context.strings.t('bilingual')),
        ),
      ]);
    }
    final processingActions = <PopupMenuEntry<_TranscriptMoreAction>>[];
    if (job.translationState.status.isActive == false) {
      processingActions.add(
        _menuItem(
          key: const Key('add-back-to-inbox'),
          value: _TranscriptMoreAction.addBackToInbox,
          icon: Icons.input_rounded,
          label: context.strings.t('add_back_to_inbox'),
        ),
      );
    }
    if (supportsLocalAlignment &&
        (alignment.hasWordTiming || alignment.canRequest)) {
      processingActions.add(
        _menuItem(
          key: Key(
            alignment.hasWordTiming
                ? 'rerun-forced-alignment'
                : 'retry-forced-alignment',
          ),
          value: _TranscriptMoreAction.retryAlignment,
          icon: Icons.refresh_rounded,
          label: context.strings.t(
            alignment.status == ForcedAlignmentStatus.notRequested
                ? 'run_local_alignment'
                : 'retry_local_alignment',
          ),
        ),
      );
    }
    if (job.translationState.status.isActive == false) {
      processingActions.add(
        _menuItem(
          key: const Key('translate-transcript'),
          value: _TranscriptMoreAction.translate,
          icon: translateIcon,
          label: translateLabel,
          enabled: controller.translationConfigured,
        ),
      );
    }
    addSection(processingActions);
    if (includeDocumentActions) {
      addSection(<PopupMenuEntry<_TranscriptMoreAction>>[
        _menuItem(
          key: const Key('copy-transcript-menu'),
          value: _TranscriptMoreAction.copy,
          icon: Icons.copy_all_outlined,
          label: context.strings.t('copy'),
        ),
        _menuItem(
          key: const Key('export-transcript-menu'),
          value: _TranscriptMoreAction.export,
          icon: Icons.ios_share_rounded,
          label: context.strings.t('export'),
        ),
      ]);
    }
    if (entries.isEmpty) return const SizedBox.shrink();
    return SizedBox.square(
      dimension: 40,
      child: PopupMenuButton<_TranscriptMoreAction>(
        key: const Key('review-toolbar-more'),
        tooltip: context.strings.t('more_actions'),
        padding: EdgeInsets.zero,
        onSelected: (action) =>
            _runTranscriptMoreAction(context, controller, settings, action),
        itemBuilder: (_) => entries,
        icon: const Icon(Icons.more_horiz_rounded),
      ),
    );
  }

  PopupMenuItem<_TranscriptMoreAction> _menuItem({
    Key? key,
    required _TranscriptMoreAction value,
    required IconData icon,
    required String label,
    bool enabled = true,
  }) => PopupMenuItem(
    key: key,
    value: value,
    enabled: enabled,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Flexible(child: Text(label)),
      ],
    ),
  );

  void _runTranscriptMoreAction(
    BuildContext context,
    AppController controller,
    AppSettings settings,
    _TranscriptMoreAction action,
  ) {
    switch (action) {
      case _TranscriptMoreAction.toggleBlindListening:
        onToggleBlindListening?.call();
      case _TranscriptMoreAction.toggleMimic:
        onToggleMimic?.call();
      case _TranscriptMoreAction.toggleStructure:
        onToggleStructure?.call();
      case _TranscriptMoreAction.toggleSpeakers:
        unawaited(
          controller.updateSettings(
            settings.copyWith(showSpeakers: !settings.showSpeakers),
          ),
        );
      case _TranscriptMoreAction.toggleTimestamps:
        unawaited(
          controller.updateSettings(
            settings.copyWith(showTimestamps: !settings.showTimestamps),
          ),
        );
      case _TranscriptMoreAction.original:
        onViewModeChanged(TranslationViewMode.original);
      case _TranscriptMoreAction.translated:
        onViewModeChanged(TranslationViewMode.translated);
      case _TranscriptMoreAction.bilingual:
        onViewModeChanged(TranslationViewMode.bilingual);
      case _TranscriptMoreAction.addBackToInbox:
        unawaited(_enqueueAgain(context, controller));
      case _TranscriptMoreAction.retryAlignment:
        unawaited(controller.retryForcedAlignment(job.id));
      case _TranscriptMoreAction.translate:
        if (_translationStarted) {
          _runTranslationToolbarAction(
            context,
            job,
            controller,
            _translationToolbarAction(job.translationState.status),
          );
        } else {
          unawaited(_showTranslationDialog(context, job));
        }
      case _TranscriptMoreAction.copy:
        unawaited(_copyTranscript(context, controller, settings));
      case _TranscriptMoreAction.export:
        unawaited(showTranscriptExportDialog(context, jobIds: [job.id]));
    }
  }

  Future<void> _enqueueAgain(
    BuildContext context,
    AppController controller,
  ) async {
    final queued = await controller.enqueueAgain(job.id);
    if (queued == null && context.mounted) {
      showAppNotice(
        context,
        message: context.strings.t('source_missing'),
        tone: AppNoticeTone.error,
      );
    }
  }

  Future<void> _copyTranscript(
    BuildContext context,
    AppController controller,
    AppSettings settings,
  ) async {
    final options = ExportOptions(
      showSpeakers: settings.showSpeakers,
      showTimestamps: settings.showTimestamps,
      localeCode: Localizations.localeOf(context).languageCode,
      contentMode: switch (viewMode) {
        TranslationViewMode.original => ExportContentMode.original,
        TranslationViewMode.translated => ExportContentMode.translated,
        TranslationViewMode.bilingual => ExportContentMode.bilingual,
      },
    );
    await Clipboard.setData(
      ClipboardData(text: controller.renderJob(job.id, options)),
    );
    if (context.mounted) {
      showAppNotice(
        context,
        message: context.strings.t('copied'),
        tone: AppNoticeTone.success,
      );
    }
  }

  Widget _buildAiBriefActions(BuildContext context, AppController controller) {
    final active = job.aiGenerationState.status.isActive;
    if (active) return const SizedBox.shrink();
    if (job.aiBrief == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('copy-ai-brief-toolbar'),
          tooltip: context.strings.t('copy_brief'),
          onPressed: () =>
              copyBriefText(context, controller.renderAiBriefMarkdown(job.id)),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.copy_all_outlined),
        ),
        IconButton(
          key: const Key('export-ai-brief-toolbar'),
          tooltip: context.strings.t('export_brief'),
          onPressed: () => exportBrief(context, job.id),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.ios_share_rounded),
        ),
        IconButton(
          key: const Key('refresh-ai-brief-toolbar'),
          tooltip: context.strings.t('refresh_ai_brief'),
          onPressed: onGenerateAiBrief,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }
}

class _TranslationViewDropdown extends StatelessWidget {
  const _TranslationViewDropdown({
    required this.value,
    required this.compact,
    required this.onChanged,
  });

  final TranslationViewMode value;
  final bool compact;
  final ValueChanged<TranslationViewMode> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('translation-view-mode-control'),
    width: compact ? 108 : 112,
    height: 40,
    padding: const EdgeInsets.only(left: 12, right: 8),
    decoration: BoxDecoration(
      color:
          Theme.of(context).inputDecorationTheme.fillColor ??
          Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<TranslationViewMode>(
        key: const Key('translation-view-mode'),
        value: value,
        isDense: true,
        isExpanded: true,
        icon: const Icon(Icons.arrow_drop_down_rounded, size: 20),
        items: [
          DropdownMenuItem(
            value: TranslationViewMode.original,
            child: Text(context.strings.t('original')),
          ),
          DropdownMenuItem(
            value: TranslationViewMode.translated,
            child: Text(context.strings.t('translated')),
          ),
          DropdownMenuItem(
            value: TranslationViewMode.bilingual,
            child: Text(context.strings.t('bilingual')),
          ),
        ],
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    ),
  );
}

enum _TranslationToolbarAction { retryUnfinished, retranslateAll, cancel }

_TranslationToolbarAction _translationToolbarAction(TranslationStatus status) {
  if (status.isActive) return _TranslationToolbarAction.cancel;
  if (status.canRetry) return _TranslationToolbarAction.retryUnfinished;
  return _TranslationToolbarAction.retranslateAll;
}

void _runTranslationToolbarAction(
  BuildContext context,
  TranscriptionJob job,
  AppController controller,
  _TranslationToolbarAction action,
) {
  switch (action) {
    case _TranslationToolbarAction.retryUnfinished:
      unawaited(controller.retryTranslation(job.id));
    case _TranslationToolbarAction.retranslateAll:
      unawaited(_confirmRetranslateAll(context, job));
    case _TranslationToolbarAction.cancel:
      controller.cancelTranslation(job.id);
  }
}

String _translationToolbarActionLabel(
  BuildContext context,
  _TranslationToolbarAction action,
) => switch (action) {
  _TranslationToolbarAction.retryUnfinished => context.strings.t(
    'translate_unfinished_with_llm',
  ),
  _TranslationToolbarAction.retranslateAll => context.strings.t(
    'retranslate_all_with_llm',
  ),
  _TranslationToolbarAction.cancel => context.strings.t('cancel'),
};

IconData _translationToolbarActionIcon(_TranslationToolbarAction action) =>
    switch (action) {
      _TranslationToolbarAction.retryUnfinished => Icons.refresh_rounded,
      _TranslationToolbarAction.retranslateAll => Icons.restart_alt_rounded,
      _TranslationToolbarAction.cancel => Icons.stop_circle_outlined,
    };

class TranslationStatusStrip extends StatelessWidget {
  const TranslationStatusStrip({super.key, required this.job});

  final TranscriptionJob job;

  @override
  Widget build(BuildContext context) {
    final state = job.translationState;
    return DecoratedBox(
      key: const Key('translation-status-strip'),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.status == TranslationStatus.translating)
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    key: const Key('translation-progress-bar'),
                    value: state.totalSegments == 0
                        ? null
                        : state.progress.clamp(0, 1),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('cancel-translation-progress'),
                  tooltip: context.strings.t('cancel'),
                  style: IconButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () =>
                      context.read<AppController>().cancelTranslation(job.id),
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
                const SizedBox(width: 4),
              ],
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: _TranslationStatusLabel(job: job, compact: false),
          ),
        ],
      ),
    );
  }
}

class _TranslationStatusLabel extends StatelessWidget {
  const _TranslationStatusLabel({required this.job, required this.compact});

  final TranscriptionJob job;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final state = job.translationState;
    final fullText = switch (state.status) {
      TranslationStatus.translating =>
        context.strings
            .t('translation_progress')
            .replaceFirst('{done}', '${state.completedSegments}')
            .replaceFirst('{total}', '${state.totalSegments}'),
      TranslationStatus.completed => context.strings.t('completed'),
      TranslationStatus.partial ||
      TranslationStatus.interrupted => context.strings.t('translation_partial'),
      TranslationStatus.cancelled => context.strings.t('translation_cancelled'),
      TranslationStatus.failed => context.strings.error(
        state.errorCode,
        englishFallback: state.errorMessage,
      ),
      TranslationStatus.idle => '',
    };
    if (fullText.isEmpty) return const SizedBox.shrink();
    final text = state.status == TranslationStatus.translating && compact
        ? '${state.completedSegments}/${state.totalSegments}'
        : fullText;
    final color = _translationStatusColor(context, state.status);
    final indicator = state.status == TranslationStatus.translating
        ? SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Icon(_translationStatusIcon(state.status), size: 17, color: color);
    return Semantics(
      label: fullText,
      excludeSemantics: true,
      child: Row(
        key: const Key('translation-status'),
        mainAxisSize: MainAxisSize.min,
        children: [
          indicator,
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              key: state.status == TranslationStatus.translating
                  ? const Key('translation-progress-count')
                  : null,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: state.status == TranslationStatus.completed
                    ? FontWeight.w600
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Color _translationStatusColor(BuildContext context, TranslationStatus status) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return switch (status) {
    TranslationStatus.completed =>
      dark ? Colors.green.shade300 : Colors.green.shade700,
    TranslationStatus.partial ||
    TranslationStatus.interrupted ||
    TranslationStatus.cancelled =>
      dark ? Colors.orange.shade300 : Colors.orange.shade700,
    TranslationStatus.failed => theme.colorScheme.error,
    TranslationStatus.translating => theme.colorScheme.primary,
    TranslationStatus.idle => theme.colorScheme.onSurfaceVariant,
  };
}

Color translatedSegmentHighlightColor(BuildContext context) =>
    _translationStatusColor(context, TranslationStatus.completed).withValues(
      alpha: Theme.of(context).brightness == Brightness.dark ? .18 : .10,
    );

IconData _translationStatusIcon(TranslationStatus status) => switch (status) {
  TranslationStatus.completed => Icons.check_circle_rounded,
  TranslationStatus.partial ||
  TranslationStatus.interrupted ||
  TranslationStatus.cancelled => Icons.warning_amber_rounded,
  TranslationStatus.failed => Icons.error_rounded,
  TranslationStatus.translating => Icons.sync_rounded,
  TranslationStatus.idle => Icons.info_outline_rounded,
};

Future<void> _showTranslationDialog(
  BuildContext context,
  TranscriptionJob job,
) async {
  final controller = context.read<AppController>();
  var target = job.translationState.targetLanguage.isNotEmpty
      ? job.translationState.targetLanguage
      : controller.settings.translationSettings.targetLanguage;
  if (!supportedTranslationLanguageCodes.contains(target)) target = 'en';
  final selected = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(context.strings.t('translate_with_llm')),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: const Key('manual-translation-target'),
                initialValue: target,
                decoration: InputDecoration(
                  labelText: context.strings.t('target_language'),
                ),
                items: [
                  for (final code in supportedTranslationLanguageCodes)
                    DropdownMenuItem(
                      value: code,
                      child: Text(
                        context.strings.translationLanguageName(code),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => target = value);
                },
              ),
              const SizedBox(height: 12),
              Text(
                context.strings
                    .t('translation_model_label')
                    .replaceFirst(
                      '{model}',
                      controller.settings.translationSettings.model,
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
            onPressed: () => Navigator.pop(context, target),
            child: Text(context.strings.t('translate_with_llm')),
          ),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  final hasExisting =
      job.document?.segments.any((segment) => segment.hasTranslation) ?? false;
  final targetChanged =
      hasExisting &&
      job.translationState.targetLanguage.isNotEmpty &&
      job.translationState.targetLanguage != selected;
  var replace = false;
  if (targetChanged) {
    replace = await _confirmTranslationReplacement(context) ?? false;
    if (!replace || !context.mounted) return;
  }
  await controller.translateJob(
    job.id,
    targetLanguage: selected,
    replaceExisting: replace,
  );
}

Future<void> _confirmRetranslateAll(
  BuildContext context,
  TranscriptionJob job,
) async {
  if (await _confirmTranslationReplacement(context) != true ||
      !context.mounted) {
    return;
  }
  final controller = context.read<AppController>();
  final target = job.translationState.targetLanguage.isNotEmpty
      ? job.translationState.targetLanguage
      : controller.settings.translationSettings.targetLanguage;
  await controller.translateJob(
    job.id,
    targetLanguage: target,
    replaceExisting: true,
  );
}

Future<bool?> _confirmTranslationReplacement(BuildContext context) =>
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.t('translation_replace_title')),
        content: Text(context.strings.t('translation_replace_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.t('continue')),
          ),
        ],
      ),
    );
