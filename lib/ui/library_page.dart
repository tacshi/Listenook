import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../data/transcript_exporter.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'job_actions.dart';
import 'transcript_export_dialog.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String _status = 'all';
  String _scope = 'all';
  String? _scopeId;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final jobs = controller.allJobs
        .where((job) => _matches(job, controller))
        .toList();
    final selectedJobs = controller.allJobs
        .where((job) => _selectedIds.contains(job.id))
        .toList(growable: false);
    final exportableIds = selectedJobs
        .where((job) => job.document != null)
        .map((job) => job.id)
        .toList(growable: false);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 210,
                    child: _LibraryOrganizerSidebar(
                      controller: controller,
                      scope: _scope,
                      scopeId: _scopeId,
                      onScopeChanged: (scope, id) => _changeView(() {
                        _scope = scope;
                        _scopeId = id;
                      }),
                      onAddGroup: () =>
                          _showCreateGroupDialog(context, controller),
                      onRenameGroup: (group) =>
                          _showRenameGroupDialog(context, controller, group),
                      onDeleteGroup: (group) =>
                          _confirmDeleteGroup(context, controller, group),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const VerticalDivider(width: 1),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _libraryToolbar(context),
                        if (_selectionMode) ...[
                          const SizedBox(height: 8),
                          _LibrarySelectionBar(
                            selectedCount: _selectedIds.length,
                            visibleJobs: jobs,
                            onSelectAllVisible: () => setState(() {
                              final visibleIds = jobs
                                  .map((job) => job.id)
                                  .toSet();
                              if (_selectedIds.containsAll(visibleIds)) {
                                _selectedIds.removeAll(visibleIds);
                              } else {
                                _selectedIds.addAll(visibleIds);
                              }
                            }),
                            onMove: _selectedIds.isEmpty
                                ? null
                                : () => _showMoveToGroupDialog(
                                    context,
                                    controller,
                                    _selectedIds,
                                  ),
                            onTags: selectedJobs.isEmpty
                                ? null
                                : () async => _manageTags(
                                    context,
                                    controller,
                                    selectedJobs,
                                  ),
                            onExport: exportableIds.isEmpty
                                ? null
                                : () => showTranscriptExportDialog(
                                    context,
                                    jobIds: exportableIds,
                                  ),
                            onRemove:
                                selectedJobs.isNotEmpty &&
                                    selectedJobs.every((job) => !job.isBusy)
                                ? () =>
                                      _confirmBulkRemove(context, selectedJobs)
                                : null,
                          ),
                        ],
                        const SizedBox(height: 8),
                        Expanded(
                          child: jobs.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.library_books_outlined,
                                        size: 64,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.outline,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(context.strings.t('no_history')),
                                    ],
                                  ),
                                )
                              : ListView.separated(
                                  itemCount: jobs.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1, thickness: 1),
                                  itemBuilder: (context, index) =>
                                      _HistoryListItem(
                                        job: jobs[index],
                                        selectionMode: _selectionMode,
                                        selected: _selectedIds.contains(
                                          jobs[index].id,
                                        ),
                                        onSelectedChanged: (selected) =>
                                            setState(
                                              () => selected
                                                  ? _selectedIds.add(
                                                      jobs[index].id,
                                                    )
                                                  : _selectedIds.remove(
                                                      jobs[index].id,
                                                    ),
                                            ),
                                        onManageTags: () => _manageTags(
                                          context,
                                          controller,
                                          [jobs[index]],
                                        ),
                                      ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateGroupDialog(
    BuildContext context,
    AppController controller,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _OrganizerNameDialog(
        title: context.strings.t('new_group'),
        validateName: (name) =>
            controller.libraryGroups.any(
              (group) => group.name.toLowerCase() == name.toLowerCase(),
            )
            ? context.strings.t('group_name_exists')
            : null,
      ),
    );
    if (name != null) await controller.createLibraryGroup(name);
  }

  Future<void> _manageTags(
    BuildContext context,
    AppController controller,
    List<TranscriptionJob> jobs,
  ) async {
    await _showManageTagsDialog(context, controller, jobs);
    if (!mounted || _scope != 'tag' || _scopeId == null) return;
    final activeTagId = _scopeId!;
    if (controller.allJobs.any((job) => job.tagIds.contains(activeTagId))) {
      return;
    }
    setState(() {
      _scope = 'all';
      _scopeId = null;
      _selectedIds.clear();
    });
  }

  Widget _libraryToolbar(BuildContext context) => Row(
    key: const Key('library-toolbar'),
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(
        child: TextField(
          key: const Key('library-search'),
          controller: _searchController,
          onChanged: (value) => _changeView(() => _query = value),
          decoration: InputDecoration(
            hintText: context.strings.t('search_library'),
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    key: const Key('clear-library-search'),
                    tooltip: context.strings.t('clear_search'),
                    onPressed: () {
                      _searchController.clear();
                      _changeView(() => _query = '');
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        ),
      ),
      const SizedBox(width: 12),
      SizedBox(
        key: const Key('library-status-filter'),
        width: 160,
        height: 48,
        child: DropdownButton<String>(
          value: _status,
          isExpanded: true,
          focusColor: Colors.transparent,
          items: [
            DropdownMenuItem(
              value: 'all',
              child: Text(context.strings.t('all_statuses')),
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
          onChanged: (value) => _changeView(() => _status = value ?? 'all'),
        ),
      ),
      const SizedBox(width: 12),
      OutlinedButton.icon(
        key: const Key('toggle-library-selection'),
        onPressed: () => setState(() {
          _selectionMode = !_selectionMode;
          _selectedIds.clear();
        }),
        icon: Icon(
          _selectionMode ? Icons.close_rounded : Icons.checklist_rounded,
        ),
        label: Text(context.strings.t(_selectionMode ? 'done' : 'select')),
      ),
    ],
  );

  void _changeView(VoidCallback update) {
    setState(() {
      update();
      _selectedIds.clear();
    });
  }

  Future<void> _showRenameGroupDialog(
    BuildContext context,
    AppController controller,
    LibraryGroup group,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _OrganizerNameDialog(
        title: context.strings.t('rename_group'),
        initialName: group.name,
        validateName: (name) =>
            controller.libraryGroups.any(
              (candidate) =>
                  candidate.id != group.id &&
                  candidate.name.toLowerCase() == name.toLowerCase(),
            )
            ? context.strings.t('group_name_exists')
            : null,
      ),
    );
    if (name != null) await controller.renameLibraryGroup(group.id, name);
  }

  Future<void> _confirmDeleteGroup(
    BuildContext context,
    AppController controller,
    LibraryGroup group,
  ) async {
    final count = controller.allJobs
        .where((job) => job.groupId == group.id)
        .length;
    final confirmed = await _confirmDeleteOrganizer(
      context,
      title: context.strings.t('delete_group'),
      body: context.strings
          .t('delete_group_body')
          .replaceFirst('{count}', '$count'),
    );
    if (!confirmed) return;
    await controller.deleteLibraryGroup(group.id);
    if (mounted && _scope == 'group' && _scopeId == group.id) {
      setState(() {
        _scope = 'all';
        _scopeId = null;
      });
    }
  }

  Future<bool> _confirmDeleteOrganizer(
    BuildContext context, {
    required String title,
    required String body,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.strings.t('cancel')),
            ),
            FilledButton(
              key: const Key('confirm-delete-organizer'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.strings.t('delete')),
            ),
          ],
        ),
      ) ??
      false;

  bool _matches(TranscriptionJob job, AppController controller) {
    if (_scope == 'unfiled' &&
        controller.libraryGroupById(job.groupId) != null) {
      return false;
    }
    if (_scope == 'group' && job.groupId != _scopeId) return false;
    if (_scope == 'tag' && !job.tagIds.contains(_scopeId)) return false;
    final normalizedQuery = _query.trim().toLowerCase();
    if (normalizedQuery.isNotEmpty) {
      final groupMatches =
          controller
              .libraryGroupById(job.groupId)
              ?.name
              .toLowerCase()
              .contains(normalizedQuery) ??
          false;
      final tagMatches = job.tagIds.any(
        (id) =>
            controller
                .libraryTagById(id)
                ?.name
                .toLowerCase()
                .contains(normalizedQuery) ??
            false,
      );
      if (!job.displayName.toLowerCase().contains(normalizedQuery) &&
          !job.fileName.toLowerCase().contains(normalizedQuery) &&
          !groupMatches &&
          !tagMatches) {
        return false;
      }
    }
    if (_status == 'completed' && job.status != JobStatus.completed) {
      return false;
    }
    if (_status == 'attention' &&
        !job.status.canTranscribe &&
        !job.status.canRetry) {
      return false;
    }
    return true;
  }

  Future<void> _confirmBulkRemove(
    BuildContext context,
    List<TranscriptionJob> jobs,
  ) async {
    final removed = await confirmAndRemoveLibraryJobs(context, jobs);
    if (removed && mounted) setState(_selectedIds.clear);
  }
}

class _LibraryOrganizerSidebar extends StatelessWidget {
  const _LibraryOrganizerSidebar({
    required this.controller,
    required this.scope,
    required this.scopeId,
    required this.onScopeChanged,
    required this.onAddGroup,
    required this.onRenameGroup,
    required this.onDeleteGroup,
  });

  final AppController controller;
  final String scope;
  final String? scopeId;
  final void Function(String scope, String? id) onScopeChanged;
  final VoidCallback onAddGroup;
  final Future<void> Function(LibraryGroup group) onRenameGroup;
  final Future<void> Function(LibraryGroup group) onDeleteGroup;

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      ListTile(
        dense: true,
        selected: scope == 'all',
        leading: const Icon(Icons.library_books_outlined),
        title: Text(context.strings.t('all_items')),
        trailing: Text('${controller.allJobs.length}'),
        onTap: () => onScopeChanged('all', null),
      ),
      ListTile(
        dense: true,
        selected: scope == 'unfiled',
        leading: const Icon(Icons.inbox_outlined),
        title: Text(context.strings.t('unfiled')),
        trailing: Text(
          '${controller.allJobs.where((job) => controller.libraryGroupById(job.groupId) == null).length}',
        ),
        onTap: () => onScopeChanged('unfiled', null),
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.strings.t('groups'),
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            IconButton(
              key: const Key('add-library-group'),
              tooltip: context.strings.t('add_group'),
              onPressed: onAddGroup,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
      ),
      for (final group in controller.libraryGroups)
        ListTile(
          key: ValueKey('library-group-${group.id}'),
          dense: true,
          selected: scope == 'group' && scopeId == group.id,
          leading: const Icon(Icons.folder_outlined),
          title: Text(group.name, overflow: TextOverflow.ellipsis),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${controller.allJobs.where((job) => job.groupId == group.id).length}',
              ),
              PopupMenuButton<String>(
                key: ValueKey('library-group-menu-${group.id}'),
                onSelected: (value) async {
                  if (value == 'rename') await onRenameGroup(group);
                  if (value == 'delete') await onDeleteGroup(group);
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'rename',
                    child: Text(context.strings.t('rename_group')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(context.strings.t('delete_group')),
                  ),
                ],
              ),
            ],
          ),
          onTap: () => onScopeChanged('group', group.id),
        ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          context.strings.t('tags'),
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
      for (final tag in controller.libraryTags)
        if (controller.allJobs.any((job) => job.tagIds.contains(tag.id)))
          ListTile(
            key: ValueKey('library-tag-${tag.id}'),
            dense: true,
            selected: scope == 'tag' && scopeId == tag.id,
            leading: Icon(
              Icons.sell_outlined,
              color: _libraryTagColors(
                context,
                _libraryTagColorIndex(controller.libraryTags, tag.id),
              ).foreground,
            ),
            title: Text(tag.name, overflow: TextOverflow.ellipsis),
            trailing: Text(
              '${controller.allJobs.where((job) => job.tagIds.contains(tag.id)).length}',
            ),
            onTap: () => onScopeChanged('tag', tag.id),
          ),
    ],
  );
}

class _OrganizerNameDialog extends StatefulWidget {
  const _OrganizerNameDialog({
    required this.title,
    this.initialName = '',
    this.validateName,
  });

  final String title;
  final String initialName;
  final String? Function(String name)? validateName;

  @override
  State<_OrganizerNameDialog> createState() => _OrganizerNameDialogState();
}

class _OrganizerNameDialogState extends State<_OrganizerNameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.pop(context, _controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: _formKey,
      child: TextFormField(
        key: const Key('library-organizer-name-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 60,
        decoration: InputDecoration(labelText: context.strings.t('name')),
        validator: (value) {
          final name = value?.trim() ?? '';
          if (name.isEmpty) return context.strings.t('title_required');
          return widget.validateName?.call(name);
        },
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.strings.t('cancel')),
      ),
      FilledButton(
        key: const Key('confirm-library-organizer'),
        onPressed: _submit,
        child: Text(context.strings.t('save')),
      ),
    ],
  );
}

class _LibrarySelectionBar extends StatelessWidget {
  const _LibrarySelectionBar({
    required this.selectedCount,
    required this.visibleJobs,
    required this.onSelectAllVisible,
    required this.onMove,
    required this.onTags,
    required this.onExport,
    required this.onRemove,
  });

  final int selectedCount;
  final List<TranscriptionJob> visibleJobs;
  final VoidCallback onSelectAllVisible;
  final VoidCallback? onMove;
  final VoidCallback? onTags;
  final VoidCallback? onExport;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Row(
    key: const Key('library-selection-bar'),
    children: [
      Text(
        context.strings
            .t('selected_count')
            .replaceFirst('{count}', '$selectedCount'),
      ),
      const SizedBox(width: 12),
      TextButton(
        onPressed: visibleJobs.isEmpty ? null : onSelectAllVisible,
        child: Text(context.strings.t('select_all_visible')),
      ),
      const Spacer(),
      IconButton(
        key: const Key('bulk-tag-library-items'),
        onPressed: onTags,
        tooltip: context.strings.t('manage_tags'),
        icon: const Icon(Icons.sell_outlined),
      ),
      const SizedBox(width: 8),
      IconButton(
        key: const Key('bulk-move-library-items'),
        onPressed: onMove,
        tooltip: context.strings.t('move_to_group'),
        icon: const Icon(Icons.drive_file_move_outline),
      ),
      const SizedBox(width: 8),
      IconButton(
        key: const Key('bulk-export-library-items'),
        onPressed: onExport,
        tooltip: context.strings.t('export'),
        icon: const Icon(Icons.ios_share_rounded),
      ),
      const SizedBox(width: 8),
      IconButton(
        key: const Key('bulk-remove-library-items'),
        onPressed: onRemove,
        tooltip: context.strings.t('remove_selected'),
        icon: const Icon(Icons.delete_outline_rounded),
      ),
    ],
  );
}

class _HistoryListItem extends StatelessWidget {
  const _HistoryListItem({
    required this.job,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectedChanged,
    this.onManageTags,
  });
  final TranscriptionJob job;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool>? onSelectedChanged;
  final Future<void> Function()? onManageTags;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final group = controller.libraryGroupById(job.groupId);
    final tags =
        job.tagIds
            .map(controller.libraryTagById)
            .whereType<LibraryTag>()
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return Padding(
      key: ValueKey('library-history-item-${job.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          if (selectionMode) ...[
            Checkbox(
              key: ValueKey('select-library-item-${job.id}'),
              value: selected,
              onChanged: (value) => onSelectedChanged?.call(value ?? false),
            ),
            const SizedBox(width: 4),
          ],
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
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      job.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (group != null)
                      _LibraryOrganizerPill(
                        icon: Icons.folder_outlined,
                        label: group.name,
                      ),
                    for (final tag in tags)
                      _LibraryOrganizerPill(
                        key: ValueKey('library-item-tag-${job.id}-${tag.id}'),
                        icon: Icons.sell_outlined,
                        label: tag.name,
                        colorIndex: _libraryTagColorIndex(
                          controller.libraryTags,
                          tag.id,
                        ),
                      ),
                  ],
                ),
                if (job.displayTitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    job.fileName,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  '${_formatCreatedAt(context, job.createdAt)} · '
                  '${formatClock(job.metadata?.durationMs ?? 0)} · '
                  '${context.strings.t('job_${job.status.name}')}',
                  key: ValueKey('library-item-summary-${job.id}'),
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
          if (job.status == JobStatus.ready || job.status == JobStatus.failed)
            IconButton(
              key: Key('add-to-inbox-${job.status.name}-job-${job.id}'),
              tooltip: context.strings.t('add_to_inbox_tooltip'),
              onPressed: () => controller.addToInbox(job.id),
              icon: const Icon(Icons.input_rounded),
            ),
          if (job.document != null) ...[
            IconButton(
              key: ValueKey('open-library-job-${job.id}'),
              tooltip: context.strings.t('open'),
              style: IconButton.styleFrom(backgroundColor: Colors.transparent),
              onPressed: () => controller.openInWorkspace(job.id),
              icon: const Icon(Icons.open_in_new_rounded),
            ),
            IconButton(
              key: ValueKey('export-library-job-${job.id}'),
              tooltip: context.strings.t('export'),
              onPressed: () =>
                  showTranscriptExportDialog(context, jobIds: [job.id]),
              icon: const Icon(Icons.ios_share_rounded),
            ),
          ],
          PopupMenuButton<String>(
            key: ValueKey('library-item-menu-${job.id}'),
            onSelected: (value) async {
              switch (value) {
                case 'rename':
                  await _showRenameDialog(context, controller, job);
                case 'move':
                  await _showMoveToGroupDialog(context, controller, [job.id]);
                case 'tags':
                  await onManageTags?.call();
                case 'delete':
                  await confirmAndRemoveLibraryJobs(context, [job]);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'rename',
                child: Text(context.strings.t('rename')),
              ),
              PopupMenuItem(
                value: 'move',
                child: Text(context.strings.t('move_to_group')),
              ),
              PopupMenuItem(
                value: 'tags',
                child: Text(context.strings.t('manage_tags')),
              ),
              PopupMenuItem(
                value: 'delete',
                enabled: !job.isBusy,
                child: Text(context.strings.t('delete_history')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _formatCreatedAt(BuildContext context, DateTime createdAt) {
  final local = createdAt.toLocal();
  final localizations = MaterialLocalizations.of(context);
  final date = localizations.formatShortDate(local);
  final time = localizations.formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return '$date $time';
}

class _LibraryOrganizerPill extends StatelessWidget {
  const _LibraryOrganizerPill({
    super.key,
    required this.icon,
    required this.label,
    this.colorIndex,
  });

  final IconData icon;
  final String label;
  final int? colorIndex;

  @override
  Widget build(BuildContext context) {
    final colors = colorIndex == null
        ? null
        : _libraryTagColors(context, colorIndex!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors?.background,
        border: Border.all(
          color: colors?.border ?? Theme.of(context).colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: colors?.foreground),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: colors?.foreground),
          ),
        ],
      ),
    );
  }
}

class _LibraryTagColors {
  const _LibraryTagColors({
    required this.foreground,
    required this.background,
    required this.border,
  });

  final Color foreground;
  final Color background;
  final Color border;
}

const _lightLibraryTagColors = [
  Color(0xFF6A1B9A),
  Color(0xFF1565C0),
  Color(0xFF00838F),
  Color(0xFF2E7D32),
  Color(0xFFF9A825),
  Color(0xFFC62828),
  Color(0xFFAD1457),
  Color(0xFF4527A0),
  Color(0xFFEF6C00),
  Color(0xFF4E342E),
  Color(0xFF37474F),
  Color(0xFF0277BD),
];

const _darkLibraryTagColors = [
  Color(0xFFCE93D8),
  Color(0xFF90CAF9),
  Color(0xFF4DD0E1),
  Color(0xFFA5D6A7),
  Color(0xFFFFD54F),
  Color(0xFFEF9A9A),
  Color(0xFFF48FB1),
  Color(0xFFB39DDB),
  Color(0xFFFFB74D),
  Color(0xFFBCAAA4),
  Color(0xFFB0BEC5),
  Color(0xFF4FC3F7),
];

int _libraryTagColorIndex(List<LibraryTag> tags, String tagId) {
  final index = tags.indexWhere((tag) => tag.id == tagId);
  return index < 0 ? 0 : index;
}

Color _libraryTagForeground(Brightness brightness, int index) {
  final palette = brightness == Brightness.dark
      ? _darkLibraryTagColors
      : _lightLibraryTagColors;
  if (index >= 0 && index < palette.length) return palette[index];
  final hue = ((index < 0 ? 0 : index) * 137.508) % 360;
  return HSLColor.fromAHSL(
    1,
    hue,
    brightness == Brightness.dark ? 0.42 : 0.58,
    brightness == Brightness.dark ? 0.76 : 0.36,
  ).toColor();
}

_LibraryTagColors _libraryTagColors(BuildContext context, int index) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final foreground = _libraryTagForeground(
    isDark ? Brightness.dark : Brightness.light,
    index,
  );
  return _LibraryTagColors(
    foreground: foreground,
    background: foreground.withValues(alpha: isDark ? 0.20 : 0.10),
    border: foreground.withValues(alpha: isDark ? 0.65 : 0.45),
  );
}

const _unfiledGroupResult = '__unfiled__';

Future<void> _showMoveToGroupDialog(
  BuildContext context,
  AppController controller,
  Iterable<String> jobIds,
) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(context.strings.t('move_to_group')),
      children: [
        SimpleDialogOption(
          key: const ValueKey('move-to-group-unfiled'),
          onPressed: () => Navigator.pop(context, _unfiledGroupResult),
          child: Row(
            children: [
              const Icon(Icons.inbox_outlined),
              const SizedBox(width: 12),
              Text(context.strings.t('unfiled')),
            ],
          ),
        ),
        for (final group in controller.libraryGroups)
          SimpleDialogOption(
            key: ValueKey('move-to-group-${group.id}'),
            onPressed: () => Navigator.pop(context, group.id),
            child: Row(
              children: [
                const Icon(Icons.folder_outlined),
                const SizedBox(width: 12),
                Text(group.name),
              ],
            ),
          ),
      ],
    ),
  );
  if (result == null) return;
  await controller.moveLibraryItems(
    jobIds,
    result == _unfiledGroupResult ? null : result,
  );
}

Future<void> _showManageTagsDialog(
  BuildContext context,
  AppController controller,
  List<TranscriptionJob> jobs,
) async {
  if (jobs.isEmpty) return;
  final changes = await showDialog<_TagChanges>(
    context: context,
    builder: (context) =>
        _ManageTagsDialog(tags: controller.libraryTags, jobs: jobs),
  );
  if (changes == null) return;
  final createdTagIds = <String>{};
  for (final name in changes.newTagNames) {
    createdTagIds.add((await controller.createLibraryTag(name)).id);
  }
  await controller.updateLibraryItemTags(
    jobs.map((job) => job.id),
    addTagIds: {...changes.addTagIds, ...createdTagIds},
    removeTagIds: changes.removeTagIds,
  );
}

class _TagChanges {
  const _TagChanges({
    required this.addTagIds,
    required this.removeTagIds,
    required this.newTagNames,
  });

  final Set<String> addTagIds;
  final Set<String> removeTagIds;
  final List<String> newTagNames;
}

class _ManageTagsDialog extends StatefulWidget {
  const _ManageTagsDialog({required this.tags, required this.jobs});

  final List<LibraryTag> tags;
  final List<TranscriptionJob> jobs;

  @override
  State<_ManageTagsDialog> createState() => _ManageTagsDialogState();
}

class _ManageTagsDialogState extends State<_ManageTagsDialog> {
  late final Map<String, bool?> _values;
  final TextEditingController _newTagController = TextEditingController();
  final List<String> _newTagNames = [];
  String? _newTagError;

  @override
  void initState() {
    super.initState();
    _values = {
      for (final tag in widget.tags)
        tag.id: switch (widget.jobs
            .where((job) => job.tagIds.contains(tag.id))
            .length) {
          0 => false,
          final count when count == widget.jobs.length => true,
          _ => null,
        },
    };
  }

  @override
  void dispose() {
    _newTagController.dispose();
    super.dispose();
  }

  bool _stageNewTag({bool requireName = true}) {
    final name = _newTagController.text.trim();
    if (name.isEmpty) {
      if (requireName) {
        setState(() => _newTagError = context.strings.t('tag_name_required'));
        return false;
      }
      return true;
    }
    if (name.length > 60) {
      setState(() => _newTagError = context.strings.t('tag_name_too_long'));
      return false;
    }
    final normalizedName = name.toLowerCase();
    final duplicate =
        widget.tags.any((tag) => tag.name.toLowerCase() == normalizedName) ||
        _newTagNames.any(
          (candidate) => candidate.toLowerCase() == normalizedName,
        );
    if (duplicate) {
      setState(() => _newTagError = context.strings.t('tag_name_exists'));
      return false;
    }
    setState(() {
      _newTagNames.add(name);
      _newTagController.clear();
      _newTagError = null;
    });
    return true;
  }

  void _submit() {
    if (!_stageNewTag(requireName: false)) return;
    Navigator.pop(
      context,
      _TagChanges(
        addTagIds: {
          for (final entry in _values.entries)
            if (entry.value == true) entry.key,
        },
        removeTagIds: {
          for (final entry in _values.entries)
            if (entry.value == false) entry.key,
        },
        newTagNames: List.unmodifiable(_newTagNames),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.t('manage_tags')),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('new-library-tag-field'),
            controller: _newTagController,
            autofocus: widget.tags.isEmpty,
            maxLength: 60,
            maxLengthEnforcement: MaxLengthEnforcement.none,
            decoration: InputDecoration(
              labelText: context.strings.t('add_tag'),
              errorText: _newTagError,
              suffixIcon: IconButton(
                key: const Key('add-library-tag-in-dialog'),
                tooltip: context.strings.t('add_tag'),
                onPressed: _stageNewTag,
                icon: const Icon(Icons.add_rounded),
              ),
            ),
            onChanged: (_) {
              if (_newTagError != null) {
                setState(() => _newTagError = null);
              }
            },
            onSubmitted: (_) => _stageNewTag(),
          ),
          if (_newTagNames.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final name in _newTagNames)
                  Builder(
                    builder: (context) {
                      final colors = _libraryTagColors(
                        context,
                        widget.tags.length + _newTagNames.indexOf(name),
                      );
                      return InputChip(
                        key: ValueKey('new-library-tag-$name'),
                        avatar: Icon(
                          Icons.sell_outlined,
                          size: 16,
                          color: colors.foreground,
                        ),
                        label: Text(name),
                        labelStyle: TextStyle(color: colors.foreground),
                        backgroundColor: colors.background,
                        side: BorderSide(color: colors.border),
                        deleteIconColor: colors.foreground,
                        onDeleted: () =>
                            setState(() => _newTagNames.remove(name)),
                      );
                    },
                  ),
              ],
            ),
          if (_newTagNames.isNotEmpty) const SizedBox(height: 8),
          if (widget.tags.isEmpty)
            Text(context.strings.t('no_tags'))
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final tag in widget.tags)
                    CheckboxListTile(
                      key: ValueKey('library-tag-option-${tag.id}'),
                      value: _values[tag.id],
                      tristate: true,
                      title: Text(tag.name),
                      activeColor: _libraryTagColors(
                        context,
                        _libraryTagColorIndex(widget.tags, tag.id),
                      ).foreground,
                      secondary: Icon(
                        Icons.sell_outlined,
                        color: _libraryTagColors(
                          context,
                          _libraryTagColorIndex(widget.tags, tag.id),
                        ).foreground,
                      ),
                      onChanged: (_) => setState(() {
                        _values[tag.id] = _values[tag.id] == true
                            ? false
                            : true;
                      }),
                    ),
                ],
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
        key: const Key('confirm-library-tags'),
        onPressed: _submit,
        child: Text(context.strings.t('save')),
      ),
    ],
  );
}

Future<void> _showRenameDialog(
  BuildContext context,
  AppController controller,
  TranscriptionJob job,
) async {
  final title = await showDialog<String>(
    context: context,
    builder: (context) => _RenameLibraryItemDialog(job: job),
  );
  if (title != null) await controller.renameLibraryItem(job.id, title);
}

class _RenameLibraryItemDialog extends StatefulWidget {
  const _RenameLibraryItemDialog({required this.job});

  final TranscriptionJob job;

  @override
  State<_RenameLibraryItemDialog> createState() =>
      _RenameLibraryItemDialogState();
}

class _RenameLibraryItemDialogState extends State<_RenameLibraryItemDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _fieldController;

  @override
  void initState() {
    super.initState();
    _fieldController = TextEditingController(
      text: widget.job.displayTitle ?? widget.job.fileName,
    );
  }

  @override
  void dispose() {
    _fieldController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.pop(context, _fieldController.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.t('rename_library_item')),
    content: Form(
      key: _formKey,
      child: TextFormField(
        key: const Key('rename-library-item-field'),
        controller: _fieldController,
        autofocus: true,
        maxLength: 200,
        decoration: InputDecoration(
          labelText: context.strings.t('display_title'),
        ),
        validator: (value) => value == null || value.trim().isEmpty
            ? context.strings.t('title_required')
            : null,
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      if (widget.job.displayTitle != null)
        TextButton(
          key: const Key('reset-library-item-title'),
          onPressed: () => Navigator.pop(context, ''),
          child: Text(context.strings.t('use_original_filename')),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.strings.t('cancel')),
      ),
      FilledButton(
        key: const Key('confirm-rename-library-item'),
        onPressed: _submit,
        child: Text(context.strings.t('save')),
      ),
    ],
  );
}
