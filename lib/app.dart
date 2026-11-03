import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'core/models.dart';
import 'core/platform_capabilities.dart';
import 'data/desktop_runtime.dart';
import 'data/desktop_tray.dart';
import 'data/managed_media_store.dart';
import 'data/local_repositories.dart';
import 'data/update_service.dart';
import 'l10n/strings.dart';
import 'state/app_controller.dart';
import 'state/now_playing_coordinator.dart';
import 'state/podcast_controller.dart';
import 'state/video_open_requests.dart';
import 'theme.dart';
import 'ui/app_shell.dart';
import 'ui/platform/platform_context.dart';

class ListenookApp extends StatelessWidget {
  const ListenookApp({
    super.key,
    required this.controller,
    required this.updates,
    required this.desktopRuntime,
    this.desktopTray,
    this.podcastController,
    this.videoOpenRequests,
    this.videoPlaybackRepository,
    this.capabilities,
    this.managedMediaStore,
    this.nowPlaying,
  });
  final AppController controller;
  final UpdateService updates;
  final DesktopRuntime desktopRuntime;
  final DesktopTray? desktopTray;
  final PodcastController? podcastController;
  final VideoOpenRequests? videoOpenRequests;
  final VideoPlaybackRepository? videoPlaybackRepository;

  /// Overrides the theme platform's capabilities (tests).
  final PlatformCapabilities? capabilities;

  /// iOS: where picked and received files are kept.
  final ManagedMediaStore? managedMediaStore;

  /// Lock-screen controls for whichever player is playing.
  final NowPlayingCoordinator? nowPlaying;

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: controller),
      ChangeNotifierProvider.value(value: updates),
      Provider.value(value: desktopRuntime),
      if (desktopTray != null) Provider<DesktopTray>.value(value: desktopTray!),
      if (podcastController != null)
        ChangeNotifierProvider.value(value: podcastController!),
      if (videoOpenRequests != null)
        ChangeNotifierProvider.value(value: videoOpenRequests!),
      if (videoPlaybackRepository != null)
        Provider<VideoPlaybackRepository>.value(
          value: videoPlaybackRepository!,
        ),
      if (capabilities != null)
        Provider<PlatformCapabilities>.value(value: capabilities!),
      if (managedMediaStore != null)
        Provider<ManagedMediaStore>.value(value: managedMediaStore!),
      if (nowPlaying != null)
        Provider<NowPlayingCoordinator>.value(value: nowPlaying!),
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
          ...GlobalMaterialLocalizations.delegates,
        ],
        builder: (context, child) =>
            InputModality(child: child ?? const SizedBox.shrink()),
        home: const AppShell(),
      ),
    ),
  );
}
