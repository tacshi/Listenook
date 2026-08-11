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
              child: Row(
                children: [
                  Text(
                    context.strings.t('settings'),
                    key: const Key('settings-page-title'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(
                    icon: const Icon(Icons.transcribe_rounded),
                    text: context.strings.t('settings_transcription'),
                  ),
                  Tab(
                    icon: const Icon(Icons.palette_outlined),
                    text: context.strings.t('appearance'),
                  ),
                  Tab(
                    icon: const Icon(Icons.info_outline_rounded),
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
      trailing: controller.keyConfigured
          ? Tooltip(
              key: const Key('soniox-key-status'),
              message: context.strings.t('key_configured'),
              child: const Icon(
                Icons.verified_user_outlined,
                color: Colors.green,
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
          const SizedBox(height: 8),
          SwitchListTile(
            key: const Key('soniox-translation-switch'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(context.strings.t('soniox_translation')),
            subtitle: Text(context.strings.t('soniox_translation_description')),
            value: settings.sonioxTranslation.enabled,
            onChanged: (value) async {
              final error = await controller.updateSonioxTranslation(
                settings.sonioxTranslation.copyWith(enabled: value),
              );
              if (error != null && context.mounted) {
                _showMessage(context.strings.error(error));
              }
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('soniox-translation-target'),
            initialValue: settings.sonioxTranslation.targetLanguage,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: context.strings.t('soniox_translation_target'),
              prefixIcon: const Icon(Icons.language_rounded),
            ),
            items: [
              for (final code in supportedSonioxTranslationLanguageCodes)
                DropdownMenuItem(
                  value: code,
                  child: Text(context.strings.translationLanguageName(code)),
                ),
            ],
            onChanged: settings.sonioxTranslation.enabled
                ? (value) async {
                    if (value == null) return;
                    final error = await controller.updateSonioxTranslation(
                      settings.sonioxTranslation.copyWith(
                        targetLanguage: value,
                      ),
                    );
                    if (error != null && context.mounted) {
                      _showMessage(context.strings.error(error));
                    }
                  }
                : null,
          ),
        ],
      ),
    ),
    if (!settings.sonioxTranslation.enabled)
      _TranslationSettingsSection(
        controller: controller,
        settings: settings.translationSettings,
      ),
  ]);

  Widget _appearanceTab(
    BuildContext context,
    AppController controller,
    AppSettings settings,
  ) => _tabList([
    Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
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

class _TranslationSettingsSection extends StatefulWidget {
  const _TranslationSettingsSection({
    required this.controller,
    required this.settings,
  });

  final AppController controller;
  final TranslationSettings settings;

  @override
  State<_TranslationSettingsSection> createState() =>
      _TranslationSettingsSectionState();
}

class _TranslationSettingsSectionState
    extends State<_TranslationSettingsSection> {
  late TranslationProviderTemplate _provider;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  final _apiKey = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  bool _testing = false;
  bool? _connectionOk;
  List<String> _models = const [];

  @override
  void initState() {
    super.initState();
    _provider = widget.settings.provider;
    _baseUrl = TextEditingController(text: widget.settings.baseUrl);
    _model = TextEditingController(text: widget.settings.model);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  TranslationSettings get _candidate => TranslationSettings(
    provider: _provider,
    baseUrl: _baseUrl.text,
    model: _model.text,
    targetLanguage: widget.settings.targetLanguage,
    autoTranslate: widget.settings.autoTranslate,
  );

  String get _normalizedBaseUrl =>
      _baseUrl.text.trim().replaceFirst(RegExp(r'/+$'), '');

  bool get _sameSavedEndpoint =>
      _normalizedBaseUrl ==
      widget.settings.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');

  bool get _canUseStoredKey =>
      widget.controller.translationKeyConfigured && _sameSavedEndpoint;

  bool get _canTest {
    final validation = _candidate.validationError(requireModel: false);
    if (validation != null) return false;
    return !_candidate.requiresApiKey ||
        _apiKey.text.trim().isNotEmpty ||
        _canUseStoredKey;
  }

  bool get _canSave {
    if (_candidate.validationError() != null) return false;
    if (_matchesSavedConfiguration && _apiKey.text.trim().isEmpty) return false;
    return !_candidate.requiresApiKey ||
        _apiKey.text.trim().isNotEmpty ||
        _canUseStoredKey;
  }

  bool get _matchesSavedConfiguration =>
      _provider == widget.settings.provider &&
      _sameSavedEndpoint &&
      _model.text.trim() == widget.settings.model.trim();

  @override
  Widget build(BuildContext context) {
    final savedConfigurationReady =
        widget.controller.translationConfigured && _matchesSavedConfiguration;
    final statusLabel = _connectionOk == true
        ? context.strings.t('translation_connection_ok')
        : _connectionOk == false
        ? context.strings.t('translation_connection_failed')
        : savedConfigurationReady
        ? context.strings.t('translation_configured')
        : context.strings.t('translation_not_configured');
    return _Section(
      title: context.strings.t('llm_translation'),
      icon: Icons.translate_rounded,
      trailing: Tooltip(
        key: const Key('translation-status'),
        message: statusLabel,
        child: Icon(
          _connectionOk == false
              ? Icons.error_outline_rounded
              : savedConfigurationReady
              ? Icons.check_circle_outline_rounded
              : Icons.settings_outlined,
          color: _connectionOk == false
              ? Theme.of(context).colorScheme.error
              : savedConfigurationReady
              ? Colors.green
              : Theme.of(context).colorScheme.secondary,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyedSubtree(
            key: const Key('translation-provider-template-field'),
            child: DropdownButtonFormField<String>(
              key: ValueKey(_provider),
              initialValue: _provider.name,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: context.strings.t('provider_template'),
                prefixIcon: const Icon(Icons.hub_outlined),
              ),
              items: _providerMenuItems(context),
              onChanged: (value) {
                final provider = _providerByName(value);
                if (provider != null) _applyProvider(provider);
              },
            ),
          ),
          if (_provider == TranslationProviderTemplate.lmStudio ||
              _provider == TranslationProviderTemplate.ollama ||
              _provider == TranslationProviderTemplate.volcengineArk)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                context.strings.translationProviderHelp(_provider),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('translation-base-url-field'),
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            onChanged: _baseUrlChanged,
            decoration: InputDecoration(
              labelText: context.strings.t('base_url'),
            ),
          ),
          const SizedBox(height: 10),
          if (_candidate.requiresApiKey)
            TextField(
              key: const Key('translation-key-field'),
              controller: _apiKey,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              onChanged: (_) => _invalidateTest(clearModel: false),
              decoration: InputDecoration(
                labelText: context.strings.t('api_key'),
                hintText: _canUseStoredKey
                    ? context.strings.t('translation_key_retained_hint')
                    : context.strings.t('translation_key_hint'),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            )
          else
            Row(
              children: [
                const Icon(Icons.computer_rounded, size: 20),
                const SizedBox(width: 8),
                Text(context.strings.t('translation_local_no_key')),
              ],
            ),
          const SizedBox(height: 10),
          _modelField(context),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_candidate.requiresApiKey)
                OutlinedButton.icon(
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null && mounted) {
                      setState(() {
                        _apiKey.text = data!.text!;
                        _connectionOk = null;
                        _models = const [];
                      });
                    }
                  },
                  icon: const Icon(Icons.content_paste_rounded),
                  label: Text(context.strings.t('paste')),
                ),
              FilledButton.icon(
                key: const Key('save-translation-settings'),
                onPressed: _saving || !_canSave ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_rounded),
                label: Text(context.strings.t('save')),
              ),
              OutlinedButton.icon(
                key: const Key('test-translation-settings'),
                onPressed: _testing || !_canTest ? null : _test,
                icon: _testing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check_rounded),
                label: Text(context.strings.t('test')),
              ),
              if (widget.controller.translationKeyConfigured &&
                  _sameSavedEndpoint)
                TextButton.icon(
                  onPressed: widget.controller.removeTranslationApiKey,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(context.strings.t('remove')),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _showPrivacyExplanation,
              icon: const Icon(Icons.privacy_tip_outlined, size: 18),
              label: Text(context.strings.t('translation_privacy_link')),
            ),
          ),
        ],
      ),
    );
  }

  List<DropdownMenuItem<String>> _providerMenuItems(BuildContext context) => [
    _providerItem(context, TranslationProviderTemplate.custom),
    _providerHeader(context, 'provider_popular'),
    _providerItem(context, TranslationProviderTemplate.openAi),
    _providerItem(context, TranslationProviderTemplate.deepSeek),
    _providerItem(context, TranslationProviderTemplate.groq),
    _providerItem(context, TranslationProviderTemplate.nvidiaNim),
    _providerItem(context, TranslationProviderTemplate.togetherAi),
    _providerItem(context, TranslationProviderTemplate.mistralAi),
    _providerHeader(context, 'provider_local'),
    _providerItem(context, TranslationProviderTemplate.lmStudio),
    _providerItem(context, TranslationProviderTemplate.ollama),
    _providerHeader(context, 'provider_other'),
    _providerItem(context, TranslationProviderTemplate.fireworksAi),
    _providerItem(context, TranslationProviderTemplate.perplexity),
    _providerItem(context, TranslationProviderTemplate.volcengineArk),
  ];

  DropdownMenuItem<String> _providerItem(
    BuildContext context,
    TranslationProviderTemplate provider,
  ) => DropdownMenuItem(
    value: provider.name,
    child: Text(context.strings.translationProviderName(provider)),
  );

  DropdownMenuItem<String> _providerHeader(BuildContext context, String key) =>
      DropdownMenuItem(
        value: 'header-$key',
        enabled: false,
        child: Text(
          context.strings.t(key),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.outline,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  TranslationProviderTemplate? _providerByName(String? name) {
    for (final provider in TranslationProviderTemplate.values) {
      if (provider.name == name) return provider;
    }
    return null;
  }

  Widget _modelField(BuildContext context) {
    if (_connectionOk != true) {
      final value = _model.text.trim();
      return InputDecorator(
        key: const Key('translation-model-field'),
        decoration: InputDecoration(
          labelText: context.strings.t('model'),
          prefixIcon: const Icon(Icons.lock_outline_rounded),
        ),
        child: Text(
          value.isEmpty
              ? context.strings.t('translation_test_to_select_model')
              : value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (_models.isEmpty) {
      return TextField(
        key: const Key('translation-model-field'),
        controller: _model,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: context.strings.t('model'),
          hintText: context.strings.t('translation_model_hint'),
        ),
      );
    }
    final selected = _models.contains(_model.text) ? _model.text : null;
    return DropdownButtonFormField<String>(
      key: const Key('translation-model-field'),
      initialValue: selected,
      isExpanded: true,
      menuMaxHeight: 420,
      decoration: InputDecoration(
        labelText: context.strings.t('model'),
        prefixIcon: const Icon(Icons.smart_toy_outlined),
      ),
      hint: Text(context.strings.t('translation_select_model')),
      items: [
        for (final model in _models)
          DropdownMenuItem(
            value: model,
            child: Text(model, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) => setState(() => _model.text = value ?? ''),
    );
  }

  void _applyProvider(TranslationProviderTemplate provider) {
    if (provider == _provider) return;
    setState(() {
      _provider = provider;
      _baseUrl.text = provider.defaultBaseUrl;
      _model.clear();
      _apiKey.clear();
      _models = const [];
      _connectionOk = null;
    });
  }

  void _baseUrlChanged(String value) {
    final inferred = TranslationProviderTemplateX.inferFromBaseUrl(value);
    setState(() {
      _provider = inferred;
      _connectionOk = null;
      _models = const [];
      _model.clear();
    });
  }

  void _invalidateTest({required bool clearModel}) {
    setState(() {
      _connectionOk = null;
      _models = const [];
      if (clearModel) _model.clear();
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final error = await widget.controller.saveTranslationConfiguration(
        _candidate,
        apiKey: _apiKey.text,
      );
      if (!mounted) return;
      if (error == null) {
        _apiKey.clear();
        _message(context.strings.t('translation_saved'));
      } else {
        _message(context.strings.error(error));
      }
    } on Object {
      if (mounted) _message(context.strings.t('key_save_failed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    final result = await widget.controller.testTranslationConfiguration(
      _candidate,
      candidateApiKey: _apiKey.text,
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _connectionOk = result.errorCode == null;
      _models = result.errorCode == null ? result.models : const [];
      if (result.errorCode == null &&
          result.models.isNotEmpty &&
          !result.models.contains(_model.text)) {
        _model.clear();
      }
    });
    _message(
      result.errorCode == null
          ? result.models.isEmpty
                ? context.strings.t('translation_connection_no_models')
                : context.strings.t('translation_connection_ok')
          : context.strings.error(result.errorCode),
    );
  }

  Future<void> _showPrivacyExplanation() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.strings.t('translation_privacy_title')),
      content: Text(context.strings.t('translation_privacy_body')),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.strings.t('continue')),
        ),
      ],
    ),
  );

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

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
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 12), trailing!],
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
