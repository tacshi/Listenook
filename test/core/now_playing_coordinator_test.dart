import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/data/now_playing.dart';
import 'package:listenook/state/now_playing_coordinator.dart';

class _FakeBridge implements NowPlayingBridge {
  final updates = <NowPlayingItem>[];
  var clears = 0;
  final _commands = StreamController<NowPlayingCommand>.broadcast();

  void send(NowPlayingCommand command) => _commands.add(command);

  @override
  Stream<NowPlayingCommand> get commands => _commands.stream;

  @override
  Future<void> update(NowPlayingItem item) async => updates.add(item);

  @override
  Future<void> clear() async => clears++;
}

class _FakeSource extends ChangeNotifier implements NowPlayingSource {
  _FakeSource(this.title);

  final String title;
  bool playing = false;
  Duration position = Duration.zero;
  final calls = <String>[];

  void advance(Duration to) {
    position = to;
    notifyListeners();
  }

  @override
  NowPlayingItem? get nowPlaying => NowPlayingItem(
    title: title,
    duration: const Duration(minutes: 10),
    position: position,
    playing: playing,
  );

  @override
  Future<void> play() async {
    calls.add('play');
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> seekTo(Duration position) async {
    calls.add('seek ${position.inSeconds}');
    advance(position);
  }
}

void main() {
  test('the newest player owns the lock screen and its commands', () async {
    final bridge = _FakeBridge();
    final coordinator = NowPlayingCoordinator(bridge);
    final podcast = _FakeSource('Episode')..playing = true;
    final review = _FakeSource('Lecture');

    coordinator.claim(podcast);
    expect(bridge.updates.last.title, 'Episode');

    coordinator.claim(review);
    expect(bridge.updates.last.title, 'Lecture');

    bridge.send(const NowPlayingToggle());
    bridge.send(const NowPlayingSkip(Duration(seconds: 15)));
    await pumpEventQueue();
    expect(review.calls, ['play', 'seek 15']);
    expect(podcast.calls, isEmpty);

    // Releasing a player that is not shown changes nothing.
    coordinator.release(podcast);
    expect(bridge.clears, 0);
    coordinator.release(review);
    expect(bridge.clears, 1);
    coordinator.dispose();
  });

  test('steady playback is not resent; pauses and jumps are', () async {
    final bridge = _FakeBridge();
    final coordinator = NowPlayingCoordinator(bridge);
    final source = _FakeSource('Episode');
    coordinator.claim(source);
    expect(bridge.updates, hasLength(1));

    await source.play();
    await pumpEventQueue();
    expect(bridge.updates, hasLength(2));
    expect(bridge.updates.last.playing, isTrue);

    source.advance(const Duration(milliseconds: 250));
    await pumpEventQueue();
    expect(bridge.updates, hasLength(2));

    source.advance(const Duration(minutes: 5));
    await pumpEventQueue();
    expect(bridge.updates, hasLength(3));
    coordinator.dispose();
  });

  test('the channel bridge turns native commands into commands', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('app.listenook.test/now_playing');
    final bridge = ChannelNowPlayingBridge(channel: channel);
    final received = <NowPlayingCommand>[];
    final subscription = bridge.commands.listen(received.add);
    addTearDown(subscription.cancel);

    Future<void> deliver(Map<String, Object> arguments) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(MethodCall('command', arguments)),
              (_) {},
            );

    await deliver({'name': 'pause'});
    await deliver({'name': 'skip', 'seconds': -15});
    await deliver({'name': 'seek', 'positionMs': 90000});
    await pumpEventQueue();

    expect(received[0], isA<NowPlayingPause>());
    expect(
      (received[1] as NowPlayingSkip).offset,
      const Duration(seconds: -15),
    );
    expect(
      (received[2] as NowPlayingSeek).position,
      const Duration(seconds: 90),
    );
  });
}
