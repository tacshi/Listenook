import 'package:flutter_test/flutter_test.dart';
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
}
