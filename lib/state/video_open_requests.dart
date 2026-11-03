import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/app_identity.dart';

const supportedPlayerVideoExtensions = {
  'mp4',
  'm4v',
  'mov',
  'mkv',
  'webm',
  'avi',
  'wmv',
  'flv',
  'ts',
  'm2ts',
  'mts',
  'mpg',
  'mpeg',
  'ogv',
  '3gp',
};

bool isPlayerVideoPath(String path) => supportedPlayerVideoExtensions.contains(
  p.extension(path).replaceFirst('.', '').toLowerCase(),
);

/// Audio and subtitles the Inbox accepts from other apps. Folders are
/// accepted too: the Inbox lists the media inside.
bool isImportablePath(String path) =>
    FileSystemEntity.isDirectorySync(path) ||
    const {
      'mp3',
      'wav',
      'm4a',
      'ogg',
      'srt',
      'vtt',
      'ass',
      'ssa',
    }.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

/// Videos the operating system asked Listenook to open (double-click,
/// "Open With", or a file passed on the command line), waiting for the app
/// shell to show them in the standalone player.
class VideoOpenRequests extends ChangeNotifier {
  VideoOpenRequests({MethodChannel? channel, this.acceptsImports = false})
    : _channel = channel ?? const MethodChannel(AppIdentity.openFilesChannel);

  final MethodChannel _channel;
  final List<String> _pending = [];
  final List<String> _imports = [];

  /// iOS: audio and subtitles opened from other apps (or dropped on the app)
  /// are queued for the Inbox instead of being ignored.
  final bool acceptsImports;

  bool get hasPending => _pending.isNotEmpty;

  bool get hasImports => _imports.isNotEmpty;

  void addAll(Iterable<String> paths) {
    var added = false;
    for (final path in paths) {
      if (path.startsWith('-')) continue;
      final video = isPlayerVideoPath(path);
      if (!video && !(acceptsImports && isImportablePath(path))) continue;
      final absolute = p.normalize(p.absolute(path));
      if (!File(absolute).existsSync() && !Directory(absolute).existsSync()) {
        continue;
      }
      final queue = video ? _pending : _imports;
      queue
        ..remove(absolute)
        ..add(absolute);
      added = true;
    }
    if (added) notifyListeners();
  }

  /// Everything queued for the Inbox, oldest first.
  List<String> takeImports() {
    final imports = List<String>.of(_imports);
    _imports.clear();
    return imports;
  }

  /// The most recently requested video. Older requests are dropped: opening
  /// several videos at once plays the last one, like a single-window player.
  String? takeLatest() {
    if (_pending.isEmpty) return null;
    final latest = _pending.last;
    _pending.clear();
    return latest;
  }

  /// Receives files the runner delivers (macOS `application(_:open:)`; iOS
  /// "Open in", "Copy to" and drops), including the ones that arrived before
  /// Flutter started.
  Future<void> attachNativeInbox() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openFilesAvailable') await _drainNativeInbox();
      return null;
    });
    await _drainNativeInbox();
  }

  /// Whether macOS launched the app to open documents, which may still be on
  /// their way when Dart starts.
  Future<bool> launchedForFiles() async {
    try {
      return await _channel.invokeMethod<bool>('launchedForFiles') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _drainNativeInbox() async {
    try {
      final paths = await _channel.invokeListMethod<String>(
        'takePendingOpenFiles',
      );
      if (paths != null) addAll(paths);
    } on MissingPluginException {
      // Platforms without a native inbox pass files as launch arguments.
    } on PlatformException {
      // A failed hand-off only loses the open request.
    }
  }
}
