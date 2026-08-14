import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../data/desktop_runtime.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';

Future<bool?> showInboxMonitorSetupDialog(BuildContext context) =>
    showDialog<bool>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<AppController>(),
        child: const InboxMonitorSetupDialog(),
      ),
    );

class InboxMonitorSetupDialog extends StatefulWidget {
  const InboxMonitorSetupDialog({super.key});

  @override
  State<InboxMonitorSetupDialog> createState() =>
      _InboxMonitorSetupDialogState();
}

class _InboxMonitorSetupDialogState extends State<InboxMonitorSetupDialog> {
  static const _audioExtensions = ['mp3', 'wav', 'm4a', 'ogg'];
  static const _videoExtensions = ['mp4', 'mkv', 'avi'];

  String _folderPath = '';
  Set<String> _extensions = Set.of(supportedMonitoredMediaExtensions);
  bool _seeded = false;
  bool _saving = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    final config = context.read<AppController>().inboxMonitorConfig;
    _folderPath = config.folderPath;
    _extensions = Set.of(config.extensions);
    _seeded = true;
  }

  Future<void> _chooseFolder() async {
    final selected = await getDirectoryPath();
    if (selected == null || !mounted) return;
    setState(() {
      _folderPath = selected;
      _error = null;
    });
  }

  void _toggle(String extension) {
    setState(() {
      if (!_extensions.remove(extension)) _extensions.add(extension);
      _error = null;
    });
  }

  void _selectGroup(List<String> extensions) {
    setState(() {
      if (extensions.every(_extensions.contains)) {
        _extensions.removeAll(extensions);
      } else {
        _extensions.addAll(extensions);
      }
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_folderPath.trim().isEmpty) {
      setState(
        () => _error = context.strings.t('inbox_monitor_folder_required'),
      );
      return;
    }
    if (_extensions.isEmpty) {
      setState(
        () => _error = context.strings.t('inbox_monitor_file_type_required'),
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final controller = context.read<AppController>();
      final desktopRuntime = Provider.of<DesktopRuntime?>(
        context,
        listen: false,
      );
      await controller.configureInboxMonitor(
        folderPath: _folderPath,
        extensions: _extensions,
        launchAtLogin: controller.inboxMonitorConfig.launchAtLogin,
      );
      await desktopRuntime?.requestNotificationPermission();
      if (mounted) Navigator.pop(context, true);
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = context.strings.t('inbox_monitor_folder_required');
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('inbox-monitor-setup-dialog'),
    icon: const Icon(Icons.drive_folder_upload_outlined),
    title: Text(context.strings.t('inbox_monitor_setup_title')),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.strings.t('inbox_monitor_body')),
            const SizedBox(height: 16),
            InputDecorator(
              decoration: InputDecoration(
                labelText: context.strings.t('inbox_monitor_folder'),
                prefixIcon: const Icon(Icons.folder_outlined),
                errorText: _error,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _folderPath.isEmpty
                          ? context.strings.t('inbox_monitor_not_configured')
                          : _folderPath,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const Key('inbox-monitor-folder-picker'),
                    onPressed: _saving ? null : _chooseFolder,
                    child: Text(
                      context.strings.t(
                        _folderPath.isEmpty
                            ? 'inbox_monitor_choose_folder'
                            : 'inbox_monitor_change_folder',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.strings.t('inbox_monitor_recursive_hint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 18),
            _ExtensionGroup(
              title: context.strings.t('inbox_monitor_audio_types'),
              extensions: _audioExtensions,
              selected: _extensions,
              onToggle: _toggle,
              onSelectAll: () => _selectGroup(_audioExtensions),
            ),
            const SizedBox(height: 14),
            _ExtensionGroup(
              title: context.strings.t('inbox_monitor_video_types'),
              extensions: _videoExtensions,
              selected: _extensions,
              onToggle: _toggle,
              onSelectAll: () => _selectGroup(_videoExtensions),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.verified_user_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.strings.t('inbox_monitor_review_hint'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context, false),
        child: Text(context.strings.t('cancel')),
      ),
      FilledButton(
        key: const Key('inbox-monitor-save'),
        onPressed: _saving ? null : _save,
        child: _saving
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(context.strings.t('save')),
      ),
    ],
  );
}

class _ExtensionGroup extends StatelessWidget {
  const _ExtensionGroup({
    required this.title,
    required this.extensions,
    required this.selected,
    required this.onToggle,
    required this.onSelectAll,
  });

  final String title;
  final List<String> extensions;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: onSelectAll,
            child: Text(context.strings.t('inbox_monitor_select_all')),
          ),
        ],
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final extension in extensions)
            FilterChip(
              key: ValueKey('inbox-monitor-extension-$extension'),
              label: Text(extension.toUpperCase()),
              selected: selected.contains(extension),
              onSelected: (_) => onToggle(extension),
            ),
        ],
      ),
    ],
  );
}
