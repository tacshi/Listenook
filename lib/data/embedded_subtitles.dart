import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/models.dart';
import 'timed_subtitle_import.dart';

/// A subtitle track stored inside a video container.
class EmbeddedSubtitleTrack {
  const EmbeddedSubtitleTrack({
    required this.containerIndex,
    required this.trackNumber,
    required this.codec,
    this.format,
    this.language,
    this.title,
    this.isDefault = false,
    this.isForced = false,
  });

  /// The track's position among all container tracks, which is the
  /// `ff-index` libmpv reports for it.
  final int containerIndex;

  /// Matroska `TrackNumber` or MP4 `track_ID`.
  final int trackNumber;
  final String codec;

  /// The text format the cues are read as; `null` for picture-based or
  /// otherwise unreadable tracks, which can only be shown by the player.
  final SubtitleFormat? format;
  final String? language;
  final String? title;
  final bool isDefault;
  final bool isForced;

  bool get isText => format != null;
}

class EmbeddedSubtitleException implements Exception {
  const EmbeddedSubtitleException(this.code);

  final String code;

  @override
  String toString() => 'EmbeddedSubtitleException($code)';
}

/// Reads text subtitle tracks from Matroska (MKV/WebM) and MP4/MOV files
/// without decoding audio or video, so a subtitle track can drive sentence
/// navigation before playback reaches it.
class EmbeddedSubtitleReader {
  const EmbeddedSubtitleReader();

  static const containerExtensions = {'mkv', 'webm', 'mp4', 'm4v', 'mov'};

  static bool supportsPath(String path) => containerExtensions.contains(
    p.extension(path).replaceFirst('.', '').toLowerCase(),
  );

  Future<List<EmbeddedSubtitleTrack>> listTracks(String path) =>
      Isolate.run(() => listTracksSync(path));

  Future<List<TimedSubtitleCue>> extract(
    String path,
    EmbeddedSubtitleTrack track,
  ) => Isolate.run(() => extractSync(path, track));

  static List<EmbeddedSubtitleTrack> listTracksSync(String path) {
    if (!supportsPath(path)) return const [];
    return _withFile(path, (reader) {
      if (_isMatroska(reader)) return _MatroskaReader(reader).tracks();
      return _Mp4Reader(reader).tracks();
    });
  }

  static List<TimedSubtitleCue> extractSync(
    String path,
    EmbeddedSubtitleTrack track,
  ) {
    if (!track.isText) {
      throw const EmbeddedSubtitleException('subtitle_track_not_text');
    }
    return _withFile(path, (reader) {
      final cues = _isMatroska(reader)
          ? _MatroskaReader(reader).cues(track)
          : _Mp4Reader(reader).cues(track);
      return mergeSimultaneousCues(_closeOpenEnds(cues));
    });
  }

  static T _withFile<T>(String path, T Function(_ByteReader reader) read) {
    final file = File(path).openSync();
    try {
      return read(_ByteReader(file));
    } on _Truncated {
      throw const EmbeddedSubtitleException('subtitle_container_unreadable');
    } on RangeError {
      throw const EmbeddedSubtitleException('subtitle_container_unreadable');
    } finally {
      file.closeSync();
    }
  }

  static bool _isMatroska(_ByteReader reader) =>
      reader.length >= 4 &&
      reader.byteAt(0) == 0x1a &&
      reader.byteAt(1) == 0x45 &&
      reader.byteAt(2) == 0xdf &&
      reader.byteAt(3) == 0xa3;
}

/// Gives cues without a stored duration an end at the next cue, so they can
/// still be repeated as one sentence.
List<TimedSubtitleCue> _closeOpenEnds(List<TimedSubtitleCue> cues) {
  const fallbackMs = 4000;
  final sorted = List.of(cues)
    ..sort((left, right) => left.startMs.compareTo(right.startMs));
  return [
    for (var index = 0; index < sorted.length; index++)
      if (sorted[index].endMs > sorted[index].startMs)
        sorted[index]
      else
        TimedSubtitleCue(
          startMs: sorted[index].startMs,
          endMs:
              index + 1 < sorted.length &&
                  sorted[index + 1].startMs > sorted[index].startMs
              ? sorted[index + 1].startMs.clamp(
                  sorted[index].startMs + 1,
                  sorted[index].startMs + fallbackMs,
                )
              : sorted[index].startMs + fallbackMs,
          text: sorted[index].text,
        ),
  ];
}

class _Truncated implements Exception {
  const _Truncated();
}

/// Random access over a file with a small read-ahead window, so walking
/// container headers does not issue one system call per byte.
class _ByteReader {
  _ByteReader(this._file) : length = _file.lengthSync();

  static const _window = 1 << 16;

  final RandomAccessFile _file;
  final int length;
  int _bufferStart = 0;
  Uint8List _buffer = Uint8List(0);

  int byteAt(int position) {
    _ensure(position, 1);
    return _buffer[position - _bufferStart];
  }

  Uint8List bytes(int position, int count) {
    if (count < 0 || position < 0 || position + count > length) {
      throw const _Truncated();
    }
    if (count > _window) {
      _file.setPositionSync(position);
      final data = _file.readSync(count);
      if (data.length != count) throw const _Truncated();
      return data;
    }
    _ensure(position, count);
    final offset = position - _bufferStart;
    return Uint8List.fromList(_buffer.sublist(offset, offset + count));
  }

  int uint(int position, int width) {
    var value = 0;
    for (var index = 0; index < width; index++) {
      value = (value << 8) | byteAt(position + index);
    }
    return value;
  }

  void _ensure(int position, int count) {
    if (position >= _bufferStart &&
        position + count <= _bufferStart + _buffer.length) {
      return;
    }
    if (position < 0 || position + count > length) throw const _Truncated();
    _file.setPositionSync(position);
    _buffer = _file.readSync(_window);
    _bufferStart = position;
    if (_buffer.length < count) throw const _Truncated();
  }
}

// --- Matroska -------------------------------------------------------------

const _ebmlHeaderId = 0x1a45dfa3;
const _segmentId = 0x18538067;
const _infoId = 0x1549a966;
const _timecodeScaleId = 0x2ad7b1;
const _tracksId = 0x1654ae6b;
const _trackEntryId = 0xae;
const _trackNumberId = 0xd7;
const _trackTypeId = 0x83;
const _codecIdId = 0x86;
const _nameId = 0x536e;
const _languageId = 0x22b59c;
const _languageBcp47Id = 0x22b59d;
const _flagDefaultId = 0x88;
const _flagForcedId = 0x55aa;
const _contentEncodingsId = 0x6d80;
const _contentEncodingId = 0x6240;
const _contentCompressionId = 0x5034;
const _contentCompAlgoId = 0x4254;
const _contentCompSettingsId = 0x4255;
const _contentEncryptionId = 0x5035;
const _clusterId = 0x1f43b675;
const _clusterTimecodeId = 0xe7;
const _simpleBlockId = 0xa3;
const _blockGroupId = 0xa0;
const _blockId = 0xa1;
const _blockDurationId = 0x9b;
const _subtitleTrackType = 0x11;

const _segmentLevelIds = {
  0x114d9b74, // SeekHead
  _infoId,
  _tracksId,
  _clusterId,
  0x1c53bb6b, // Cues
  0x1941a469, // Attachments
  0x1043a770, // Chapters
  0x1254c367, // Tags
};

class _Element {
  const _Element(this.id, this.dataStart, this.size);

  final int id;
  final int dataStart;

  /// `null` when the element has an unknown size (live-streamed files).
  final int? size;

  int end(int parentEnd) => size == null ? parentEnd : dataStart + size!;
}

class _MatroskaTrack {
  _MatroskaTrack(this.containerIndex);

  final int containerIndex;
  int number = 0;
  int type = 0;
  String codec = '';
  String? name;
  String? language = 'eng';
  String? languageBcp47;
  bool isDefault = true;
  bool isForced = false;
  bool encrypted = false;
  int? compression;
  Uint8List? strippedHeader;

  SubtitleFormat? get format {
    if (encrypted ||
        (compression != null && compression != 0 && compression != 3)) {
      return null;
    }
    return switch (codec) {
      'S_TEXT/UTF8' || 'S_TEXT/ASCII' => SubtitleFormat.srt,
      'S_TEXT/ASS' || 'S_TEXT/SSA' || 'S_ASS' || 'S_SSA' => SubtitleFormat.ass,
      'S_TEXT/WEBVTT' => SubtitleFormat.webVtt,
      _ => null,
    };
  }

  EmbeddedSubtitleTrack toTrack() => EmbeddedSubtitleTrack(
    containerIndex: containerIndex,
    trackNumber: number,
    codec: codec,
    format: format,
    language: _language(languageBcp47 ?? language),
    title: name?.trim().isEmpty == true ? null : name?.trim(),
    isDefault: isDefault,
    isForced: isForced,
  );
}

class _MatroskaReader {
  _MatroskaReader(this._reader);

  final _ByteReader _reader;
  int _timecodeScale = 1000000;

  List<EmbeddedSubtitleTrack> tracks() => [
    for (final track in _readTracks(stopAtFirstCluster: true))
      if (track.type == _subtitleTrackType) track.toTrack(),
  ];

  List<TimedSubtitleCue> cues(EmbeddedSubtitleTrack target) {
    final cues = <TimedSubtitleCue>[];
    _MatroskaTrack? track;
    _walkSegment((element, segmentEnd) {
      if (element.id == _tracksId) {
        track = _parseTracks(
          element,
          segmentEnd,
        ).where((item) => item.number == target.trackNumber).firstOrNull;
      } else if (element.id == _clusterId && track != null) {
        _readCluster(element, segmentEnd, track!, cues);
      }
      return true;
    });
    if (track == null) {
      throw const EmbeddedSubtitleException('subtitle_track_missing');
    }
    return cues;
  }

  List<_MatroskaTrack> _readTracks({required bool stopAtFirstCluster}) {
    var tracks = <_MatroskaTrack>[];
    _walkSegment((element, segmentEnd) {
      if (element.id == _tracksId) {
        tracks = _parseTracks(element, segmentEnd);
        return false;
      }
      return !(stopAtFirstCluster && element.id == _clusterId);
    });
    return tracks;
  }

  /// Visits the segment's top-level children until [visit] returns false.
  void _walkSegment(bool Function(_Element element, int segmentEnd) visit) {
    var position = 0;
    final header = _element(position, _reader.length);
    if (header.id != _ebmlHeaderId) {
      throw const EmbeddedSubtitleException('subtitle_container_unreadable');
    }
    position = header.end(_reader.length);
    while (position < _reader.length) {
      final segment = _element(position, _reader.length);
      final segmentEnd = segment.end(_reader.length).clamp(0, _reader.length);
      if (segment.id != _segmentId) {
        position = segmentEnd;
        continue;
      }
      var child = segment.dataStart;
      while (child < segmentEnd) {
        final element = _element(child, segmentEnd);
        if (element.id == _infoId) _parseInfo(element, segmentEnd);
        if (!visit(element, segmentEnd)) return;
        child = element.size == null
            ? _unknownSizeEnd(element, segmentEnd)
            : element.end(segmentEnd);
      }
      return;
    }
  }

  void _parseInfo(_Element info, int parentEnd) {
    for (final child in _children(info, parentEnd)) {
      if (child.id == _timecodeScaleId) {
        _timecodeScale = _reader.uint(child.dataStart, child.size!);
      }
    }
  }

  List<_MatroskaTrack> _parseTracks(_Element tracks, int parentEnd) {
    final result = <_MatroskaTrack>[];
    for (final entry in _children(tracks, parentEnd)) {
      if (entry.id != _trackEntryId) continue;
      final track = _MatroskaTrack(result.length);
      for (final field in _children(entry, entry.end(parentEnd))) {
        final size = field.size ?? 0;
        switch (field.id) {
          case _trackNumberId:
            track.number = _reader.uint(field.dataStart, size);
          case _trackTypeId:
            track.type = _reader.uint(field.dataStart, size);
          case _codecIdId:
            track.codec = _string(field);
          case _nameId:
            track.name = _string(field);
          case _languageId:
            track.language = _string(field);
          case _languageBcp47Id:
            track.languageBcp47 = _string(field);
          case _flagDefaultId:
            track.isDefault = _reader.uint(field.dataStart, size) != 0;
          case _flagForcedId:
            track.isForced = _reader.uint(field.dataStart, size) != 0;
          case _contentEncodingsId:
            _parseEncodings(field, entry.end(parentEnd), track);
        }
      }
      result.add(track);
    }
    return result;
  }

  void _parseEncodings(
    _Element encodings,
    int parentEnd,
    _MatroskaTrack track,
  ) {
    for (final encoding in _children(encodings, parentEnd)) {
      if (encoding.id != _contentEncodingId) continue;
      for (final part in _children(encoding, encoding.end(parentEnd))) {
        if (part.id == _contentEncryptionId) track.encrypted = true;
        if (part.id != _contentCompressionId) continue;
        track.compression = 0;
        for (final setting in _children(part, part.end(parentEnd))) {
          if (setting.id == _contentCompAlgoId) {
            track.compression = _reader.uint(setting.dataStart, setting.size!);
          } else if (setting.id == _contentCompSettingsId) {
            track.strippedHeader = _reader.bytes(
              setting.dataStart,
              setting.size!,
            );
          }
        }
      }
    }
  }

  void _readCluster(
    _Element cluster,
    int segmentEnd,
    _MatroskaTrack track,
    List<TimedSubtitleCue> cues,
  ) {
    var clusterTimecode = 0;
    final end = cluster.end(segmentEnd);
    var position = cluster.dataStart;
    while (position < end) {
      final element = _element(position, end);
      if (cluster.size == null && _segmentLevelIds.contains(element.id)) {
        return;
      }
      final elementEnd = element.end(end);
      switch (element.id) {
        case _clusterTimecodeId:
          clusterTimecode = _reader.uint(element.dataStart, element.size!);
        case _simpleBlockId:
          _readBlock(
            element.dataStart,
            elementEnd,
            null,
            clusterTimecode,
            track,
            cues,
          );
        case _blockGroupId:
          int? blockStart;
          int? blockEnd;
          int? duration;
          for (final child in _children(element, end)) {
            if (child.id == _blockId) {
              blockStart = child.dataStart;
              blockEnd = child.end(elementEnd);
            } else if (child.id == _blockDurationId) {
              duration = _reader.uint(child.dataStart, child.size!);
            }
          }
          if (blockStart != null) {
            _readBlock(
              blockStart,
              blockEnd!,
              duration,
              clusterTimecode,
              track,
              cues,
            );
          }
      }
      position = elementEnd;
    }
  }

  void _readBlock(
    int start,
    int end,
    int? duration,
    int clusterTimecode,
    _MatroskaTrack track,
    List<TimedSubtitleCue> cues,
  ) {
    final (number, width) = _vint(start, keepMarker: false);
    if (number != track.number) return;
    final headerEnd = start + width + 3;
    if (headerEnd > end) return;
    final relative = _reader.uint(start + width, 2).toSigned(16);
    final flags = _reader.byteAt(start + width + 2);
    // Laced subtitle blocks are not produced by muxers in practice.
    if (flags & 0x06 != 0) return;
    var payload = _reader.bytes(headerEnd, end - headerEnd);
    if (track.compression == 0) {
      try {
        payload = Uint8List.fromList(ZLibCodec().decode(payload));
      } on FormatException {
        return;
      }
    } else if (track.compression == 3 && track.strippedHeader != null) {
      payload = Uint8List.fromList([...track.strippedHeader!, ...payload]);
    }
    final raw = utf8
        .decode(payload, allowMalformed: true)
        .replaceAll('\x00', '');
    final text = track.format == SubtitleFormat.ass
        ? matroskaAssBlockText(raw)
        : raw.trim();
    if (text.isEmpty) return;
    final startMs = _milliseconds(clusterTimecode + relative);
    cues.add(
      TimedSubtitleCue(
        startMs: startMs,
        endMs: duration == null ? startMs : startMs + _milliseconds(duration),
        text: text,
      ),
    );
  }

  int _milliseconds(int ticks) => (ticks * _timecodeScale) ~/ 1000000;

  int _unknownSizeEnd(_Element element, int parentEnd) {
    var position = element.dataStart;
    while (position < parentEnd) {
      final child = _element(position, parentEnd);
      if (_segmentLevelIds.contains(child.id)) return position;
      position = child.end(parentEnd);
    }
    return parentEnd;
  }

  Iterable<_Element> _children(_Element parent, int parentEnd) sync* {
    final end = parent.end(parentEnd);
    var position = parent.dataStart;
    while (position < end) {
      final child = _element(position, end);
      yield child;
      if (child.size == null) return;
      position = child.end(end);
    }
  }

  _Element _element(int position, int parentEnd) {
    final (id, idWidth) = _vint(position, keepMarker: true);
    final (size, sizeWidth) = _vint(position + idWidth, keepMarker: false);
    final unknown = size == (1 << (7 * sizeWidth)) - 1;
    final dataStart = position + idWidth + sizeWidth;
    if (!unknown && dataStart + size > parentEnd) {
      // Truncated trailing element: read what is present.
      return _Element(id, dataStart, (parentEnd - dataStart).clamp(0, size));
    }
    return _Element(id, dataStart, unknown ? null : size);
  }

  (int, int) _vint(int position, {required bool keepMarker}) {
    final first = _reader.byteAt(position);
    if (first == 0) throw const _Truncated();
    var width = 1;
    while (first & (0x80 >> (width - 1)) == 0) {
      width++;
    }
    var value = keepMarker ? first : first & (0xff >> width);
    for (var index = 1; index < width; index++) {
      value = (value << 8) | _reader.byteAt(position + index);
    }
    return (value, width);
  }

  String _string(_Element element) => utf8
      .decode(
        _reader.bytes(element.dataStart, element.size ?? 0),
        allowMalformed: true,
      )
      .replaceAll('\x00', '')
      .trim();
}

// --- MP4 / QuickTime ------------------------------------------------------

class _Box {
  const _Box(this.type, this.dataStart, this.end);

  final String type;
  final int dataStart;
  final int end;
}

class _Mp4Track {
  _Mp4Track(this.containerIndex);

  final int containerIndex;
  int id = 0;
  bool enabled = true;
  String handler = '';
  String codec = '';
  String? language;
  int timescale = 1000;
  List<(int, int)> timeToSample = const [];
  int fixedSampleSize = 0;
  List<int> sampleSizes = const [];
  int sampleCount = 0;
  List<(int, int)> sampleToChunk = const [];
  List<int> chunkOffsets = const [];

  bool get isSubtitle =>
      const {'text', 'sbtl', 'subt', 'clcp'}.contains(handler);

  EmbeddedSubtitleTrack toTrack() => EmbeddedSubtitleTrack(
    containerIndex: containerIndex,
    trackNumber: id,
    codec: codec,
    format: codec == 'tx3g' ? SubtitleFormat.movText : null,
    language: _language(language),
    isDefault: enabled,
  );
}

class _Mp4Reader {
  _Mp4Reader(this._reader);

  final _ByteReader _reader;

  List<EmbeddedSubtitleTrack> tracks() => [
    for (final track in _tracks())
      if (track.isSubtitle) track.toTrack(),
  ];

  List<TimedSubtitleCue> cues(EmbeddedSubtitleTrack target) {
    final track = _tracks()
        .where((item) => item.isSubtitle && item.id == target.trackNumber)
        .firstOrNull;
    if (track == null) {
      throw const EmbeddedSubtitleException('subtitle_track_missing');
    }
    final cues = <TimedSubtitleCue>[];
    final offsets = _sampleOffsets(track);
    var time = 0;
    var sample = 0;
    for (final (count, delta) in track.timeToSample) {
      for (var index = 0; index < count && sample < offsets.length; index++) {
        final size = _sampleSize(track, sample);
        final text = _sampleText(offsets[sample], size);
        if (text.isNotEmpty) {
          cues.add(
            TimedSubtitleCue(
              startMs: time * 1000 ~/ track.timescale,
              endMs: (time + delta) * 1000 ~/ track.timescale,
              text: cleanAssText(text),
            ),
          );
        }
        time += delta;
        sample++;
      }
    }
    return cues;
  }

  List<_Mp4Track> _tracks() {
    final moov = _find(0, _reader.length, 'moov');
    if (moov == null) {
      throw const EmbeddedSubtitleException('subtitle_container_unreadable');
    }
    final tracks = <_Mp4Track>[];
    for (final trak in _boxes(moov.dataStart, moov.end)) {
      if (trak.type != 'trak') continue;
      final track = _Mp4Track(tracks.length);
      _readTrak(trak, track);
      tracks.add(track);
    }
    return tracks;
  }

  void _readTrak(_Box trak, _Mp4Track track) {
    final tkhd = _find(trak.dataStart, trak.end, 'tkhd');
    if (tkhd != null) {
      final version = _reader.byteAt(tkhd.dataStart);
      track.enabled = _reader.uint(tkhd.dataStart + 1, 3) & 1 != 0;
      track.id = _reader.uint(tkhd.dataStart + (version == 1 ? 20 : 12), 4);
    }
    final mdia = _find(trak.dataStart, trak.end, 'mdia');
    if (mdia == null) return;
    final mdhd = _find(mdia.dataStart, mdia.end, 'mdhd');
    if (mdhd != null) {
      final version = _reader.byteAt(mdhd.dataStart);
      track.timescale = _reader.uint(
        mdhd.dataStart + (version == 1 ? 20 : 12),
        4,
      );
      if (track.timescale <= 0) track.timescale = 1000;
      final packed = _reader.uint(mdhd.dataStart + (version == 1 ? 32 : 20), 2);
      track.language = String.fromCharCodes([
        ((packed >> 10) & 0x1f) + 0x60,
        ((packed >> 5) & 0x1f) + 0x60,
        (packed & 0x1f) + 0x60,
      ]);
    }
    final hdlr = _find(mdia.dataStart, mdia.end, 'hdlr');
    if (hdlr != null) track.handler = _fourCc(hdlr.dataStart + 8);
    if (!track.isSubtitle) return;
    final minf = _find(mdia.dataStart, mdia.end, 'minf');
    final stbl = minf == null ? null : _find(minf.dataStart, minf.end, 'stbl');
    if (stbl == null) return;
    for (final box in _boxes(stbl.dataStart, stbl.end)) {
      final data = box.dataStart;
      switch (box.type) {
        case 'stsd':
          if (_reader.uint(data + 4, 4) > 0) track.codec = _fourCc(data + 12);
        case 'stts':
          final count = _reader.uint(data + 4, 4);
          track.timeToSample = [
            for (var index = 0; index < count; index++)
              (
                _reader.uint(data + 8 + index * 8, 4),
                _reader.uint(data + 12 + index * 8, 4),
              ),
          ];
        case 'stsz':
          track.fixedSampleSize = _reader.uint(data + 4, 4);
          track.sampleCount = _reader.uint(data + 8, 4);
          if (track.fixedSampleSize == 0) {
            track.sampleSizes = [
              for (var index = 0; index < track.sampleCount; index++)
                _reader.uint(data + 12 + index * 4, 4),
            ];
          }
        case 'stsc':
          final count = _reader.uint(data + 4, 4);
          track.sampleToChunk = [
            for (var index = 0; index < count; index++)
              (
                _reader.uint(data + 8 + index * 12, 4),
                _reader.uint(data + 12 + index * 12, 4),
              ),
          ];
        case 'stco' || 'co64':
          final width = box.type == 'co64' ? 8 : 4;
          final count = _reader.uint(data + 4, 4);
          track.chunkOffsets = [
            for (var index = 0; index < count; index++)
              _reader.uint(data + 8 + index * width, width),
          ];
      }
    }
  }

  List<int> _sampleOffsets(_Mp4Track track) {
    final offsets = <int>[];
    final runs = track.sampleToChunk;
    for (var chunk = 0; chunk < track.chunkOffsets.length; chunk++) {
      var samplesInChunk = 0;
      for (final (firstChunk, perChunk) in runs) {
        if (firstChunk - 1 <= chunk) samplesInChunk = perChunk;
      }
      var offset = track.chunkOffsets[chunk];
      for (var index = 0; index < samplesInChunk; index++) {
        if (offsets.length >= track.sampleCount) return offsets;
        offsets.add(offset);
        offset += _sampleSize(track, offsets.length - 1);
      }
    }
    return offsets;
  }

  int _sampleSize(_Mp4Track track, int sample) => track.fixedSampleSize != 0
      ? track.fixedSampleSize
      : sample < track.sampleSizes.length
      ? track.sampleSizes[sample]
      : 0;

  String _sampleText(int offset, int size) {
    if (size < 2 || offset + size > _reader.length) return '';
    final length = _reader.uint(offset, 2).clamp(0, size - 2);
    if (length == 0) return '';
    final bytes = _reader.bytes(offset + 2, length);
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      final units = <int>[
        for (var index = 2; index + 1 < bytes.length; index += 2)
          (bytes[index] << 8) | bytes[index + 1],
      ];
      return String.fromCharCodes(units).trim();
    }
    return utf8.decode(bytes, allowMalformed: true).trim();
  }

  _Box? _find(int start, int end, String type) =>
      _boxes(start, end).where((box) => box.type == type).firstOrNull;

  Iterable<_Box> _boxes(int start, int end) sync* {
    var position = start;
    while (position + 8 <= end) {
      var size = _reader.uint(position, 4);
      final type = _fourCc(position + 4);
      var header = 8;
      if (size == 1) {
        size = _reader.uint(position + 8, 8);
        header = 16;
      } else if (size == 0) {
        size = end - position;
      }
      if (size < header) return;
      final boxEnd = (position + size).clamp(0, end);
      yield _Box(type, position + header, boxEnd);
      position += size;
    }
  }

  String _fourCc(int position) =>
      String.fromCharCodes(_reader.bytes(position, 4));
}

String? _language(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed == 'und') return null;
  return trimmed;
}
