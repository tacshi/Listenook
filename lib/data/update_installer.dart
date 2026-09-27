import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/update_models.dart';

abstract class UpdateInstaller {
  const UpdateInstaller();

  Future<void> launch(File file, UpdateAsset asset);

  factory UpdateInstaller.forCurrentPlatform() {
    if (Platform.isMacOS) return MacosUpdateInstaller();
    if (Platform.isWindows) return WindowsUpdateInstaller();
    return const UnsupportedUpdateInstaller();
  }
}

class UnsupportedUpdateInstaller extends UpdateInstaller {
  const UnsupportedUpdateInstaller();

  @override
  Future<void> launch(File file, UpdateAsset asset) async {
    throw const UpdateInstallException(
      'Automatic installation is unavailable on this platform.',
    );
  }
}

class WindowsUpdateInstaller extends UpdateInstaller {
  WindowsUpdateInstaller({
    @visibleForTesting
    Future<Process> Function(String, List<String>, ProcessStartMode)? start,
  }) : _start =
           start ??
           ((executable, arguments, mode) =>
               Process.start(executable, arguments, mode: mode));

  static const fallbackArgs = <String>[
    '/SILENT',
    '/NOCANCEL',
    '/NORESTART',
    '/CLOSEAPPLICATIONS',
    '/relaunch=1',
  ];

  final Future<Process> Function(
    String executable,
    List<String> arguments,
    ProcessStartMode mode,
  )
  _start;

  @override
  Future<void> launch(File file, UpdateAsset asset) async {
    if (asset.kind != UpdateInstallKind.innoSetup) {
      throw const UpdateInstallException(
        'The Windows update is not an installer.',
      );
    }
    final args = asset.silentArgs.isEmpty ? fallbackArgs : asset.silentArgs;
    try {
      await _start(file.path, args, ProcessStartMode.detached);
    } on Object catch (error) {
      throw UpdateInstallException(
        'Could not start the update installer: $error',
      );
    }
  }
}

class MacosUpdateInstaller extends UpdateInstaller {
  MacosUpdateInstaller({
    @visibleForTesting String? executablePath,
    @visibleForTesting
    Future<ProcessResult> Function(String, List<String>)? run,
    @visibleForTesting
    Future<Process> Function(String, List<String>, ProcessStartMode)? start,
    @visibleForTesting int? processId,
  }) : _executablePath = executablePath ?? Platform.resolvedExecutable,
       _run = run ?? Process.run,
       _start =
           start ??
           ((executable, arguments, mode) =>
               Process.start(executable, arguments, mode: mode)),
       _processId = processId ?? pid;

  final String _executablePath;
  final Future<ProcessResult> Function(String, List<String>) _run;
  final Future<Process> Function(
    String executable,
    List<String> arguments,
    ProcessStartMode mode,
  )
  _start;
  final int _processId;

  @override
  Future<void> launch(File file, UpdateAsset asset) async {
    if (asset.kind != UpdateInstallKind.appZip) {
      throw const UpdateInstallException(
        'The macOS update is not an app archive.',
      );
    }
    final target = installedBundlePath();
    if (target == null) {
      throw const UpdateInstallException(
        'Listenook must be installed in a writable folder before it can update.',
      );
    }

    final staging = Directory(p.join(file.parent.path, 'staging'));
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    final extract = await _run('/usr/bin/ditto', [
      '-x',
      '-k',
      file.path,
      staging.path,
    ]);
    if (extract.exitCode != 0) {
      throw UpdateInstallException(
        'Could not extract the update: ${extract.stderr}',
      );
    }
    final bundle = await _findBundle(staging);
    if (bundle == null) {
      throw const UpdateInstallException(
        'The update does not contain Listenook.app.',
      );
    }
    final codesign = await _run('/usr/bin/codesign', [
      '--verify',
      '--strict',
      '--deep',
      bundle,
    ]);
    if (codesign.exitCode != 0) {
      throw const UpdateInstallException(
        'The update has an invalid code signature.',
      );
    }
    final gatekeeper = await _run('/usr/sbin/spctl', [
      '--assess',
      '--type',
      'execute',
      bundle,
    ]);
    if (gatekeeper.exitCode != 0) {
      throw const UpdateInstallException('Gatekeeper rejected the update.');
    }

    final helper = File(p.join(file.parent.path, 'install-update.sh'));
    await helper.writeAsString(_helperScript);
    final chmod = await _run('/bin/chmod', ['+x', helper.path]);
    if (chmod.exitCode != 0) {
      throw const UpdateInstallException(
        'Could not prepare the update helper.',
      );
    }
    try {
      await _start('/bin/sh', [
        helper.path,
        '$_processId',
        bundle,
        target,
      ], ProcessStartMode.detached);
    } on Object catch (error) {
      throw UpdateInstallException('Could not start the update helper: $error');
    }
  }

  Future<String?> _findBundle(Directory staging) async {
    await for (final entry in staging.list()) {
      if (entry is Directory && p.basename(entry.path) == 'Listenook.app') {
        return entry.path;
      }
    }
    return null;
  }

  @visibleForTesting
  String? installedBundlePath() {
    final bundle = p.dirname(p.dirname(p.dirname(_executablePath)));
    if (p.basename(bundle) != 'Listenook.app' ||
        p.isWithin('/Volumes', bundle)) {
      return null;
    }
    final parent = Directory(p.dirname(bundle));
    try {
      final probe = File(p.join(parent.path, '.listenook-update-probe'));
      probe.writeAsStringSync('');
      probe.deleteSync();
    } on Object {
      return null;
    }
    return bundle;
  }

  @visibleForTesting
  static const helperScript = _helperScript;

  static const _helperScript = r'''#!/bin/sh
set -u
old_pid="$1"
source_app="$2"
target_app="$3"
new_app="${target_app}.update-new"
backup_app="${target_app}.update-backup"

i=0
while kill -0 "$old_pid" 2>/dev/null && [ "$i" -lt 150 ]; do
  sleep 0.2
  i=$((i+1))
done
if kill -0 "$old_pid" 2>/dev/null; then exit 1; fi

rm -rf "$new_app" "$backup_app"
/usr/bin/ditto "$source_app" "$new_app" || exit 1
/usr/bin/xattr -dr com.apple.quarantine "$new_app" 2>/dev/null || true

/bin/mv "$target_app" "$backup_app" || exit 1
if ! /bin/mv "$new_app" "$target_app"; then
  /bin/mv "$backup_app" "$target_app" 2>/dev/null || true
  exit 1
fi

/bin/rm -rf "$backup_app"
/usr/bin/open "$target_app"
''';
}
