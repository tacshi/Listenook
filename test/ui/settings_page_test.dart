import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:listenook/core/contracts.dart';
import 'package:listenook/core/local_speech.dart';
import 'package:listenook/core/models.dart';
import 'package:listenook/core/update_models.dart';
import 'package:listenook/data/local_media_source_resolver.dart';
import 'package:listenook/data/transcript_exporter.dart';
import 'package:listenook/data/update_installer.dart';
import 'package:listenook/data/update_service.dart';
import 'package:listenook/l10n/strings.dart';
import 'package:listenook/state/app_controller.dart';
import 'package:listenook/ui/settings_page.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('configured Inbox monitor can return to no-folder state', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'meow-settings-remove-monitor-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.runAsync(
      () => controller.configureInboxMonitor(
        folderPath: directory.path,
        extensions: const {'wav'},
        launchAtLogin: false,
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: SettingsPage()),
        ),
      ),
    );

    final removeFolder = find.byKey(
      const Key('settings-inbox-monitor-remove-folder'),
    );
    await tester.ensureVisible(removeFolder);
    await tester.pumpAndSettle();
    await tester.tap(removeFolder);
    await tester.pump();
    await tester.pump();

    expect(controller.inboxMonitorConfigured, isFalse);
    expect(find.text('Inbox folder is not configured.'), findsOneWidget);
    expect(
      find.byKey(const Key('settings-inbox-monitor-remove-folder')),
      findsNothing,
    );
  });

  testWidgets('stored API keys have no reveal controls', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final credentials = _Credentials()..value = 'soniox-secret';
    final mossCredentials = _Credentials()..value = 'moss-secret';
    final translationCredentials = _TranslationCredentials()
      ..value = 'translation-secret';
    final controller = AppController(
      credentialStore: credentials,
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      mossCredentialStore: mossCredentials,
      mossClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      translationCredentialStore: translationCredentials,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.tap(find.text('Transcription'));
    await tester.pumpAndSettle();

    final sonioxKeyField = tester.widget<TextField>(
      find.byKey(const Key('soniox-key-field')),
    );
    expect(sonioxKeyField.obscureText, isTrue);
    expect(sonioxKeyField.controller?.text, isEmpty);
    expect(sonioxKeyField.decoration?.hintText, '••••••••••••••••');
    expect(sonioxKeyField.decoration?.hintText, isNot(contains('soniox_')));
    expect(sonioxKeyField.decoration?.suffixIcon, isNull);
    expect(find.byKey(const Key('moss-key-field')), findsNothing);

    await _selectDefaultProvider(tester, 'MOSS Pro');
    expect(find.byKey(const Key('soniox-key-field')), findsNothing);
    final mossKeyFinder = find.byKey(const Key('moss-key-field'));
    final mossKeyField = tester.widget<TextField>(mossKeyFinder);
    expect(mossKeyField.obscureText, isTrue);
    expect(mossKeyField.controller?.text, isEmpty);
    expect(mossKeyField.decoration?.hintText, '••••••••••••••••');
    expect(mossKeyField.decoration?.suffixIcon, isNull);

    expect(find.byKey(const Key('translation-key-field')), findsNothing);
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    final translationKeyFinder = find.byKey(const Key('translation-key-field'));
    final translationKeyField = tester.widget<TextField>(translationKeyFinder);
    expect(translationKeyField.obscureText, isTrue);
    expect(translationKeyField.controller?.text, isEmpty);
    expect(translationKeyField.decoration?.labelText, isNull);
    expect(translationKeyField.decoration?.hintText, '••••••••••••••••');
    expect(translationKeyField.decoration?.suffixIcon, isNull);
  });

  testWidgets(
    'provider dropdown changes the default and retains credential drafts',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = _Settings()
        ..value = const AppSettings(
          defaultTranscriptionProvider: TranscriptionProvider.mossPro,
        );
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: settings,
        jobRepository: _Jobs(),
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: _Soniox(),
        mossCredentialStore: _Credentials(),
        mossClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await tester.tap(find.text('Transcription'));
      await tester.pumpAndSettle();

      final providerDropdown = find.byKey(
        const Key('default-transcription-provider'),
      );
      expect(providerDropdown, findsOneWidget);
      expect(
        tester
            .widget<DropdownButtonFormField<TranscriptionProvider>>(
              providerDropdown,
            )
            .initialValue,
        TranscriptionProvider.mossPro,
      );
      expect(find.byKey(const Key('moss-key-field')), findsOneWidget);
      expect(find.byKey(const Key('soniox-key-field')), findsNothing);
      expect(find.text('Soniox built-in translation'), findsNothing);
      expect(
        find.textContaining('MOSS-Transcribe-Diarize-Pro'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('moss-key-field')),
        'moss-draft',
      );

      await _selectDefaultProvider(tester, 'Soniox');
      expect(
        controller.settings.defaultTranscriptionProvider,
        TranscriptionProvider.soniox,
      );
      expect(find.byKey(const Key('moss-key-field')), findsNothing);
      expect(find.byKey(const Key('soniox-key-field')), findsOneWidget);
      expect(find.text('Soniox built-in translation'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('soniox-key-field')),
        'soniox-draft',
      );
      expect(
        settings.value.defaultTranscriptionProvider,
        TranscriptionProvider.soniox,
      );
      expect(find.text('Set as default'), findsNothing);
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);

      await _selectDefaultProvider(tester, 'MOSS Pro');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('moss-key-field')))
            .controller
            ?.text,
        'moss-draft',
      );
      await _selectDefaultProvider(tester, 'Soniox');
      expect(find.byKey(const Key('moss-key-field')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('soniox-key-field')))
            .controller
            ?.text,
        'soniox-draft',
      );

      expect(find.byKey(const Key('translation-key-field')), findsNothing);
      await tester.tap(find.text('AI'));
      await tester.pumpAndSettle();
      expect(find.text('AI provider'), findsOneWidget);
    },
  );

  testWidgets('provider dropdown shows only relevant local model settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = _Settings();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: settings,
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      localSttService: _SupportedLocalStt(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: SettingsPage()),
        ),
      ),
    );
    final destinations = [
      'General',
      'Transcription',
      'Word Timing',
      'AI',
      'Shortcuts',
      'About',
    ];
    for (final destination in destinations) {
      expect(find.text(destination), findsOneWidget);
    }
    for (var index = 1; index < destinations.length; index++) {
      expect(
        tester.getCenter(find.text(destinations[index - 1])).dx,
        lessThan(tester.getCenter(find.text(destinations[index])).dx),
      );
    }
    await tester.tap(find.text('Transcription'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('default-transcription-provider')));
    await tester.pumpAndSettle();
    expect(find.text('MOSS Local'), findsOneWidget);
    expect(find.text('Qwen3 Local (Beta)'), findsOneWidget);
    expect(find.text('AI provider'), findsNothing);
    expect(
      find.byKey(
        const Key('download-model-moss-transcribe-diarize-0.9b-coreml-int8'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const Key('download-model-qwen3-asr-1.7b-mlx-8bit-bundle')),
      findsNothing,
    );
    expect(find.byKey(const Key('automatic-word-timing-switch')), findsNothing);
    final autoTranscribe = find.byKey(
      const Key('auto-transcribe-local-switch'),
    );
    expect(autoTranscribe, findsOneWidget);
    expect(tester.widget<Switch>(autoTranscribe).value, isFalse);

    await tester.tap(find.text('MOSS Local'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key('download-model-moss-transcribe-diarize-0.9b-coreml-int8'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('download-model-qwen3-asr-1.7b-mlx-8bit-bundle')),
      findsNothing,
    );
    expect(
      find.byKey(
        const Key('download-model-qwen3-forced-aligner-0.6b-coreml-int8'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        const Key('download-model-qwen3-forced-aligner-0.6b-coreml-fp16'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const Key('default-forced-alignment-model')),
      findsNothing,
    );
    expect(autoTranscribe, findsOneWidget);
    expect(find.text('Automatic transcription'), findsOneWidget);
    expect(
      find.textContaining('Files dropped into Inbox still require'),
      findsOneWidget,
    );

    await _selectDefaultProvider(tester, 'Qwen3 Local (Beta)');
    expect(
      find.byKey(
        const Key('download-model-moss-transcribe-diarize-0.9b-coreml-int8'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const Key('download-model-qwen3-asr-1.7b-mlx-8bit-bundle')),
      findsOneWidget,
    );
    expect(
      find.textContaining('Local multilingual transcription'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Speaker labels are unavailable'),
      findsOneWidget,
    );

    await tester.tap(autoTranscribe);
    await tester.pumpAndSettle();

    expect(controller.settings.autoTranscribeLocal, isTrue);
    expect(settings.value.autoTranscribeLocal, isTrue);

    await _selectDefaultProvider(tester, 'MOSS Pro');
    expect(
      find.byKey(
        const Key('download-model-moss-transcribe-diarize-0.9b-coreml-int8'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const Key('download-model-qwen3-asr-1.7b-mlx-8bit-bundle')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('auto-transcribe-local-switch')),
      findsOneWidget,
    );

    await tester.tap(find.text('Word Timing'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('default-transcription-provider')),
      findsNothing,
    );
    expect(find.byKey(const Key('auto-transcribe-local-switch')), findsNothing);
    expect(
      find.byKey(
        const Key('download-model-moss-transcribe-diarize-0.9b-coreml-int8'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const Key('download-model-qwen3-asr-1.7b-mlx-8bit-bundle')),
      findsNothing,
    );
    expect(
      find.byKey(
        const Key('download-model-qwen3-forced-aligner-0.6b-coreml-int8'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('download-model-qwen3-forced-aligner-0.6b-coreml-fp16'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('default-forced-alignment-model')),
      findsOneWidget,
    );
    final automaticTiming = find.byKey(
      const Key('automatic-word-timing-switch'),
    );
    expect(automaticTiming, findsOneWidget);
    expect(tester.widget<SwitchListTile>(automaticTiming).value, isTrue);
    expect(
      find.textContaining('Install an alignment model below'),
      findsOneWidget,
    );
    await tester.tap(automaticTiming);
    await tester.pumpAndSettle();
    expect(controller.settings.automaticWordTiming, isFalse);
    expect(settings.value.automaticWordTiming, isFalse);

    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(find.text('AI provider'), findsOneWidget);
    expect(
      find.byKey(const Key('default-forced-alignment-model')),
      findsNothing,
    );
  });

  testWidgets('compact settings tabs scroll and support keyboard navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      localSttService: _SupportedLocalStt(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final compactThemeSelector = find.byKey(
      const Key('settings-theme-selector'),
    );
    final compactLanguageSelector = find.byKey(
      const Key('settings-language-selector'),
    );
    expect(
      tester.getTopLeft(compactThemeSelector).dy,
      lessThan(tester.getTopLeft(compactLanguageSelector).dy),
    );
    expect(
      tester.getSize(compactThemeSelector).width,
      closeTo(tester.getSize(compactLanguageSelector).width, 0.1),
    );
    final transcriptionTab = find.byKey(
      const Key('settings-tab-transcription'),
    );
    await tester.tap(transcriptionTab);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('default-transcription-provider')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    final transcriptionTabFocus = Focus.of(tester.element(transcriptionTab));
    transcriptionTabFocus.requestFocus();
    await tester.pump();
    expect(transcriptionTabFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('automatic-word-timing-switch')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.byKey(const Key('settings-tab-about')));
    await tester.tap(find.byKey(const Key('settings-tab-about')));
    await tester.pumpAndSettle();
    expect(find.text('Privacy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an installed FP16 aligner can be selected and persisted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = _Settings();
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: settings,
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
      localModelManager: _UiModels(),
      localSttService: _SupportedLocalStt(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [AppStrings.delegate],
          home: Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.tap(find.text('Word Timing'));
    await tester.pumpAndSettle();
    expect(
      find.text('Choose an installed default alignment model below.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('default-forced-alignment-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Qwen3 word alignment — FP16').last);
    await tester.pumpAndSettle();

    expect(
      controller.settings.defaultForcedAlignmentModel,
      ForcedAlignmentModel.qwen3CoreMlFp16,
    );
    expect(
      settings.value.defaultForcedAlignmentModel,
      ForcedAlignmentModel.qwen3CoreMlFp16,
    );
    expect(
      find.text('Choose an installed default alignment model below.'),
      findsNothing,
    );
  });

  testWidgets('an unsaved Soniox key can be tested and then saved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Uri? launchedUrl;
    final credentials = _Credentials();
    final soniox = _Soniox();
    final controller = AppController(
      credentialStore: credentials,
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: soniox,
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: SettingsPage(
              launchExternalUrl: (url) async {
                launchedUrl = url;
                return true;
              },
            ),
          ),
        ),
      ),
    );

    final pageTitle = find.byKey(const Key('settings-page-title'));
    expect(
      tester.widget<Text>(pageTitle).style?.fontSize,
      Theme.of(tester.element(pageTitle)).textTheme.titleLarge?.fontSize,
    );
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Transcription'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('Word Timing'), findsNothing);
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Shortcuts'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
    expect(find.byIcon(Icons.palette_outlined), findsNothing);
    expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    expect(find.text('Theme').hitTestable(), findsOneWidget);
    expect(find.text('Language').hitTestable(), findsOneWidget);
    final themeSelector = find.byKey(const Key('settings-theme-selector'));
    final languageSelector = find.byKey(
      const Key('settings-language-selector'),
    );
    expect(
      tester.getTopLeft(themeSelector).dy,
      closeTo(tester.getTopLeft(languageSelector).dy, 0.1),
    );
    expect(tester.getSize(themeSelector).width, greaterThan(300));
    expect(
      tester.getSize(themeSelector).width,
      closeTo(tester.getSize(languageSelector).width, 0.1),
    );
    expect(find.text('Batch options'), findsNothing);
    expect(find.text('Concurrent jobs'), findsNothing);
    expect(find.text('Inbox monitoring').hitTestable(), findsOneWidget);
    expect(find.text('Background'), findsNothing);
    expect(find.text('Show menu bar icon'), findsOneWidget);
    expect(
      find.text('Keeps Listenook available after its window is closed.'),
      findsOneWidget,
    );
    expect(find.text('Starts hidden in the menu bar.'), findsOneWidget);
    final traySetting = find.byKey(const Key('settings-show-tray-icon'));
    final traySwitch = find.descendant(
      of: traySetting,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(traySwitch).value, isTrue);
    expect(tester.widget<Switch>(traySwitch).onChanged, isNotNull);
    await tester.tap(traySwitch);
    await tester.pumpAndSettle();
    expect(controller.inboxMonitorConfig.showTrayIcon, isFalse);
    expect(find.text('Starts hidden in the menu bar.'), findsNothing);
    final startupSetting = find.byKey(const Key('settings-launch-at-login'));
    final startupSwitch = tester.widget<Switch>(
      find.descendant(of: startupSetting, matching: find.byType(Switch)),
    );
    expect(startupSwitch.onChanged, isNotNull);
    final startupTitle = tester.widget<Text>(
      find.text('Launch Listenook at login'),
    );
    final themeTitle = tester.widget<Text>(find.text('Theme'));
    final languageTitle = tester.widget<Text>(find.text('Language'));
    final settingsTheme = Theme.of(tester.element(startupSetting)).textTheme;
    expect(startupTitle.style?.fontSize, settingsTheme.bodyMedium?.fontSize);
    expect(themeTitle.style?.fontSize, startupTitle.style?.fontSize);
    expect(themeTitle.style?.fontWeight, startupTitle.style?.fontWeight);
    expect(languageTitle.style?.fontSize, startupTitle.style?.fontSize);
    expect(languageTitle.style?.fontWeight, startupTitle.style?.fontWeight);
    final menuBarCard = find.ancestor(
      of: find.text('Show menu bar icon'),
      matching: find.byType(Card),
    );
    final startupCard = find.ancestor(
      of: find.text('Launch Listenook at login'),
      matching: find.byType(Card),
    );
    final inboxMonitoringCard = find.ancestor(
      of: find.text('Inbox monitoring'),
      matching: find.byType(Card),
    );
    expect(menuBarCard, findsOneWidget);
    expect(startupCard, findsOneWidget);
    expect(inboxMonitoringCard, findsOneWidget);
    expect(menuBarCard.evaluate().single, same(startupCard.evaluate().single));
    expect(
      tester.getTopLeft(startupCard).dy,
      lessThan(tester.getTopLeft(inboxMonitoringCard).dy),
    );
    await tester.tap(
      find.descendant(of: startupSetting, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(controller.inboxMonitorConfig.launchAtLogin, isTrue);
    expect(find.text('Privacy').hitTestable(), findsNothing);

    await tester.tap(find.text('Transcription'));
    await tester.pumpAndSettle();

    final createKeyLink = find.byKey(const Key('create-soniox-key-link'));
    expect(find.text('Create a Soniox API key'), findsOneWidget);
    final apiKeyTitle = find.text('API key');
    expect(
      (tester.getCenter(createKeyLink).dy - tester.getCenter(apiKeyTitle).dy)
          .abs(),
      lessThanOrEqualTo(1),
    );
    expect(
      tester.getCenter(createKeyLink).dx,
      greaterThan(tester.getCenter(apiKeyTitle).dx),
    );
    expect(
      tester.getCenter(createKeyLink).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('soniox-key-field'))).dy),
    );
    await tester.tap(createKeyLink);
    await tester.pump();
    expect(launchedUrl, Uri.parse('https://console.soniox.com'));

    expect(find.byKey(const Key('session-language-hints-field')), findsNothing);
    expect(find.byKey(const Key('session-context-terms-field')), findsNothing);

    final sonioxSwitch = find.byKey(const Key('soniox-translation-switch'));
    final sonioxTarget = find.byKey(const Key('soniox-translation-target'));
    final targetField = tester.widget<DropdownButtonFormField<String>>(
      sonioxTarget,
    );
    expect(
      tester.getTopLeft(sonioxTarget).dy -
          tester.getBottomLeft(sonioxSwitch).dy,
      greaterThanOrEqualTo(12),
    );
    expect(supportedSonioxTranslationLanguageCodes, hasLength(60));
    expect(supportedSonioxTranslationLanguageCodes, contains('zh'));
    expect(supportedSonioxTranslationLanguageCodes, isNot(contains('yue')));
    expect(supportedSonioxTranslationLanguageCodes, isNot(contains('zh-Hans')));
    expect(targetField.onChanged, isNull);

    await tester.ensureVisible(sonioxSwitch);
    await tester.tap(sonioxSwitch);
    await tester.pumpAndSettle();
    expect(controller.settings.sonioxTranslation.enabled, isTrue);
    expect(
      tester.widget<DropdownButtonFormField<String>>(sonioxTarget).onChanged,
      isNotNull,
    );
    expect(
      find.byKey(const Key('translation-provider-template-field')),
      findsNothing,
    );
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(find.text('AI provider'), findsOneWidget);
    expect(
      find.textContaining('automatic translation, AI Briefs'),
      findsOneWidget,
    );
    await tester.tap(find.text('Transcription'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('soniox-key-field')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('save-soniox-key')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('test-soniox-key')))
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(const Key('soniox-key-field')),
      ' candidate-key ',
    );
    await tester.pump();

    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('test-soniox-key')))
          .onPressed,
      isNotNull,
    );
    await tester.ensureVisible(find.byKey(const Key('test-soniox-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('test-soniox-key')));
    await tester.pumpAndSettle();
    expect(soniox.validatedKey, 'candidate-key');

    await tester.ensureVisible(find.byKey(const Key('save-soniox-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-soniox-key')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(credentials.value, 'candidate-key');
    expect(controller.keyConfigured, isTrue);
    expect(find.text('Soniox key saved securely.'), findsOneWidget);
    expect(find.text('Securely stored on this device'), findsNothing);
    expect(find.byKey(const Key('provider-status-soniox')), findsNothing);

    await tester.tap(find.text('Shortcuts'));
    await tester.pumpAndSettle();
    expect(find.text('Application').hitTestable(), findsOneWidget);
    expect(find.text('Navigation').hitTestable(), findsOneWidget);
    expect(find.text('Playback').hitTestable(), findsOneWidget);
    expect(find.text('Fullscreen playback').hitTestable(), findsOneWidget);
    expect(find.text('Hold to repeat the current sentence'), findsOneWidget);
    for (final id in [
      'open-media',
      'toggle-sidebar',
      'start-ready',
      'workspace',
      'library',
      'settings',
      'hold-repeat',
      'play-pause',
      'seek-backward',
      'seek-forward',
      'decrease-speed',
      'increase-speed',
      'exit-fullscreen',
    ]) {
      expect(find.byKey(ValueKey('shortcut-row-$id')), findsOneWidget);
    }
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('shortcut-row-open-media')),
        matching: find.text('⌘'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.text('Media engine diagnostics'), findsNothing);
    expect(find.text('Inbox monitoring').hitTestable(), findsNothing);
    expect(find.text('Privacy').hitTestable(), findsOneWidget);
    expect(find.text('Third-party notices').hitTestable(), findsOneWidget);
  });

  testWidgets('shortcut tab localizes labels and uses Ctrl off macOS', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );

    expect(find.text('通用'), findsOneWidget);
    expect(find.text('转写'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('词级时间'), findsNothing);
    await tester.tap(find.text('快捷键'));
    await tester.pumpAndSettle();
    expect(find.text('应用').hitTestable(), findsOneWidget);
    expect(find.text('导航').hitTestable(), findsOneWidget);
    expect(find.text('播放').hitTestable(), findsOneWidget);
    expect(find.text('全屏播放').hitTestable(), findsOneWidget);
    expect(find.text('按住以重复当前句'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('shortcut-row-open-media')),
        matching: find.text('Ctrl'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('shortcut-row-play-pause')),
        matching: find.text('空格'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'translation configuration tests unsaved values and stores one key',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final translationCredentials = _TranslationCredentials();
      final translationService = _TranslationService();
      final settings = _Settings();
      final controller = AppController(
        credentialStore: _Credentials(),
        settingsRepository: settings,
        jobRepository: _Jobs(),
        mediaService: _Media(),
        sourceResolver: const LocalMediaSourceResolver(),
        sonioxClient: _Soniox(),
        exporter: const DefaultTranscriptExporter(),
        translationCredentialStore: translationCredentials,
        translationService: translationService,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: AppStrings.supportedLocales,
            localizationsDelegates: [AppStrings.delegate],
            home: Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await tester.tap(find.text('AI'));
      await tester.pumpAndSettle();

      final baseUrl = find.byKey(const Key('translation-base-url-field'));
      final model = find.byKey(const Key('translation-model-field'));
      final key = find.byKey(const Key('translation-key-field'));
      final provider = find.byKey(
        const Key('translation-provider-template-field'),
      );
      await tester.ensureVisible(baseUrl);

      final keyBounds = tester.getRect(key);
      final modelBounds = tester.getRect(model);
      expect(keyBounds.top, closeTo(modelBounds.top, 1));
      expect(keyBounds.bottom, closeTo(modelBounds.bottom, 1));
      expect(keyBounds.right, lessThan(modelBounds.left));

      final emptyTranslationKey = tester.widget<TextField>(key);
      expect(emptyTranslationKey.decoration?.labelText, isNull);
      expect(
        emptyTranslationKey.decoration?.hintText,
        'Required for remote endpoints',
      );

      expect(tester.widget<TextField>(baseUrl).controller?.text, isEmpty);
      expect(
        find.text('Choose a provider and test the connection'),
        findsNothing,
      );
      final translationStatus = find.byKey(const Key('translation-status'));
      expect(
        tester.widget<Tooltip>(translationStatus).message,
        'Choose a provider and test the connection',
      );
      expect(
        tester.getCenter(translationStatus).dx,
        greaterThan(tester.getCenter(find.text('AI provider')).dx),
      );
      expect(
        find.text('Test the connection to select a model'),
        findsOneWidget,
      );

      await tester.ensureVisible(provider);
      await tester.tap(provider);
      await tester.pumpAndSettle();
      expect(find.text('Cloud'), findsOneWidget);
      expect(find.text('Local'), findsOneWidget);
      expect(find.text('Popular'), findsNothing);
      expect(find.text('Other'), findsNothing);
      expect(find.text('OpenRouter'), findsOneWidget);
      expect(find.text('LM Studio'), findsOneWidget);
      expect(find.text('LM Studio (Local)'), findsNothing);
      expect(find.text('Ollama OpenAI API'), findsOneWidget);
      expect(find.text('Ollama OpenAI API (Local)'), findsNothing);
      await tester.tap(find.text('OpenRouter').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(baseUrl).controller?.text,
        'https://openrouter.ai/api/v1',
      );

      await tester.enterText(baseUrl, 'https://example.test/v1/');
      await tester.pump();
      expect(find.text('Custom'), findsOneWidget);
      await tester.enterText(key, 'candidate-secret');
      await tester.pump();
      await tester.tap(find.text('Transcription'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translation-base-url-field')), findsNothing);
      await tester.tap(find.text('AI'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(baseUrl).controller?.text,
        'https://example.test/v1/',
      );
      expect(
        tester.widget<TextField>(key).controller?.text,
        'candidate-secret',
      );
      final testButton = find.byKey(const Key('test-translation-settings'));
      expect(tester.widget<OutlinedButton>(testButton).onPressed, isNotNull);
      await tester.ensureVisible(testButton);
      await tester.tap(testButton);
      await tester.pumpAndSettle();

      expect(translationService.candidateKey, 'candidate-secret');
      expect(
        translationService.testedSettings?.baseUrl,
        'https://example.test/v1',
      );
      expect(translationCredentials.value, isNull);
      expect(find.text('Select a model'), findsOneWidget);

      await tester.ensureVisible(model);
      await tester.tap(model);
      await tester.pumpAndSettle();
      await tester.tap(find.text('suggested-model').last);
      await tester.pumpAndSettle();

      final saveButton = find.byKey(const Key('save-translation-settings'));
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(translationCredentials.value, 'candidate-secret');
      expect(
        settings.value.translationSettings.baseUrl,
        'https://example.test/v1',
      );
      expect(settings.value.translationSettings.model, 'suggested-model');
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);

      await tester.tap(model);
      await tester.pumpAndSettle();
      await tester.tap(find.text('replacement-model').last);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(translationCredentials.value, 'candidate-secret');
      expect(settings.value.translationSettings.model, 'replacement-model');
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);

      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();
      expect(translationCredentials.value, isNull);
      expect(controller.translationKeyConfigured, isFalse);
    },
  );

  testWidgets('About check button runs an update check', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    final updates = UpdateService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'schema': 1,
            'platforms': {
              'macos-arm64': {
                'version': '1.0.0',
                'build': 1,
                'kind': 'appZip',
                'fileName': 'Listenook.zip',
                'size': 3,
                'sha256': sha256.convert(const [1, 2, 3]).toString(),
                'url': 'https://example.com/Listenook.zip',
              },
            },
          }),
          200,
        ),
      ),
      installer: const UnsupportedUpdateInstaller(),
      manifestUri: Uri.parse('https://example.com/latest.json'),
      readCurrentVersion: () async => const AppVersion(1, 0, 0, build: 1),
      updatesDirectory: () => Future.error(StateError('unavailable')),
      platformKey: 'macos-arm64',
      automaticEnabled: false,
    );
    addTearDown(updates.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: controller),
          ChangeNotifierProvider.value(value: updates),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('settings-tab-about')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('about-check-for-updates')));
    await tester.pumpAndSettle();

    expect(updates.phase, UpdatePhase.upToDate);
    expect(find.byKey(const Key('about-update-up-to-date')), findsOneWidget);
    expect(find.text('Listenook is up to date.'), findsOneWidget);
  });

  testWidgets('About tab shows the version and checks for updates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync(
      'meow-settings-about-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final controller = AppController(
      credentialStore: _Credentials(),
      settingsRepository: _Settings(),
      jobRepository: _Jobs(),
      mediaService: _Media(),
      sourceResolver: const LocalMediaSourceResolver(),
      sonioxClient: _Soniox(),
      exporter: const DefaultTranscriptExporter(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    var releaseVersion = '1.0.0';
    var releaseBuild = 1;
    const bytes = <int>[1, 2, 3];
    final updates = UpdateService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('latest.json')) {
          return http.Response(
            jsonEncode({
              'schema': 1,
              'platforms': {
                'macos-arm64': {
                  'version': releaseVersion,
                  'build': releaseBuild,
                  'kind': 'appZip',
                  'fileName': 'Listenook.zip',
                  'size': bytes.length,
                  'sha256': sha256.convert(bytes).toString(),
                  'url': 'https://example.com/Listenook.zip',
                },
              },
            }),
            200,
          );
        }
        return http.Response.bytes(bytes, 200);
      }),
      installer: const UnsupportedUpdateInstaller(),
      manifestUri: Uri.parse('https://example.com/latest.json'),
      readCurrentVersion: () async => const AppVersion(1, 0, 0, build: 1),
      updatesDirectory: () async => directory,
      platformKey: 'macos-arm64',
      automaticEnabled: false,
    );
    addTearDown(updates.dispose);
    await tester.runAsync(updates.initialize);

    var restarts = 0;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: controller),
          ChangeNotifierProvider.value(value: updates),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: SettingsPage(onRestartUpdate: () => restarts++)),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('settings-tab-about')));
    await tester.pumpAndSettle();

    expect(find.text('Version 1.0.0+1'), findsOneWidget);

    await tester.runAsync(updates.checkAndDownloadNow);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('about-update-up-to-date')), findsOneWidget);

    releaseVersion = '2.0.0';
    releaseBuild = 2;
    await tester.runAsync(updates.checkAndDownloadNow);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('about-update-ready')), findsOneWidget);
    expect(find.text('Listenook 2.0.0 is ready to install.'), findsOneWidget);
    expect(find.byKey(const Key('about-check-for-updates')), findsNothing);

    await tester.tap(find.byKey(const Key('about-restart-to-update')));
    expect(restarts, 1);
  });
}

Future<void> _selectDefaultProvider(
  WidgetTester tester,
  String providerName,
) async {
  await tester.tap(find.byKey(const Key('default-transcription-provider')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(providerName).last);
  await tester.pumpAndSettle();
}

class _Credentials implements CredentialStore {
  String? value;

  @override
  Future<void> deleteApiKey() async => value = null;

  @override
  Future<String?> readApiKey() async => value;

  @override
  Future<void> writeApiKey(String key) async => value = key;
}

class _SupportedLocalStt implements LocalSttService {
  @override
  bool get isSupported => true;

  @override
  Future<LocalSttResult> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) => throw UnimplementedError();
}

class _TranslationCredentials implements TranslationCredentialStore {
  String? value;

  @override
  Future<void> deleteApiKey() async => value = null;

  @override
  Future<String?> readApiKey() async => value;

  @override
  Future<void> writeApiKey(String key) async => value = key;
}

class _TranslationService implements TranslationService {
  TranslationSettings? testedSettings;
  String? candidateKey;

  @override
  Future<List<String>> listModels(
    TranslationSettings settings, {
    String? candidateApiKey,
  }) async {
    testedSettings = settings;
    candidateKey = candidateApiKey;
    return ['suggested-model', 'replacement-model'];
  }

  @override
  Future<void> translate({
    required TranslationSettings settings,
    required String targetLanguage,
    required List<TranscriptSegment> segments,
    required Future<void> Function(
      Map<String, String> translatedBySegmentId,
      int completedSegments,
      int totalSegments,
    )
    onBatch,
    CancelCheck? shouldCancel,
  }) async {}
}

class _Settings implements SettingsRepository {
  AppSettings value = const AppSettings();

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

class _UiModels implements LocalModelManager {
  @override
  List<LocalModelDescriptor> get models => LocalSpeechModels.all;

  @override
  Future<void> delete(String modelId) async {}

  @override
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    CancelCheck? shouldCancel,
  }) async {}

  @override
  String pathFor(String modelId) => '/models/$modelId';

  @override
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  }) async {
    final descriptor = LocalSpeechModels.all.singleWhere(
      (model) => model.id == modelId,
    );
    final installed = LocalSpeechModels.forcedAlignerById(modelId) != null;
    return LocalModelStatus(
      descriptor: descriptor,
      availability: installed
          ? LocalModelAvailability.ready
          : LocalModelAvailability.missing,
      downloadedBytes: installed ? descriptor.sizeBytes : 0,
    );
  }
}

class _Jobs implements JobRepository {
  @override
  Future<void> delete(String id) async {}

  @override
  Future<List<TranscriptionJob>> loadAll() async => [];

  @override
  Future<void> save(TranscriptionJob job) async {}
}

class _Media implements MediaService {
  @override
  bool canUploadDirectly(
    String path,
    MediaMetadata metadata, {
    MediaUploadProfile profile = MediaUploadProfile.standard,
  }) => true;

  @override
  Future<void> deleteTemporary(String path) async {}

  @override
  Future<void> deleteGeneratedMedia(String cacheKey) async {}

  @override
  Future<void> clearGeneratedMediaExcept(Set<String> retainedCacheKeys) async {}

  @override
  Future<MediaDiagnostics> diagnostics() async =>
      const MediaDiagnostics(available: true);

  @override
  Future<String> extractAudio(
    String sourcePath,
    String jobId, {
    required int durationMs,
    MediaUploadProfile profile = MediaUploadProfile.standard,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => sourcePath;

  @override
  Future<MediaMetadata> inspect(String sourcePath) async => const MediaMetadata(
    sizeBytes: 1,
    durationMs: 1000,
    hasAudio: true,
    hasVideo: false,
    formatName: 'wav',
  );

  @override
  Future<String> renderWaveform(String sourcePath, String cacheKey) async => '';
}

class _Soniox implements SonioxClient {
  String? validatedKey;

  @override
  Future<String> createTranscription(
    String fileId,
    TranscriptionOptions options,
  ) async => 'transcription';

  @override
  Future<void> deleteFile(String id) async {}

  @override
  Future<void> deleteTranscription(String id) async {}

  @override
  Future<Map<String, dynamic>> getTranscript(String id) async => {};

  @override
  Future<SonioxTranscriptionState> getTranscription(String id) async =>
      const SonioxTranscriptionState(status: 'completed');

  @override
  Future<String> uploadFile(
    String path, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  }) async => 'file';

  @override
  Future<void> validateKey({String? apiKey}) async {
    validatedKey = apiKey;
  }
}
