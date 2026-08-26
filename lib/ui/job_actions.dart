import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import '../state/podcast_controller.dart';
import 'app_notice.dart';

Future<bool> chooseAndRelink(BuildContext context, String jobId) async {
  final file = await openFile();
  if (file == null || !context.mounted) return false;
  final errorCode = await context.read<AppController>().relink(
    jobId,
    file.path,
  );
  if (!context.mounted) return errorCode == null;
  if (errorCode != null) {
    showAppNotice(
      context,
      message: context.strings.error(errorCode),
      tone: AppNoticeTone.error,
    );
    return false;
  }
  return true;
}

Future<bool> chooseAndReplaceSubtitle(
  BuildContext context,
  TranscriptionJob job,
) async {
  final discardsDerivedWork =
      job.document?.tokens.isNotEmpty == true ||
      job.document?.segments.any(
            (segment) => segment.translatedText?.isNotEmpty == true,
          ) ==
          true ||
      job.translationState.status != TranslationStatus.idle ||
      job.aiBrief != null;
  if (discardsDerivedWork) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.strings.t('replace_subtitle_title')),
        content: Text(context.strings.t('replace_subtitle_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.strings.t('replace')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;
  }
  final file = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        label: context.strings.t('subtitles'),
        extensions: const ['srt', 'vtt'],
      ),
    ],
  );
  if (file == null || !context.mounted) return false;
  final errorCode = await context.read<AppController>().replaceImportedSubtitle(
    job.id,
    file.path,
  );
  if (!context.mounted) return errorCode == null;
  if (errorCode != null) {
    showAppNotice(
      context,
      message: context.strings.error(errorCode),
      tone: AppNoticeTone.error,
    );
    return false;
  }
  return true;
}

Future<bool> confirmAndRemoveLibraryJobs(
  BuildContext context,
  Iterable<TranscriptionJob> jobs,
) async {
  final controller = context.read<AppController>();
  final uniqueJobs = <String, TranscriptionJob>{
    for (final job in jobs) job.id: job,
  }.values.toList(growable: false);
  if (uniqueJobs.isEmpty || uniqueJobs.any((job) => job.isBusy)) return false;

  final podcastJobIds = controller.podcastJobs.map((job) => job.id).toSet();
  final podcastJobs = uniqueJobs
      .where((job) => podcastJobIds.contains(job.id))
      .toList(growable: false);
  final allPodcast = podcastJobs.length == uniqueJobs.length;
  final strings = context.strings;
  final title = strings.t(
    allPodcast
        ? uniqueJobs.length == 1
              ? 'remove_podcast_title'
              : 'remove_podcasts_title'
        : 'remove_selected_title',
  );
  final body = strings
      .t(
        allPodcast
            ? uniqueJobs.length == 1
                  ? 'remove_podcast_body'
                  : 'remove_podcasts_body'
            : podcastJobs.isNotEmpty
            ? 'remove_selected_with_podcasts_body'
            : 'remove_selected_body',
      )
      .replaceFirst('{count}', '${uniqueJobs.length}');
  final podcast = podcastJobs.isEmpty
      ? null
      : _optionalPodcastController(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(strings.t('cancel')),
        ),
        FilledButton(
          key: const Key('confirm-remove-library-jobs'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(
            strings.t(uniqueJobs.length == 1 ? 'remove' : 'remove_selected'),
          ),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  final activeEpisodeId = podcast?.playback.episode?.id;
  if (activeEpisodeId != null &&
      podcastJobs.any(
        (job) =>
            (job.podcastProvenance?.episodeId ?? job.id) == activeEpisodeId,
      )) {
    await podcast!.playback.stop();
  }
  for (final job in uniqueJobs) {
    await controller.deleteHistory(job.id);
  }
  return true;
}

PodcastController? _optionalPodcastController(BuildContext context) {
  try {
    return context.read<PodcastController>();
  } on ProviderNotFoundException {
    return null;
  }
}
