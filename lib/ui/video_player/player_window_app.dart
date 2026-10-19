import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/local_repositories.dart';
import '../../l10n/strings.dart';
import '../../state/app_controller.dart';
import '../../theme.dart';

/// The app around a player window's page: its own [MaterialApp] (the window is
/// a separate view, outside the main window's tree), always dark, following
/// the app's language setting.
class PlayerWindowApp extends StatelessWidget {
  const PlayerWindowApp({
    super.key,
    required this.controller,
    required this.repository,
    required this.child,
  });

  final AppController controller;
  final VideoPlaybackRepository? repository;
  final Widget child;

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: controller),
      if (repository != null)
        Provider<VideoPlaybackRepository>.value(value: repository!),
    ],
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ListenookTheme.dark(),
        locale: switch (controller.settings.localeMode) {
          AppLocaleMode.english => const Locale('en'),
          AppLocaleMode.simplifiedChinese => const Locale('zh', 'CN'),
          AppLocaleMode.system => null,
        },
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [
          AppStrings.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        home: child,
      ),
    ),
  );
}
