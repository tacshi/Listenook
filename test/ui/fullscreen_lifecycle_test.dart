import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:listenook/ui/review_fullscreen_controller.dart';

void main() {
  testWidgets('exiting a fullscreen video is lifecycle safe', (tester) async {
    final player = Player(platformPlayer: _FakePlatformPlayer());
    final controller = VideoController(player);
    controller.platform.future.ignore();
    final videoKey = GlobalKey<VideoState>();
    final fullscreen = ReviewFullscreenController();
    late NavigatorState navigator;
    addTearDown(player.dispose);

    await _pumpVideoWithoutNativeBackendLog(
      tester,
      controller,
      _videoApp(
        videoKey,
        controller,
        onEnterFullscreen: () async => fullscreen.markEntered(navigator),
        onExitFullscreen: () async => fullscreen.markExited(),
      ),
    );
    navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final state = videoKey.currentState!;
    await state.enterFullscreen();
    await tester.pumpAndSettle();
    expect(state.isFullscreen(), isTrue);
    expect(fullscreen.isActive, isTrue);

    final firstExit = fullscreen.exit();
    final duplicateExit = fullscreen.exit();
    await tester.pumpAndSettle();
    await Future.wait([firstExit, duplicateExit]);

    expect(state.isFullscreen(), isFalse);
    expect(fullscreen.isActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing a video while fullscreen is lifecycle safe', (
    tester,
  ) async {
    final player = Player(platformPlayer: _FakePlatformPlayer());
    final controller = VideoController(player);
    controller.platform.future.ignore();
    final videoKey = GlobalKey<VideoState>();
    final fullscreen = ReviewFullscreenController();
    late NavigatorState navigator;
    addTearDown(player.dispose);

    await _pumpVideoWithoutNativeBackendLog(
      tester,
      controller,
      _videoApp(
        videoKey,
        controller,
        onEnterFullscreen: () async => fullscreen.markEntered(navigator),
        onExitFullscreen: () async => fullscreen.markExited(),
      ),
    );
    navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final state = videoKey.currentState!;
    await state.enterFullscreen();
    await tester.pumpAndSettle();
    expect(state.isFullscreen(), isTrue);
    expect(fullscreen.isActive, isTrue);

    final exit = fullscreen.exit();
    var exitCompleted = false;
    exit.whenComplete(() => exitCompleted = true);
    await tester.idle();
    expect(
      exitCompleted,
      isFalse,
      reason: 'exit must wait until the fullscreen route is finalized',
    );
    await tester.pumpAndSettle();
    await exit;
    expect(state.isFullscreen(), isFalse);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Next queue item'))),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpVideoWithoutNativeBackendLog(
  WidgetTester tester,
  VideoController controller,
  Widget app,
) async {
  final originalDebugPrint = debugPrint;
  debugPrint = (message, {wrapWidth}) {};
  try {
    await tester.pumpWidget(app);
    await tester.pump();
    try {
      await controller.platform.future;
    } on Object {
      // flutter_test has no bundled native media framework. The lifecycle
      // behavior under test is entirely in the Flutter fullscreen route.
    }
  } finally {
    debugPrint = originalDebugPrint;
  }
}

Widget _videoApp(
  GlobalKey<VideoState> key,
  VideoController controller, {
  Future<void> Function()? onEnterFullscreen,
  Future<void> Function()? onExitFullscreen,
}) => MaterialApp(
  home: Scaffold(
    body: Video(
      key: key,
      controller: controller,
      controls: (state) => state.isFullscreen()
          ? const ColoredBox(color: Colors.black)
          : const SizedBox.shrink(),
      onEnterFullscreen: onEnterFullscreen ?? () async {},
      onExitFullscreen: onExitFullscreen ?? () async {},
    ),
  ),
);

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration()) {
    completer.complete();
  }

  @override
  Future<int> get handle async => 0;
}
