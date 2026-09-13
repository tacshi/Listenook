import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/models.dart';
import 'data/desktop_runtime.dart';
import 'data/update_service.dart';
import 'l10n/strings.dart';
import 'state/app_controller.dart';
import 'state/podcast_controller.dart';
import 'theme.dart';
import 'ui/app_shell.dart';

class ListenookApp extends StatelessWidget {
  const ListenookApp({
    super.key,
    required this.controller,
    required this.updates,
    required this.desktopRuntime,
    this.podcastController,
  });
  final AppController controller;
  final UpdateService updates;
  final DesktopRuntime desktopRuntime;
  final PodcastController? podcastController;

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: controller),
      ChangeNotifierProvider.value(value: updates),
      Provider.value(value: desktopRuntime),
      if (podcastController != null)
        ChangeNotifierProvider.value(value: podcastController!),
    ],
    child: Consumer<AppController>(
      builder: (context, state, _) => MaterialApp(
        onGenerateTitle: (context) => AppStrings.of(context).appName,
        debugShowCheckedModeBanner: false,
        theme: ListenookTheme.light(),
        darkTheme: ListenookTheme.dark(),
        themeMode: switch (state.settings.themeMode) {
          AppThemeMode.light => ThemeMode.light,
          AppThemeMode.dark => ThemeMode.dark,
          AppThemeMode.system => ThemeMode.system,
        },
        locale: switch (state.settings.localeMode) {
          AppLocaleMode.english => const Locale('en'),
          AppLocaleMode.simplifiedChinese => const Locale('zh', 'CN'),
          AppLocaleMode.system => null,
        },
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const AppShell(),
      ),
    ),
  );
}
