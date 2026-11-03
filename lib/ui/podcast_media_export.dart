import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'app_notice.dart';
import 'platform/export_destination.dart';

Future<void> exportDownloadedPodcastMedia(
  BuildContext context,
  TranscriptionJob job,
) async {
  final extension = p.extension(job.sourcePath).replaceFirst('.', '');
  final target = await ExportTarget.file(
    context,
    suggestedName: p.basename(job.sourcePath),
    acceptedTypeGroups: [
      XTypeGroup(
        label: context.strings.t('audio_video'),
        extensions: extension.isEmpty ? const [] : [extension],
      ),
    ],
  );
  if (target == null || !context.mounted) return;
  final controller = context.read<AppController>();
  await completePodcastMediaExport(context, () async {
    final exported = await controller.exportPodcastMedia(job.id, target.path);
    return await target.deliver() ? exported : null;
  });
}

Future<void> exportDownloadedPodcastMediaBatch(
  BuildContext context,
  Iterable<TranscriptionJob> jobs,
) async {
  final selected = jobs.toList(growable: false);
  if (selected.isEmpty) return;
  final target = await ExportTarget.folder(
    context,
    confirmButtonText: context.strings.t('export'),
  );
  if (target == null || !context.mounted) return;
  final controller = context.read<AppController>();
  await completePodcastMediaBatchExport(context, () async {
    final exported = await exportPodcastMediaFilesToDirectory(
      selected,
      target.path,
      (job, destination) => controller.exportPodcastMedia(job.id, destination),
    );
    return await target.deliver() ? exported.length : null;
  });
}

@visibleForTesting
Future<List<String>> exportPodcastMediaFilesToDirectory(
  Iterable<TranscriptionJob> jobs,
  String directory,
  Future<String> Function(TranscriptionJob job, String destination) export,
) async {
  final exported = <String>[];
  final reservedPaths = <String>{};
  for (final job in jobs) {
    final destination = await _availableExportPath(
      directory,
      job.fileName,
      reservedPaths,
    );
    exported.add(await export(job, destination));
  }
  return exported;
}

Future<String> _availableExportPath(
  String directory,
  String fileName,
  Set<String> reservedPaths,
) async {
  final extension = p.extension(fileName);
  final stem = p.basenameWithoutExtension(fileName);
  var counter = 1;
  var candidate = p.join(directory, fileName);
  while (reservedPaths.contains(p.normalize(candidate).toLowerCase()) ||
      await File(candidate).exists()) {
    counter++;
    candidate = p.join(directory, '$stem ($counter)$extension');
  }
  reservedPaths.add(p.normalize(candidate).toLowerCase());
  return candidate;
}

@visibleForTesting
Future<void> completePodcastMediaExport(
  BuildContext context,
  // Null when the user dismissed the iOS share sheet.
  Future<String?> Function() export,
) async {
  try {
    if (await export() == null || !context.mounted) return;
    showAppNotice(
      context,
      message: context.strings.t('podcast_media_exported'),
      tone: AppNoticeTone.success,
    );
  } on Object {
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: context.strings.t('podcast_media_export_failed'),
      tone: AppNoticeTone.error,
    );
  }
}

@visibleForTesting
Future<void> completePodcastMediaBatchExport(
  BuildContext context,
  // Null when the user dismissed the iOS share sheet.
  Future<int?> Function() export,
) async {
  try {
    final count = await export();
    if (count == null || !context.mounted) return;
    showAppNotice(
      context,
      message: context.strings
          .t('podcast_media_batch_exported')
          .replaceFirst('{count}', '$count'),
      tone: AppNoticeTone.success,
    );
  } on Object {
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: context.strings.t('podcast_media_batch_export_failed'),
      tone: AppNoticeTone.error,
    );
  }
}
