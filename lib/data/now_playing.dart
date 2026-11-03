import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/app_identity.dart';

/// What the lock screen and Control Center show.
@immutable
class NowPlayingItem {
  const NowPlayingItem({
    required this.title,
    this.artist,
    this.album,
    this.artworkUrl,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.playing = false,
    this.rate = 1,
  });

  final String title;
  final String? artist;
  final String? album;
  final String? artworkUrl;
  final Duration duration;
  final Duration position;
  final bool playing;
  final double rate;

  Map<String, Object?> toMap() => {
    'title': title,
    'artist': ?artist,
    'album': ?album,
    'artworkUrl': ?artworkUrl,
    'durationMs': duration.inMilliseconds,
    'positionMs': position.inMilliseconds,
    'playing': playing,
    'rate': rate,
  };

  @override
  bool operator ==(Object other) =>
      other is NowPlayingItem &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.artworkUrl == artworkUrl &&
      other.duration == duration &&
      other.position == position &&
      other.playing == playing &&
      other.rate == rate;

  @override
  int get hashCode => Object.hash(
    title,
    artist,
    album,
    artworkUrl,
    duration,
    position,
    playing,
    rate,
  );
}

/// A lock-screen, headphone or interruption request.
sealed class NowPlayingCommand {
  const NowPlayingCommand();
}

class NowPlayingPlay extends NowPlayingCommand {
  const NowPlayingPlay();
}

class NowPlayingPause extends NowPlayingCommand {
  const NowPlayingPause();
}

class NowPlayingToggle extends NowPlayingCommand {
  const NowPlayingToggle();
}

class NowPlayingSkip extends NowPlayingCommand {
  const NowPlayingSkip(this.offset);
  final Duration offset;
}

class NowPlayingSeek extends NowPlayingCommand {
  const NowPlayingSeek(this.position);
  final Duration position;
}

abstract interface class NowPlayingBridge {
  Stream<NowPlayingCommand> get commands;

  Future<void> update(NowPlayingItem item);

  Future<void> clear();
}

/// No system media controls (desktop, tests).
class NoNowPlayingBridge implements NowPlayingBridge {
  const NoNowPlayingBridge();

  @override
  Stream<NowPlayingCommand> get commands => const Stream.empty();

  @override
  Future<void> update(NowPlayingItem item) async {}

  @override
  Future<void> clear() async {}
}

/// iOS: MPNowPlayingInfoCenter and MPRemoteCommandCenter in the runner
/// (ios/Runner/NowPlaying.swift).
class ChannelNowPlayingBridge implements NowPlayingBridge {
  ChannelNowPlayingBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(AppIdentity.nowPlayingChannel) {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final _commands = StreamController<NowPlayingCommand>.broadcast();

  @override
  Stream<NowPlayingCommand> get commands => _commands.stream;

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'command') return null;
    final arguments = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    final command = switch (arguments['name']) {
      'play' => const NowPlayingPlay(),
      'pause' => const NowPlayingPause(),
      'toggle' => const NowPlayingToggle(),
      'skip' => NowPlayingSkip(
        Duration(seconds: (arguments['seconds'] as num? ?? 0).toInt()),
      ),
      'seek' => NowPlayingSeek(
        Duration(milliseconds: (arguments['positionMs'] as num? ?? 0).toInt()),
      ),
      _ => null,
    };
    if (command != null) _commands.add(command);
    return null;
  }

  @override
  Future<void> update(NowPlayingItem item) => _invoke('update', item.toMap());

  @override
  Future<void> clear() => _invoke('clear');

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Not registered in widget tests.
    } on PlatformException catch (error) {
      debugPrint('Now Playing update failed: $error');
    }
  }
}
