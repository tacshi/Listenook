import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../l10n/strings.dart';
import '../state/app_controller.dart';
import 'app_notice.dart';
import 'platform/export_destination.dart';

Future<void> showTranscriptExportDialog(
  BuildContext context, {
  required List<String> jobIds,
}) async {
  if (jobIds.isEmpty) return;
  final controller = context.read<AppController>();
  var options = controller.settings.exportOptions.copyWith(
    localeCode: Localizations.localeOf(context).languageCode,
  );
  final batch = jobIds.length > 1;
  var zip = false;
  final selected = await showDialog<({ExportOptions options, bool zip})>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(context.strings.t('export')),
        content: SizedBox(
          width: 410,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<ExportFormat>(
                isExpanded: true,
                initialValue: options.format,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.description_outlined),
                ),
                items: [
                  DropdownMenuItem(
                    value: ExportFormat.txt,
                    child: Text(context.strings.t('plain_text')),
                  ),
                  DropdownMenuItem(
                    value: ExportFormat.markdown,
                    child: Text(context.strings.t('markdown')),
                  ),
                  DropdownMenuItem(
                    value: ExportFormat.srt,
                    child: Text(context.strings.t('srt')),
                  ),
                  DropdownMenuItem(
                    value: ExportFormat.webVtt,
                    child: Text(context.strings.t('vtt')),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => options = options.copyWith(format: value)),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ExportContentMode>(
                isExpanded: true,
                key: const Key('export-content-mode'),
                initialValue: options.contentMode,
                decoration: InputDecoration(
                  labelText: context.strings.t('export_content'),
                  prefixIcon: const Icon(Icons.translate_rounded),
                ),
                items: [
                  DropdownMenuItem(
                    value: ExportContentMode.original,
                    child: Text(context.strings.t('original')),
                  ),
                  DropdownMenuItem(
                    value: ExportContentMode.translated,
                    child: Text(context.strings.t('translated')),
                  ),
                  DropdownMenuItem(
                    value: ExportContentMode.bilingual,
                    child: Text(context.strings.t('bilingual')),
                  ),
                ],
                onChanged: (value) => setState(
                  () => options = options.copyWith(contentMode: value),
                ),
              ),
              if (options.contentMode != ExportContentMode.original &&
                  _hasIncompleteTranslations(controller, jobIds))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.strings.t('partial_export_warning'),
                        ),
                      ),
                    ],
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.strings.t('speaker_labels')),
                value: options.showSpeakers,
                onChanged: (value) => setState(
                  () => options = options.copyWith(showSpeakers: value),
                ),
              ),
              if (batch)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.strings.t('batch_zip')),
                  value: zip,
                  onChanged: (value) => setState(() => zip = value),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.strings.t('timestamps')),
                subtitle:
                    options.format == ExportFormat.srt ||
                        options.format == ExportFormat.webVtt
                    ? Text(context.strings.t('subtitle_timing_required'))
                    : null,
                value:
                    options.format == ExportFormat.srt ||
                        options.format == ExportFormat.webVtt
                    ? true
                    : options.showTimestamps,
                onChanged:
                    options.format == ExportFormat.srt ||
                        options.format == ExportFormat.webVtt
                    ? null
                    : (value) => setState(
                        () => options = options.copyWith(showTimestamps: value),
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.strings.t('cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, (options: options, zip: zip)),
            child: Text(context.strings.t('export')),
          ),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  final ExportTarget? target;
  if (selected.zip) {
    target = await ExportTarget.file(
      context,
      suggestedName: 'Listenook-transcripts.zip',
      acceptedTypeGroups: [
        XTypeGroup(
          label: context.strings.t('zip_archive'),
          extensions: const ['zip'],
        ),
      ],
    );
    if (target == null || !context.mounted) return;
    await controller.exportJobsZip(jobIds, target.path, selected.options);
  } else {
    target = await ExportTarget.folder(
      context,
      confirmButtonText: context.strings.t('export'),
    );
    if (target == null || !context.mounted) return;
    await controller.exportJobs(jobIds, target.path, selected.options);
  }
  await controller.updateSettings(
    controller.settings.copyWith(exportOptions: selected.options),
  );
  if (!await target.deliver()) return;
  if (context.mounted) {
    showAppNotice(
      context,
      message: context.strings.t('exported'),
      tone: AppNoticeTone.success,
    );
  }
}

bool _hasIncompleteTranslations(AppController controller, List<String> jobIds) {
  final ids = jobIds.toSet();
  return controller.allJobs
      .where((job) => ids.contains(job.id))
      .any(
        (job) =>
            job.document?.segments.any((segment) => !segment.hasTranslation) ??
            false,
      );
}
