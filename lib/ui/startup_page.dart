import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../data/app_data_migration.dart';
import '../data/migrating_secure_value.dart';
import '../l10n/strings.dart';

class ListenookBootstrap extends StatefulWidget {
  const ListenookBootstrap({
    super.key,
    required this.application,
    this.restart,
    this.progress,
    this.locale,
  });
  final Future<Widget> application;
  final Future<Widget> Function()? restart;
  final ValueListenable<double?>? progress;
  final ValueListenable<Locale>? locale;

  @override
  State<ListenookBootstrap> createState() => _ListenookBootstrapState();
}

class _ListenookBootstrapState extends State<ListenookBootstrap> {
  late Future<Widget> _application = widget.application;
  final _fields = <TextEditingController>[];
  bool _editingKeys = false;
  bool _saving = false;
  bool _saveFailed = false;

  @override
  void initState() {
    super.initState();
    widget.progress?.addListener(_changed);
    widget.locale?.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.progress?.removeListener(_changed);
    widget.locale?.removeListener(_changed);
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  void _retry() {
    final restart = widget.restart;
    if (restart == null) return;
    for (final field in _fields) {
      field.dispose();
    }
    _fields.clear();
    setState(() {
      _editingKeys = false;
      _saveFailed = false;
      _application = restart();
    });
  }

  Future<void> _saveKeys(CredentialMigrationException error) async {
    if (_fields.any((field) => field.text.trim().isEmpty)) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      for (var i = 0; i < error.targets.length; i++) {
        await error.targets[i].write(_fields[i].text.trim());
      }
      if (mounted) _retry();
    } on Object {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale =
        widget.locale?.value ??
        WidgetsBinding.instance.platformDispatcher.locale;
    final strings = AppStrings(locale);
    return FutureBuilder<Widget>(
      future: _application,
      builder: (context, state) {
        if (state.hasData) return state.data!;
        final error = state.error;
        return MaterialApp(
          title: strings.appName,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff7439ce),
            ),
          ),
          home: Scaffold(
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (state.hasError) ...[
                          Text(
                            strings.t(
                              error is AppMigrationException
                                  ? error.code
                                  : 'startup_failed',
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          if (_editingKeys &&
                              error is CredentialMigrationException) ...[
                            for (var i = 0; i < error.targets.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: TextField(
                                  controller: _fields[i],
                                  obscureText: true,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  decoration: InputDecoration(
                                    labelText:
                                        '${error.targets[i].name} API Key',
                                  ),
                                ),
                              ),
                            if (_saveFailed)
                              Text(strings.t('migration_key_save_failed')),
                            FilledButton(
                              onPressed: _saving
                                  ? null
                                  : () => _saveKeys(error),
                              child: Text(strings.t('migration_save_continue')),
                            ),
                          ] else ...[
                            if (widget.restart != null)
                              FilledButton(
                                onPressed: _retry,
                                child: Text(strings.t('retry')),
                              ),
                            if (error is CredentialMigrationException)
                              TextButton(
                                onPressed: () => setState(() {
                                  _editingKeys = true;
                                  _fields.addAll(
                                    error.targets.map(
                                      (_) => TextEditingController(),
                                    ),
                                  );
                                }),
                                child: Text(strings.t('migration_enter_keys')),
                              ),
                          ],
                        ] else ...[
                          const Icon(
                            Icons.graphic_eq_rounded,
                            size: 52,
                            color: Color(0xff7439ce),
                          ),
                          const SizedBox(height: 20),
                          CircularProgressIndicator(
                            value: widget.progress?.value,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            strings.t(
                              widget.progress?.value == null
                                  ? 'startup_loading'
                                  : 'migration_loading',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
