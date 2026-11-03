import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/app_identity.dart';
import '../../data/managed_media_store.dart';
import 'platform_context.dart';

/// Uniform type identifiers for the extensions Listenook opens. The iOS
/// document picker filters by type only; the ones iOS does not know are
/// declared in ios/Runner/Info.plist (UTImportedTypeDeclarations).
const _typeIdentifiers = {
  'mp3': 'public.mp3',
  'wav': 'com.microsoft.waveform-audio',
  'm4a': 'com.apple.m4a-audio',
  'ogg': 'org.xiph.ogg-audio',
  'flac': 'org.xiph.flac',
  'mp4': 'public.mpeg-4',
  'm4v': 'com.apple.m4v-video',
  'mov': 'com.apple.quicktime-movie',
  'mkv': 'org.matroska.mkv',
  'webm': 'org.webmproject.webm',
  'avi': 'public.avi',
  'wmv': 'com.microsoft.windows-media-wmv',
  'flv': 'com.adobe.flash.video',
  'ts': 'public.mpeg-2-transport-stream',
  'm2ts': 'public.avchd-mpeg-2-transport-stream',
  'mts': 'public.avchd-mpeg-2-transport-stream',
  'mpg': 'public.mpeg',
  'mpeg': 'public.mpeg',
  'ogv': 'org.xiph.ogg-video',
  '3gp': 'public.3gpp',
  'srt': 'com.subrip.srt',
  'vtt': 'org.w3.webvtt',
  'ass': 'org.aegisub.ass',
  'ssa': 'org.aegisub.ssa',
};

/// A picker filter for [extensions]. Type identifiers are added only where
/// the picker needs them, since on macOS they would widen the filter.
XTypeGroup fileTypeGroup(
  BuildContext context, {
  required String label,
  required Iterable<String> extensions,
}) {
  final values = extensions.toList(growable: false);
  return XTypeGroup(
    label: label,
    extensions: values,
    uniformTypeIdentifiers: context.capabilities.sandboxedFiles
        ? {
            for (final extension in values)
              if (_typeIdentifiers[extension] case final type?) type,
          }.toList(growable: false)
        : null,
  );
}

/// Picks files with the system picker and returns paths the app can keep
/// using. In the iOS sandbox the picker hands over temporary copies; with
/// [keep] they are moved into Listenook's own storage first.
Future<List<String>> pickFiles(
  BuildContext context, {
  required List<XTypeGroup> acceptedTypeGroups,
  bool multiple = true,
  bool keep = true,
}) async {
  final store = keep ? _store(context) : null;
  final files = multiple
      ? await openFiles(acceptedTypeGroups: acceptedTypeGroups)
      : [?await openFile(acceptedTypeGroups: acceptedTypeGroups)];
  final paths = files.map((file) => file.path).toList(growable: false);
  if (paths.isEmpty || store == null) return paths;
  return store.adopt(paths);
}

/// Picks a folder. On iOS the system document picker lends the folder only
/// briefly, so its media and subtitles ([extensions]) are copied in first.
Future<String?> pickFolder(
  BuildContext context, {
  required Iterable<String> extensions,
}) async {
  if (context.capabilities.fileDialogs) return getDirectoryPath();
  final store = _store(context);
  final String? copied;
  try {
    copied = await const MethodChannel(
      AppIdentity.filesChannel,
    ).invokeMethod<String>('pickFolder', {'extensions': extensions.toList()});
  } on PlatformException {
    return null;
  }
  if (copied == null || store == null) return copied;
  return (await store.adopt([copied])).single;
}

ManagedMediaStore? _store(BuildContext context) =>
    Provider.of<ManagedMediaStore?>(context, listen: false);
