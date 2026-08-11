import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

Future<void> main(List<String> arguments) async {
  final mode = arguments.firstOrNull;
  final isProbe = mode == 'probe';
  if ((!isProbe && arguments.length != 3) ||
      (isProbe && arguments.length != 2) ||
      !const {'pcm', 'probe'}.contains(mode)) {
    stderr.writeln(
      'Usage: dart run tool/libmpv_extract_prototype.dart '
      'pcm <input> <output.wav>\n'
      '   or: dart run tool/libmpv_extract_prototype.dart probe <input>',
    );
    exitCode = 64;
    return;
  }

  final input = File(arguments[1]).absolute;
  final output = isProbe ? null : File(arguments[2]).absolute;
  if (!input.existsSync()) {
    stderr.writeln('Input does not exist: ${input.path}');
    exitCode = 66;
    return;
  }
  if (output?.existsSync() ?? false) output!.deleteSync();
  output?.parent.createSync(recursive: true);

  MediaKit.ensureInitialized();
  final player = Player();
  final native = player.platform;
  if (native is! NativePlayer) {
    stderr.writeln('media_kit did not create a NativePlayer.');
    await player.dispose();
    exitCode = 69;
    return;
  }

  final errors = <String>[];
  final errorSubscription = player.stream.error.listen(errors.add);
  var lastPosition = Duration.zero;
  final progressSubscription = player.stream.position.listen((position) {
    lastPosition = position;
  });
  final completed = isProbe
      ? null
      : player.stream.completed.firstWhere((value) => value);
  final watch = Stopwatch()..start();
  var duration = Duration.zero;
  var tracks = const Tracks();
  var fileFormat = '';

  try {
    if (!isProbe) {
      await native.setProperty('vid', 'no');
      await native.setProperty('audio-channels', 'mono');
      await native.setProperty('audio-samplerate', '16000');
      await native.setProperty('audio-format', 's16');
    }
    if (mode == 'pcm') {
      await native.setProperty('ao', 'pcm');
      await native.setProperty('ao-pcm-waveheader', 'yes');
      await native.setProperty('ao-pcm-file', output!.path);
      await native.setProperty('untimed', 'yes');
    }

    if (isProbe) {
      await player.open(Media(input.path), play: false);
      if (!_hasMediaTracks(player.state.tracks)) {
        await player.stream.tracks
            .firstWhere(_hasMediaTracks)
            .timeout(const Duration(seconds: 10));
      }
      if (player.state.duration <= Duration.zero) {
        await player.stream.duration
            .firstWhere((value) => value > Duration.zero)
            .timeout(const Duration(seconds: 10));
      }
    } else {
      await player.open(Media(input.path), play: true);
      await completed!.timeout(const Duration(minutes: 5));
    }
    duration = player.state.duration;
    tracks = player.state.tracks;
    fileFormat = await native.getProperty('file-format');
    await player.stop();
  } finally {
    await progressSubscription.cancel();
    await errorSubscription.cancel();
    await player.dispose();
    watch.stop();
  }

  if (!isProbe && (!output!.existsSync() || output.lengthSync() == 0)) {
    stderr.writeln('libmpv did not create output: ${output.path}');
    for (final error in errors) {
      stderr.writeln(error);
    }
    exitCode = 1;
    return;
  }

  stdout.writeln('mode=$mode');
  stdout.writeln('elapsed_ms=${watch.elapsedMilliseconds}');
  stdout.writeln('position_ms=${lastPosition.inMilliseconds}');
  stdout.writeln('duration_ms=${duration.inMilliseconds}');
  stdout.writeln('file_format=$fileFormat');
  stdout.writeln(
    'audio_tracks=${tracks.audio.where((track) => track.id != 'auto' && track.id != 'no').toList()}',
  );
  stdout.writeln(
    'video_tracks=${tracks.video.where((track) => track.id != 'auto' && track.id != 'no').toList()}',
  );
  if (output != null) {
    stdout.writeln('output_bytes=${output.lengthSync()}');
    stdout.writeln('output=${output.path}');
  }
  if (errors.isNotEmpty) {
    stdout.writeln('player_errors=${errors.join(' | ')}');
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

bool _hasMediaTracks(Tracks value) =>
    value.audio.any((track) => track.id != 'auto' && track.id != 'no') ||
    value.video.any((track) => track.id != 'auto' && track.id != 'no');
