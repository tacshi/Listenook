import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/data/local_repositories.dart';
import 'package:meow_stt/data/process_media_service.dart';

void main() {
  test('ffprobe passes a special-character path as one argument', () {
    const source = r'/tmp/a file [final] $HOME;?.mkv';
    final arguments = buildFfprobeArguments(source);
    expect(arguments.last, source);
    expect(arguments.where((item) => item == source), hasLength(1));
  });

  test('FFmpeg extraction is 16 kHz mono FLAC without shell interpolation', () {
    const source = r'C:\Media\speaker & guest.mp4';
    const output = r'C:\Temp\job.flac';
    final arguments = buildFfmpegExtractionArguments(source, output);
    expect(arguments[arguments.indexOf('-i') + 1], source);
    expect(
      arguments,
      containsAllInOrder(['-ac', '1', '-ar', '16000', '-c:a', 'flac']),
    );
    expect(arguments.last, output);
  });

  test('FFmpeg waveform is generated from the real audio stream', () {
    const source = r'/tmp/voice & music.m4a';
    const output = r'/tmp/job-waveform.png';
    final arguments = buildFfmpegWaveformArguments(source, output);

    expect(arguments[arguments.indexOf('-i') + 1], source);
    expect(
      arguments[arguments.indexOf('-filter_complex') + 1],
      allOf(contains('showwavespic=s=1200x160'), contains('scale=sqrt')),
    );
    expect(arguments, containsAllInOrder(['-frames:v', '1']));
    expect(arguments.last, output);
  });

  test('generated media cleanup removes only job-owned cache files', () async {
    final root = await Directory.systemTemp.createTemp('meow-media-cleanup-');
    addTearDown(() => root.delete(recursive: true));
    final paths = AppPaths.forTesting(root.path);
    await paths.temporary.create(recursive: true);
    final audio = File('${paths.temporary.path}/job.flac');
    final waveform = File('${paths.temporary.path}/job-waveform.png');
    final unrelated = File('${paths.temporary.path}/other.flac');
    await audio.writeAsBytes([1]);
    await waveform.writeAsBytes([2]);
    await unrelated.writeAsBytes([3]);

    await ProcessMediaService(paths).deleteGeneratedMedia('job');

    expect(await audio.exists(), isFalse);
    expect(await waveform.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);

    final orphan = File('${paths.temporary.path}/orphan-waveform.png');
    await orphan.writeAsBytes([4]);
    await ProcessMediaService(paths).clearGeneratedMediaExcept({'other'});

    expect(await unrelated.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
  });
}
