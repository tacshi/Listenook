import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_controller.dart';

Future<bool> chooseAndRelink(BuildContext context, String jobId) async {
  final file = await openFile();
  if (file == null || !context.mounted) return false;
  final errorCode = await context.read<AppController>().relink(
    jobId,
    file.path,
  );
  if (!context.mounted) return errorCode == null;
  if (errorCode != null) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.strings.error(errorCode))));
    return false;
  }
  return true;
}
