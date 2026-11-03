import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/app_identity.dart';
import 'platform_context.dart';

/// Where an export is written. On desktop the user picks a file or folder
/// first. On iOS there are no save dialogs: the export is written to a
/// temporary folder, then [deliver] hands it to the share sheet, whose
/// "Save to Files" stands in for the dialog.
class ExportTarget {
  ExportTarget._(this.path, {Directory? staging, Rect? anchor})
    : _staging = staging,
      _anchor = anchor;

  /// The file or folder to write to.
  final String path;
  final Directory? _staging;
  final Rect? _anchor;

  /// A file the user picks with a save dialog, or a temporary one on iOS.
  static Future<ExportTarget?> file(
    BuildContext context, {
    required String suggestedName,
    required List<XTypeGroup> acceptedTypeGroups,
    String? confirmButtonText,
  }) async {
    if (!context.capabilities.fileDialogs) {
      final anchor = _anchorOf(context);
      final staging = await _createStaging();
      return ExportTarget._(
        p.join(staging.path, suggestedName),
        staging: staging,
        anchor: anchor,
      );
    }
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: acceptedTypeGroups,
      confirmButtonText: confirmButtonText,
    );
    return location == null ? null : ExportTarget._(location.path);
  }

  /// A folder the user picks, or a temporary one on iOS whose files are all
  /// shared.
  static Future<ExportTarget?> folder(
    BuildContext context, {
    String? confirmButtonText,
  }) async {
    if (!context.capabilities.fileDialogs) {
      final anchor = _anchorOf(context);
      final staging = await _createStaging();
      return ExportTarget._(staging.path, staging: staging, anchor: anchor);
    }
    final directory = await getDirectoryPath(
      confirmButtonText: confirmButtonText,
    );
    return directory == null ? null : ExportTarget._(directory);
  }

  /// Finishes the export once it is written. Returns false when the user
  /// dismissed the share sheet without saving or sending it.
  Future<bool> deliver() async {
    final staging = _staging;
    if (staging == null) return true;
    try {
      final files = await staging
          .list(recursive: true)
          .where((entity) => entity is File)
          .map((entity) => entity.path)
          .toList();
      if (files.isEmpty) return false;
      final anchor = _anchor;
      return await const MethodChannel(
            AppIdentity.filesChannel,
          ).invokeMethod<bool>('share', {
            'paths': files..sort(),
            if (anchor != null)
              'anchor': [anchor.left, anchor.top, anchor.width, anchor.height],
          }) ??
          false;
    } finally {
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        // Temporary files: the system clears them eventually.
      }
    }
  }

  static Future<Directory> _createStaging() => Directory(
    p.join(Directory.systemTemp.path, 'Exports', const Uuid().v4()),
  ).create(recursive: true);

  /// The widget that started the export, for the iPad share popover.
  static Rect? _anchorOf(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}
