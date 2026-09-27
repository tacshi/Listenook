part of '../transcript_review.dart';

class _AiBriefDialogResult {
  const _AiBriefDialogResult(
    this.sections,
    this.outputLanguage,
    this.learningLanguage,
    this.learningLevel,
  );

  final Set<AiBriefSection> sections;
  final String outputLanguage;
  final String? learningLanguage;
  final AiLearningLevel learningLevel;
}

Future<T?> _showDialogAfterDismissal<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  TransitionRoute<T>? dialogRoute;
  final result = await showDialog<T>(
    context: context,
    builder: (context) {
      final route = ModalRoute.of<T>(context);
      if (route is TransitionRoute<T>) dialogRoute = route;
      return builder(context);
    },
  );
  await dialogRoute?.completed;
  return result;
}

Future<_AiBriefDialogResult?> _showAiBriefGenerationDialog(
  BuildContext context,
  TranscriptionJob job,
) async {
  final controller = context.read<AppController>();
  var sections = Set<AiBriefSection>.of(
    job.aiBrief?.selectedSections ??
        (job.sourceOrigin == JobSourceOrigin.podcast
            ? {AiBriefSection.languageNotes}
            : defaultAiBriefSections),
  );
  var outputLanguage =
      job.aiBrief?.outputLanguage ??
      (job.sourceOrigin == JobSourceOrigin.podcast
          ? 'zh-Hans'
          : controller.defaultAiBriefLanguage);
  var learningLanguage =
      job.aiBrief?.learningLanguage ??
      (job.sourceOrigin == JobSourceOrigin.podcast ? 'en' : null);
  var learningLevel =
      job.aiBrief?.learningLevel ?? AiLearningLevel.intermediate;
  if (learningLanguage != null &&
      !supportedTranslationLanguageCodes.contains(learningLanguage)) {
    learningLanguage = null;
  }
  if (!supportedTranslationLanguageCodes.contains(outputLanguage)) {
    outputLanguage = 'en';
  }
  return _showDialogAfterDismissal<_AiBriefDialogResult>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        return AlertDialog(
          title: Text(
            context.strings.t(
              job.aiBrief == null ? 'create_ai_brief' : 'refresh_ai_brief',
            ),
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(context.strings.t('ai_brief_description')),
                  const SizedBox(height: 16),
                  Text(
                    context.strings.t('ai_brief_sections'),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final section in AiBriefSection.values)
                        FilterChip(
                          key: ValueKey('ai-brief-section-${section.name}'),
                          selected: sections.contains(section),
                          label: Text(
                            context.strings.t(
                              'ai_brief_section_${section.name}',
                            ),
                          ),
                          onSelected: (selected) => setDialogState(() {
                            if (selected) {
                              sections.add(section);
                            } else {
                              sections.remove(section);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (sections.contains(AiBriefSection.languageNotes)) ...[
                    DropdownButtonFormField<String>(
                      key: const Key('ai-brief-learning-language'),
                      initialValue: learningLanguage ?? '',
                      decoration: InputDecoration(
                        labelText: context.strings.t(
                          'ai_brief_learning_language',
                        ),
                        prefixIcon: const Icon(Icons.school_outlined),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(
                            context.strings.t(
                              'ai_brief_learning_language_auto',
                            ),
                          ),
                        ),
                        for (final code in supportedTranslationLanguageCodes)
                          DropdownMenuItem(
                            value: code,
                            child: Text(
                              context.strings.translationLanguageName(code),
                            ),
                          ),
                      ],
                      onChanged: (value) => setDialogState(
                        () => learningLanguage = value?.isEmpty ?? true
                            ? null
                            : value,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<AiLearningLevel>(
                      key: const Key('ai-brief-learning-level'),
                      initialValue: learningLevel,
                      decoration: InputDecoration(
                        labelText: context.strings.t('ai_brief_learning_level'),
                        prefixIcon: const Icon(Icons.trending_up_rounded),
                      ),
                      items: [
                        for (final level in AiLearningLevel.values)
                          DropdownMenuItem(
                            value: level,
                            child: Text(_learningLevelLabel(context, level)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => learningLevel = value);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                  DropdownButtonFormField<String>(
                    key: const Key('ai-brief-output-language'),
                    initialValue: outputLanguage,
                    decoration: InputDecoration(
                      labelText: context.strings.t('ai_brief_output_language'),
                      prefixIcon: const Icon(Icons.language_rounded),
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
                      if (value != null) {
                        setDialogState(() => outputLanguage = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.strings
                        .t('ai_brief_model')
                        .replaceFirst(
                          '{model}',
                          controller.settings.llmProviderSettings.model,
                        ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.strings.t('cancel')),
            ),
            FilledButton.icon(
              key: const Key('confirm-create-ai-brief'),
              onPressed: sections.isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      _AiBriefDialogResult(
                        Set<AiBriefSection>.of(sections),
                        outputLanguage,
                        learningLanguage,
                        learningLevel,
                      ),
                    ),
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(context.strings.t('generate')),
            ),
          ],
        );
      },
    ),
  );
}

class _AiBriefPane extends StatelessWidget {
  const _AiBriefPane({
    required this.job,
    required this.document,
    required this.scrollController,
    required this.onGenerate,
    required this.onEvidence,
  });

  final TranscriptionJob job;
  final TranscriptDocument document;
  final ScrollController scrollController;
  final VoidCallback onGenerate;
  final Future<void> Function(String segmentId) onEvidence;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final state = job.aiGenerationState;
    final brief = job.aiBrief;
    if (brief == null && state.status.isActive) {
      return _AiBriefProgress(job: job);
    }
    if (brief == null) {
      return _AiBriefEmpty(job: job, onGenerate: onGenerate);
    }
    return Column(
      children: [
        if (brief.isStaleFor(document))
          MaterialBanner(
            key: const Key('ai-brief-outdated'),
            leading: const Icon(Icons.update_rounded),
            content: Text(context.strings.t('ai_brief_outdated')),
            actions: [
              TextButton(
                onPressed: state.status.isActive ? null : onGenerate,
                child: Text(context.strings.t('refresh_ai_brief')),
              ),
            ],
          ),
        if (state.status.isActive) _AiBriefProgress(job: job, compact: true),
        if (!state.status.isActive && state.errorCode != null)
          MaterialBanner(
            leading: Icon(
              state.status == AiGenerationStatus.cancelled
                  ? Icons.stop_circle_outlined
                  : Icons.error_outline_rounded,
            ),
            content: Text(
              context.strings.error(
                state.errorCode,
                englishFallback: state.errorMessage,
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: () => controller.retryAiBrief(job.id),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.strings.t('retry')),
              ),
            ],
          ),
        Expanded(
          child: ListView(
            key: const Key('ai-brief-scroll'),
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              Row(
                children: [
                  const Icon(Icons.verified_outlined, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.strings.t('ai_brief_draft'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              if (brief.overview.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                _AiBriefSectionCard(
                  id: 'overview',
                  title: context.strings.t('overview'),
                  icon: Icons.summarize_outlined,
                  onEdit: () => _editOverview(context, job),
                  onRegenerate: state.status.isActive
                      ? null
                      : () => _regenerateAiSection(
                          context,
                          job,
                          AiBriefSection.overview,
                        ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(brief.overview),
                      const SizedBox(height: 8),
                      _EvidenceChips(
                        document: document,
                        segmentIds: brief.overviewEvidenceSegmentIds,
                        onEvidence: onEvidence,
                      ),
                    ],
                  ),
                ),
              ],
              if (brief.chapters.isNotEmpty) ...[
                const SizedBox(height: 12),
                _AiBriefSectionCard(
                  id: 'chapters',
                  title: context.strings.t('chapters'),
                  icon: Icons.view_timeline_outlined,
                  onRegenerate: state.status.isActive
                      ? null
                      : () => _regenerateAiSection(
                          context,
                          job,
                          AiBriefSection.chapters,
                        ),
                  child: Column(
                    children: [
                      for (final chapter in brief.chapters)
                        _AiChapterTile(
                          job: job,
                          document: document,
                          chapter: chapter,
                          onEvidence: onEvidence,
                        ),
                    ],
                  ),
                ),
              ],
              for (final type in AiInsightType.values)
                if (brief.insights.any((item) => item.type == type)) ...[
                  const SizedBox(height: 12),
                  _AiBriefSectionCard(
                    id: 'insight-${type.name}',
                    title: _insightTitle(context, type),
                    icon: _insightIcon(type),
                    onRegenerate: state.status.isActive
                        ? null
                        : () => _regenerateAiSection(
                            context,
                            job,
                            _sectionForInsight(type),
                          ),
                    child: Column(
                      children: [
                        for (final insight in brief.insights.where(
                          (item) => item.type == type,
                        ))
                          _AiInsightTile(
                            job: job,
                            document: document,
                            insight: insight,
                            onEvidence: onEvidence,
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => _addInsight(context, job, type),
                            icon: const Icon(Icons.add_rounded),
                            label: Text(context.strings.t('add_item')),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              if (brief.languageNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                _AiBriefSectionCard(
                  id: 'language-notes',
                  title: context.strings.t('language_notes'),
                  icon: Icons.menu_book_outlined,
                  headerMeta: Chip(
                    avatar: const Icon(Icons.trending_up_rounded, size: 16),
                    label: Text(
                      _learningLevelLabel(context, brief.learningLevel),
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onRegenerate: state.status.isActive
                      ? null
                      : () => _regenerateAiSection(
                          context,
                          job,
                          AiBriefSection.languageNotes,
                        ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final kind in AiLanguageNoteKind.values)
                        if (brief.languageNotes.any(
                          (item) => item.kind == kind,
                        )) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(2, 12, 2, 4),
                            child: Text(
                              _languageNoteKindLabel(context, kind),
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          for (final note in brief.languageNotes.where(
                            (item) => item.kind == kind,
                          ))
                            _AiLanguageNoteTile(
                              job: job,
                              document: document,
                              note: note,
                              onEvidence: onEvidence,
                            ),
                        ],
                    ],
                  ),
                ),
              ],
              if (brief.insights.isEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () =>
                        _addInsight(context, job, AiInsightType.keyIdea),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(context.strings.t('add_item')),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AiBriefEmpty extends StatelessWidget {
  const _AiBriefEmpty({required this.job, required this.onGenerate});

  final TranscriptionJob job;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final state = job.aiGenerationState;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                context.strings.t('ai_brief_empty'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                context.strings.t('ai_brief_empty_body'),
                textAlign: TextAlign.center,
              ),
              if (state.errorCode != null) ...[
                const SizedBox(height: 12),
                Text(
                  context.strings.error(
                    state.errorCode,
                    englishFallback: state.errorMessage,
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('ai-brief-empty-action'),
                onPressed: controller.aiBriefConfigured ? onGenerate : null,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(
                  context.strings.t(
                    state.status.canRetry ? 'retry' : 'create_ai_brief',
                  ),
                ),
              ),
              if (!controller.aiBriefConfigured) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () =>
                      controller.setDestination(AppDestination.settings),
                  child: Text(context.strings.t('ai_brief_configure')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AiBriefProgress extends StatelessWidget {
  const _AiBriefProgress({required this.job, this.compact = false});

  final TranscriptionJob job;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final state = job.aiGenerationState;
    final text = state.stage == 'synthesizing'
        ? context.strings.t('ai_brief_progress_synthesizing')
        : context.strings.t('ai_brief_progress_analyzing');
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text(text)),
            TextButton.icon(
              key: const Key('cancel-ai-brief-progress'),
              onPressed: () =>
                  context.read<AppController>().cancelAiBrief(job.id),
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(context.strings.t('cancel')),
            ),
          ],
        ),
      ],
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: content,
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(padding: const EdgeInsets.all(24), child: content),
      ),
    );
  }
}

class _AiBriefSectionCard extends StatefulWidget {
  const _AiBriefSectionCard({
    required this.id,
    required this.title,
    required this.icon,
    this.headerMeta,
    this.onEdit,
    required this.onRegenerate,
    required this.child,
  });

  final String id;
  final String title;
  final IconData icon;
  final Widget? headerMeta;
  final VoidCallback? onEdit;
  final VoidCallback? onRegenerate;
  final Widget child;

  @override
  State<_AiBriefSectionCard> createState() => _AiBriefSectionCardState();
}

class _AiBriefSectionCardState extends State<_AiBriefSectionCard> {
  bool _hovered = false;
  bool _menuOpen = false;
  bool _actionsFocused = false;

  bool get _showActions => _hovered || _menuOpen || _actionsFocused;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Card(
      key: ValueKey('ai-brief-section-${widget.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              key: ValueKey('ai-brief-section-header-${widget.id}'),
              children: [
                Icon(widget.icon, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.title,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (widget.headerMeta != null) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          flex: 2,
                          child: KeyedSubtree(
                            key: ValueKey('ai-brief-section-meta-${widget.id}'),
                            child: widget.headerMeta!,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.onEdit != null || widget.onRegenerate != null)
                  Focus(
                    onFocusChange: (value) =>
                        setState(() => _actionsFocused = value),
                    child: AnimatedOpacity(
                      key: ValueKey('ai-brief-section-actions-${widget.id}'),
                      opacity: _showActions ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: IgnorePointer(
                        ignoring: !_showActions,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.onEdit != null)
                              IconButton(
                                key: ValueKey(
                                  'ai-brief-section-edit-${widget.id}',
                                ),
                                tooltip: context.strings.t('edit'),
                                onPressed: widget.onEdit,
                                icon: const Icon(Icons.edit_outlined, size: 19),
                              ),
                            if (widget.onRegenerate != null)
                              PopupMenuButton<String>(
                                key: ValueKey(
                                  'ai-brief-section-menu-${widget.id}',
                                ),
                                tooltip: context.strings.t('more_actions'),
                                onOpened: () =>
                                    setState(() => _menuOpen = true),
                                onCanceled: () =>
                                    setState(() => _menuOpen = false),
                                onSelected: (value) {
                                  setState(() => _menuOpen = false);
                                  if (value == 'regenerate') {
                                    widget.onRegenerate?.call();
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'regenerate',
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.refresh_rounded,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            context.strings.t(
                                              'regenerate_section',
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 6, 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    ),
  );
}

class _AiChapterTile extends StatelessWidget {
  const _AiChapterTile({
    required this.job,
    required this.document,
    required this.chapter,
    required this.onEvidence,
  });

  final TranscriptionJob job;
  final TranscriptDocument document;
  final AiChapter chapter;
  final Future<void> Function(String) onEvidence;

  @override
  Widget build(BuildContext context) => Card.outlined(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TextButton(
                onPressed: chapter.evidenceSegmentIds.isEmpty
                    ? null
                    : () => onEvidence(chapter.evidenceSegmentIds.first),
                child: Text(
                  _evidenceRange(document, chapter.evidenceSegmentIds),
                ),
              ),
              Expanded(
                child: Text(
                  chapter.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') _editChapter(context, job, chapter);
                  if (value == 'delete') {
                    context.read<AppController>().deleteAiChapter(
                      job.id,
                      chapter.id,
                    );
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(context.strings.t('edit')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(context.strings.t('delete_item')),
                  ),
                ],
              ),
            ],
          ),
          if (chapter.summary.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(chapter.summary),
            ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: _EvidenceChips(
              document: document,
              segmentIds: chapter.evidenceSegmentIds,
              onEvidence: onEvidence,
            ),
          ),
        ],
      ),
    ),
  );
}

class _AiInsightTile extends StatelessWidget {
  const _AiInsightTile({
    required this.job,
    required this.document,
    required this.insight,
    required this.onEvidence,
  });

  final TranscriptionJob job;
  final TranscriptDocument document;
  final AiInsight insight;
  final Future<void> Function(String) onEvidence;

  @override
  Widget build(BuildContext context) => Card.outlined(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(insight.text)),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') _editInsight(context, job, insight);
                  if (value == 'delete') {
                    context.read<AppController>().deleteAiInsight(
                      job.id,
                      insight.id,
                    );
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(context.strings.t('edit_item')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(context.strings.t('delete_item')),
                  ),
                ],
              ),
            ],
          ),
          if ((insight.owner?.isNotEmpty ?? false) ||
              (insight.deadline?.isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                children: [
                  if (insight.owner?.isNotEmpty ?? false)
                    Chip(
                      avatar: const Icon(Icons.person_outline, size: 16),
                      label: Text(insight.owner!),
                    ),
                  if (insight.deadline?.isNotEmpty ?? false)
                    Chip(
                      avatar: const Icon(Icons.event_outlined, size: 16),
                      label: Text(insight.deadline!),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          _EvidenceChips(
            document: document,
            segmentIds: insight.evidenceSegmentIds,
            onEvidence: onEvidence,
          ),
        ],
      ),
    ),
  );
}

class _AiLanguageNoteTile extends StatefulWidget {
  const _AiLanguageNoteTile({
    required this.job,
    required this.document,
    required this.note,
    required this.onEvidence,
  });

  final TranscriptionJob job;
  final TranscriptDocument document;
  final AiLanguageNote note;
  final Future<void> Function(String) onEvidence;

  @override
  State<_AiLanguageNoteTile> createState() => _AiLanguageNoteTileState();
}

class _AiLanguageNoteTileState extends State<_AiLanguageNoteTile> {
  bool _hovered = false;
  bool _menuOpen = false;
  bool _menuFocused = false;

  bool get _showMenu => _hovered || _menuOpen || _menuFocused;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Card.outlined(
      key: ValueKey('ai-language-note-${widget.note.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    widget.note.term,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Focus(
                  onFocusChange: (value) =>
                      setState(() => _menuFocused = value),
                  child: AnimatedOpacity(
                    key: ValueKey(
                      'ai-language-note-menu-reveal-${widget.note.id}',
                    ),
                    opacity: _showMenu ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: IgnorePointer(
                      ignoring: !_showMenu,
                      child: PopupMenuButton<String>(
                        key: ValueKey(
                          'ai-language-note-menu-${widget.note.id}',
                        ),
                        onOpened: () => setState(() => _menuOpen = true),
                        onCanceled: () => setState(() => _menuOpen = false),
                        onSelected: (value) {
                          setState(() => _menuOpen = false);
                          if (value == 'edit') {
                            _editLanguageNote(context, widget.job, widget.note);
                          }
                          if (value == 'delete') {
                            context.read<AppController>().deleteAiLanguageNote(
                              widget.job.id,
                              widget.note.id,
                            );
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(context.strings.t('edit_item')),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(context.strings.t('delete_item')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (widget.note.explanation.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(widget.note.explanation),
            ],
            if (widget.note.sourceExcerpt.isNotEmpty) ...[
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Text(
                    '“${widget.note.sourceExcerpt}”',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            _EvidenceChips(
              document: widget.document,
              segmentIds: widget.note.evidenceSegmentIds,
              onEvidence: widget.onEvidence,
            ),
          ],
        ),
      ),
    ),
  );
}

class _EvidenceChips extends StatelessWidget {
  const _EvidenceChips({
    required this.document,
    required this.segmentIds,
    required this.onEvidence,
  });

  final TranscriptDocument document;
  final List<String> segmentIds;
  final Future<void> Function(String) onEvidence;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final segment in document.segments) segment.id: segment};
    final evidence = segmentIds
        .map((id) => (id: id, segment: byId[id]))
        .where((item) => item.segment != null)
        .toList();
    if (evidence.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      runSpacing: 3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '${context.strings.t('evidence')}:',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        for (final item in evidence)
          ActionChip(
            key: ValueKey('ai-evidence-${item.id}'),
            avatarBoxConstraints: const BoxConstraints.tightFor(
              width: 14,
              height: 14,
            ),
            avatar: const Icon(Icons.play_arrow_rounded, size: 14),
            label: Text(
              formatClock(item.segment!.startMs),
              style: Theme.of(context).textTheme.labelSmall,
            ),
            padding: EdgeInsets.zero,
            labelPadding: const EdgeInsets.only(left: 2, right: 6),
            visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onPressed: () => onEvidence(item.id),
          ),
      ],
    );
  }
}

Future<void> _copyBriefText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text.trim()));
  if (!context.mounted) return;
  showAppNotice(
    context,
    message: context.strings.t('brief_copied'),
    tone: AppNoticeTone.success,
  );
}

Future<void> _exportBrief(BuildContext context, String jobId) async {
  final directory = await getDirectoryPath(
    confirmButtonText: context.strings.t('export_brief'),
  );
  if (directory == null || !context.mounted) return;
  await context.read<AppController>().exportAiBrief(jobId, directory);
  if (!context.mounted) return;
  showAppNotice(
    context,
    message: context.strings.t('brief_exported'),
    tone: AppNoticeTone.success,
  );
}

Future<void> _regenerateAiSection(
  BuildContext context,
  TranscriptionJob job,
  AiBriefSection section,
) async {
  final edited = switch (section) {
    AiBriefSection.overview => job.aiBrief?.edited ?? false,
    AiBriefSection.chapters =>
      job.aiBrief?.chapters.any((item) => item.edited) ?? false,
    AiBriefSection.languageNotes =>
      job.aiBrief?.languageNotes.any((item) => item.edited) ?? false,
    _ =>
      job.aiBrief?.insights.any(
            (item) => item.edited && _sectionForInsight(item.type) == section,
          ) ??
          false,
  };
  if (edited) {
    final replace = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.t('ai_brief_edited_refresh_title')),
        content: Text(context.strings.t('ai_brief_edited_refresh_body')),
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
    if (replace != true || !context.mounted) return;
  }
  unawaited(
    context.read<AppController>().regenerateAiBriefSections(job.id, {section}),
  );
}

Future<void> _editOverview(BuildContext context, TranscriptionJob job) async {
  final field = TextEditingController(text: job.aiBrief?.overview ?? '');
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.strings.t('overview')),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: field,
          autofocus: true,
          minLines: 4,
          maxLines: 12,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.strings.t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, field.text),
          child: Text(context.strings.t('save')),
        ),
      ],
    ),
  );
  field.dispose();
  if (value != null && context.mounted) {
    await context.read<AppController>().updateAiBriefOverview(job.id, value);
  }
}

Future<void> _editChapter(
  BuildContext context,
  TranscriptionJob job,
  AiChapter chapter,
) async {
  final title = TextEditingController(text: chapter.title);
  final summary = TextEditingController(text: chapter.summary);
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.strings.t('chapters')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: title, autofocus: true),
            const SizedBox(height: 12),
            TextField(controller: summary, minLines: 3, maxLines: 8),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.strings.t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.strings.t('save')),
        ),
      ],
    ),
  );
  if (save == true && context.mounted) {
    await context.read<AppController>().updateAiChapter(
      job.id,
      chapter.id,
      title: title.text,
      summary: summary.text,
    );
  }
  title.dispose();
  summary.dispose();
}

Future<void> _editInsight(
  BuildContext context,
  TranscriptionJob job,
  AiInsight insight,
) async {
  final text = TextEditingController(text: insight.text);
  final owner = TextEditingController(text: insight.owner ?? '');
  final deadline = TextEditingController(text: insight.deadline ?? '');
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.strings.t('edit_item')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: text,
              autofocus: true,
              minLines: 2,
              maxLines: 8,
            ),
            if (insight.type == AiInsightType.actionItem) ...[
              const SizedBox(height: 12),
              TextField(
                controller: owner,
                decoration: InputDecoration(
                  labelText: context.strings.t('owner'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: deadline,
                decoration: InputDecoration(
                  labelText: context.strings.t('deadline'),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.strings.t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.strings.t('save')),
        ),
      ],
    ),
  );
  if (save == true && context.mounted) {
    await context.read<AppController>().updateAiInsight(
      job.id,
      insight.id,
      text: text.text,
      owner: owner.text,
      deadline: deadline.text,
    );
  }
  text.dispose();
  owner.dispose();
  deadline.dispose();
}

Future<void> _editLanguageNote(
  BuildContext context,
  TranscriptionJob job,
  AiLanguageNote note,
) async {
  final term = TextEditingController(text: note.term);
  final explanation = TextEditingController(text: note.explanation);
  final sourceExcerpt = TextEditingController(text: note.sourceExcerpt);
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.strings.t('edit_language_note')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('ai-language-note-term'),
                controller: term,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: context.strings.t('language_note_term'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('ai-language-note-explanation'),
                controller: explanation,
                minLines: 3,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: context.strings.t('language_note_explanation'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('ai-language-note-excerpt'),
                controller: sourceExcerpt,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: context.strings.t('language_note_source_excerpt'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.strings.t('cancel')),
        ),
        FilledButton(
          onPressed:
              term.text.trim().isEmpty ||
                  explanation.text.trim().isEmpty ||
                  sourceExcerpt.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, true),
          child: Text(context.strings.t('save')),
        ),
      ],
    ),
  );
  if (save == true && context.mounted) {
    await context.read<AppController>().updateAiLanguageNote(
      job.id,
      note.id,
      term: term.text,
      explanation: explanation.text,
      sourceExcerpt: sourceExcerpt.text,
    );
  }
  WidgetsBinding.instance.addPostFrameCallback((_) {
    term.dispose();
    explanation.dispose();
    sourceExcerpt.dispose();
  });
}

Future<void> _addInsight(
  BuildContext context,
  TranscriptionJob job,
  AiInsightType initialType,
) async {
  final text = TextEditingController();
  var type = initialType;
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(context.strings.t('add_item')),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<AiInsightType>(
                initialValue: type,
                items: [
                  for (final value in AiInsightType.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(_insightTitle(context, value)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => type = value);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: text,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.t('save')),
          ),
        ],
      ),
    ),
  );
  if (save == true && context.mounted) {
    await context.read<AppController>().addAiInsight(
      job.id,
      type: type,
      text: text.text,
    );
  }
  text.dispose();
}

String _evidenceRange(TranscriptDocument document, List<String> segmentIds) {
  final byId = {for (final segment in document.segments) segment.id: segment};
  final segments = segmentIds
      .map((id) => byId[id])
      .whereType<TranscriptSegment>()
      .toList();
  if (segments.isEmpty) return '';
  final start = formatClock(segments.first.startMs);
  final end = formatClock(segments.last.endMs);
  return start == end ? start : '$start–$end';
}

String _insightTitle(BuildContext context, AiInsightType type) =>
    switch (type) {
      AiInsightType.keyIdea => context.strings.t('key_ideas'),
      AiInsightType.notableMoment => context.strings.t('notable_moments'),
      AiInsightType.decision => context.strings.t('decisions'),
      AiInsightType.actionItem => context.strings.t('action_items'),
      AiInsightType.openQuestion => context.strings.t('open_questions'),
    };

IconData _insightIcon(AiInsightType type) => switch (type) {
  AiInsightType.keyIdea => Icons.lightbulb_outline_rounded,
  AiInsightType.notableMoment => Icons.stars_outlined,
  AiInsightType.decision => Icons.gavel_outlined,
  AiInsightType.actionItem => Icons.task_alt_rounded,
  AiInsightType.openQuestion => Icons.help_outline_rounded,
};

AiBriefSection _sectionForInsight(AiInsightType type) => switch (type) {
  AiInsightType.keyIdea ||
  AiInsightType.notableMoment => AiBriefSection.keyIdeas,
  AiInsightType.decision => AiBriefSection.decisions,
  AiInsightType.actionItem => AiBriefSection.actionItems,
  AiInsightType.openQuestion => AiBriefSection.openQuestions,
};

String _learningLevelLabel(BuildContext context, AiLearningLevel level) =>
    context.strings.t('ai_learning_level_${level.name}');

String _languageNoteKindLabel(BuildContext context, AiLanguageNoteKind kind) =>
    context.strings.t('ai_language_note_kind_${kind.name}');
