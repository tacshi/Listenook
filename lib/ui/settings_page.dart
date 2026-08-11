import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _key = TextEditingController();
  bool _obscure = true;
  bool _savingKey = false;
  bool _testingKey = false;

  bool get _hasCandidateKey => _key.text.trim().isNotEmpty;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final settings = controller.settings;
    return SafeArea(
      child: DefaultTabController(
        length: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                context.strings.t('settings'),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(
                    icon: const Icon(Icons.tune_rounded),
                    text: context.strings.t('settings_transcription'),
                  ),
                  Tab(
                    icon: const Icon(Icons.palette_outlined),
                    text: context.strings.t('appearance'),
                  ),
                  Tab(
                    icon: const Icon(Icons.memory_rounded),
                    text: context.strings.t('settings_system_about'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  _transcriptionTab(context, controller, settings),
                  _appearanceTab(context, controller, settings),
                  _systemTab(context, controller),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabList(List<Widget> children) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
    children: children,
  );

  Widget _transcriptionTab(
    BuildContext context,
    AppController controller,
    AppSettings settings,
  ) => _tabList([
    _Section(
      title: context.strings.t('soniox_key'),
      icon: Icons.key_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.keyConfigured)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const Icon(Icons.verified_user_outlined, color: Colors.green),
                  const SizedBox(width: 8),
                  Text(context.strings.t('key_configured')),
                ],
              ),
            ),
          TextField(
            key: const Key('soniox-key-field'),
            controller: _key,
            obscureText: _obscure,
            enableSuggestions: false,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: context.strings.t('key_hint'),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null && mounted) {
                    setState(() => _key.text = data!.text!);
                  }
                },
                icon: const Icon(Icons.content_paste_rounded),
                label: Text(context.strings.t('paste')),
              ),
              FilledButton.icon(
                key: const Key('save-soniox-key'),
                onPressed: _hasCandidateKey && !_savingKey
                    ? () => _saveKey(controller)
                    : null,
                icon: _savingKey
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.lock_rounded),
                label: Text(context.strings.t('save')),
              ),
              OutlinedButton.icon(
                key: const Key('test-soniox-key'),
                onPressed:
                    (controller.keyConfigured || _hasCandidateKey) &&
                        !_testingKey
                    ? () => _testKey(controller)
                    : null,
                icon: _testingKey
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check_rounded),
                label: Text(context.strings.t('test')),
              ),
              if (controller.keyConfigured)
                TextButton.icon(
                  onPressed: controller.removeApiKey,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(context.strings.t('remove')),
                ),
            ],
          ),
        ],
      ),
    ),
    _Section(
      title: context.strings.t('details'),
      icon: Icons.tune_rounded,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(context.strings.t('concurrency'))),
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
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(context.strings.t('speaker_labels')),
            value: settings.showSpeakers,
            onChanged: (value) => controller.updateSettings(
              settings.copyWith(showSpeakers: value),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(context.strings.t('timestamps')),
            value: settings.showTimestamps,
            onChanged: (value) => controller.updateSettings(
              settings.copyWith(showTimestamps: value),
            ),
          ),
        ],
      ),
    ),
  ]);

  Widget _appearanceTab(
    BuildContext context,
    AppController controller,
    AppSettings settings,
  ) => _tabList([
    _Section(
      title: context.strings.t('appearance'),
      icon: Icons.palette_outlined,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(context.strings.t('theme'))),
              DropdownButton<AppThemeMode>(
                value: settings.themeMode,
                items: [
                  DropdownMenuItem(
                    value: AppThemeMode.system,
                    child: Text(context.strings.t('system')),
                  ),
                  DropdownMenuItem(
                    value: AppThemeMode.light,
                    child: Text(context.strings.t('light')),
                  ),
                  DropdownMenuItem(
                    value: AppThemeMode.dark,
                    child: Text(context.strings.t('dark')),
                  ),
                ],
                onChanged: (value) => controller.updateSettings(
                  settings.copyWith(themeMode: value),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(child: Text(context.strings.t('locale'))),
              DropdownButton<AppLocaleMode>(
                value: settings.localeMode,
                items: [
                  DropdownMenuItem(
                    value: AppLocaleMode.system,
                    child: Text(context.strings.t('system')),
                  ),
                  DropdownMenuItem(
                    value: AppLocaleMode.english,
                    child: Text(context.strings.t('english')),
                  ),
                  DropdownMenuItem(
                    value: AppLocaleMode.simplifiedChinese,
                    child: Text(context.strings.t('chinese')),
                  ),
                ],
                onChanged: (value) => controller.updateSettings(
                  settings.copyWith(localeMode: value),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  ]);

  Widget _systemTab(BuildContext context, AppController controller) =>
      _tabList([
        _Section(
          title: context.strings.t('ffmpeg'),
          icon: Icons.memory_rounded,
          child: Row(
            children: [
              Icon(
                controller.mediaDiagnostics?.available == true
                    ? Icons.check_circle_rounded
                    : Icons.warning_amber_rounded,
                color: controller.mediaDiagnostics?.available == true
                    ? Colors.green
                    : Colors.orange,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.mediaDiagnostics?.available == true
                          ? context.strings.t('available')
                          : context.strings.t('unavailable'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      controller.mediaDiagnostics?.version ??
                          (controller.mediaDiagnostics == null
                              ? context.strings.t('checking')
                              : context.strings.error(
                                  controller.mediaDiagnostics?.errorCode,
                                  englishFallback:
                                      controller.mediaDiagnostics?.error,
                                )),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: controller.refreshMediaDiagnostics,
                child: Text(context.strings.t('refresh')),
              ),
            ],
          ),
        ),
        _Section(
          title: context.strings.t('privacy'),
          icon: Icons.shield_outlined,
          child: Text(context.strings.t('privacy_body')),
        ),
        _Section(
          title: context.strings.t('notices'),
          icon: Icons.article_outlined,
          child: Text(context.strings.t('notices_body')),
        ),
      ]);

  Future<void> _saveKey(AppController controller) async {
    final candidate = _key.text.trim();
    if (candidate.isEmpty || _savingKey) return;
    setState(() => _savingKey = true);
    try {
      await controller.saveApiKey(candidate);
      if (!mounted) return;
      _key.clear();
      _showMessage(context.strings.t('key_saved'));
    } on Object {
      if (mounted) _showMessage(context.strings.t('key_save_failed'));
    } finally {
      if (mounted) setState(() => _savingKey = false);
    }
  }

  Future<void> _testKey(AppController controller) async {
    if (_testingKey) return;
    setState(() => _testingKey = true);
    final candidate = _key.text.trim();
    final errorCode = await controller.testApiKey(
      candidate.isEmpty ? null : candidate,
    );
    if (mounted) {
      if (errorCode == null) {
        _showMessage(context.strings.t('key_valid'));
      } else {
        _showMessage(context.strings.error(errorCode));
      }
      setState(() => _testingKey = false);
    }
  }

  void _showMessage(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
  });
  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    ),
  );
}
