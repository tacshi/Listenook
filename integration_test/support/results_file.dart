import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Name of the results file in the app's Documents folder.
const integrationResultsFile = 'integration_test_results.json';

/// Saves this run's results in the app's Documents folder once every test has
/// finished, so a run without a debugger can collect them: devices on Wi-Fi
/// often cannot reach the test app's debug service
/// (scripts/test-ios-integration.sh).
void saveResultsWhenDone(IntegrationTestWidgetsFlutterBinding binding) {
  // Profile builds drop error descriptions, so keep the exception itself.
  final errors = <String, String>{};
  final report = reportTestException;
  reportTestException = (details, description) {
    errors[description] = '${details.exception}\n${details.stack}';
    report(details, description);
  };
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      final directory = await getApplicationDocumentsDirectory();
      await File(p.join(directory.path, integrationResultsFile)).writeAsString(
        jsonEncode({
          'passed': passed,
          // Seconds since the epoch, so a collector can skip older runs.
          'finished': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'results': {
            for (final entry in binding.results.entries)
              entry.key: switch (entry.value) {
                Failure(:final details) =>
                  errors[entry.key] ?? details ?? 'failed',
                _ => 'success',
              },
          },
        }),
      );
    }),
  );
}
