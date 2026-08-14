import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/core/models.dart';
import 'package:meow_stt/data/inbox_folder_monitor.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Windows monitored identities compare paths case-insensitively', () {
    expect(
      monitoredPathIdentity(r'C:\Inbox\Meeting.WAV', windows: true),
      monitoredPathIdentity(r'c:\inbox\meeting.wav', windows: true),
    );
  });

  test('fingerprints distinguish changed file versions', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meow-monitor-fingerprint-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(p.join(directory.path, 'meeting.wav'));
    await file.writeAsBytes(const [1, 2, 3]);
    final first = await fingerprintMonitoredFile(file.path);
    final duplicate = await fingerprintMonitoredFile(file.path);

    await file.writeAsBytes(const [1, 2, 3, 4, 5]);
    await file.setLastModified(DateTime.now().add(const Duration(seconds: 2)));
    final changed = await fingerprintMonitoredFile(file.path);

    expect(first, isNotNull);
    expect(first!.sameVersion(duplicate!), isTrue);
    expect(first.sameVersion(changed!), isFalse);
  });

  test(
    'recursive scan filters extensions, hidden paths, and symbolic links',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-monitor-scan-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final nested = await Directory(p.join(directory.path, 'nested')).create();
      final hidden = await Directory(
        p.join(directory.path, '.hidden'),
      ).create();
      final source = File(p.join(directory.path, 'source.wav'));
      await source.writeAsBytes(const [1]);
      await File(p.join(nested.path, 'UPPER.WAV')).writeAsBytes(const [1]);
      await File(p.join(nested.path, 'movie.MP4')).writeAsBytes(const [1]);
      await File(p.join(nested.path, 'notes.txt')).writeAsBytes(const [1]);
      await File(p.join(hidden.path, 'secret.wav')).writeAsBytes(const [1]);
      await Link(p.join(directory.path, 'linked.wav')).create(source.path);

      final candidates = <SourceFingerprint>[];
      final monitor = LocalInboxFolderMonitor(
        quietPeriod: const Duration(milliseconds: 30),
        eventDebounce: const Duration(milliseconds: 10),
        reconcileInterval: const Duration(hours: 1),
      );
      addTearDown(monitor.dispose);
      await monitor.start(
        InboxMonitorConfig(
          folderPath: directory.path,
          extensions: const {'wav', 'mp4'},
        ),
        onCandidate: (candidate) async => candidates.add(candidate),
        onSnapshot: (_) async {},
        onStatus: (_, _) {},
      );
      await _waitFor(() => candidates.length == 3);

      expect(
        candidates.map((candidate) => p.basename(candidate.path)).toSet(),
        {'source.wav', 'UPPER.WAV', 'movie.MP4'},
      );
    },
  );

  test(
    'quiet period waits for a slow copy and emits the stable size',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meow-monitor-quiet-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final candidates = <SourceFingerprint>[];
      final monitor = LocalInboxFolderMonitor(
        quietPeriod: const Duration(milliseconds: 80),
        eventDebounce: const Duration(milliseconds: 5),
        reconcileInterval: const Duration(hours: 1),
      );
      addTearDown(monitor.dispose);
      await monitor.start(
        InboxMonitorConfig(
          folderPath: directory.path,
          extensions: const {'wav'},
        ),
        onCandidate: (candidate) async => candidates.add(candidate),
        onSnapshot: (_) async {},
        onStatus: (_, _) {},
      );

      final file = File(p.join(directory.path, 'copying.wav'));
      await file.writeAsBytes(const [1, 2]);
      await monitor.scanNow();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await file.writeAsBytes(const [1, 2, 3, 4, 5], mode: FileMode.append);
      await monitor.scanNow();

      await _waitFor(() => candidates.isNotEmpty);
      expect(candidates, hasLength(1));
      expect(candidates.single.sizeBytes, 7);
    },
  );

  test('unavailable folder is retained and recovered on retry', () async {
    final root = await Directory.systemTemp.createTemp(
      'meow-monitor-unavailable-',
    );
    addTearDown(() => root.delete(recursive: true));
    final watched = Directory(p.join(root.path, 'mounted-later'));
    final statuses = <InboxMonitorStatus>[];
    final candidates = <SourceFingerprint>[];
    final monitor = LocalInboxFolderMonitor(
      quietPeriod: const Duration(milliseconds: 20),
      retryDelay: const Duration(milliseconds: 30),
      reconcileInterval: const Duration(hours: 1),
    );
    addTearDown(monitor.dispose);
    await monitor.start(
      InboxMonitorConfig(folderPath: watched.path, extensions: const {'wav'}),
      onCandidate: (candidate) async => candidates.add(candidate),
      onSnapshot: (_) async {},
      onStatus: (status, _) => statuses.add(status),
    );
    expect(statuses, contains(InboxMonitorStatus.unavailable));

    await watched.create();
    await File(p.join(watched.path, 'returned.wav')).writeAsBytes(const [1]);
    await _waitFor(() => candidates.isNotEmpty);

    expect(statuses, contains(InboxMonitorStatus.active));
    expect(p.basename(candidates.single.path), 'returned.wav');
  });

  test('successful scans report the current monitored identities', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meow-monitor-snapshot-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File(p.join(directory.path, 'meeting.wav'));
    await source.writeAsBytes(const [1, 2, 3]);
    final snapshots = <Set<String>>[];
    final monitor = LocalInboxFolderMonitor(
      quietPeriod: const Duration(milliseconds: 20),
      reconcileInterval: const Duration(hours: 1),
    );
    addTearDown(monitor.dispose);
    await monitor.start(
      InboxMonitorConfig(folderPath: directory.path, extensions: const {'wav'}),
      onCandidate: (_) async {},
      onSnapshot: (identities) async => snapshots.add(identities),
      onStatus: (_, _) {},
    );

    expect(snapshots.last, {monitoredPathIdentity(source.path)});

    await source.delete();
    await monitor.scanNow();

    expect(snapshots.last, isEmpty);
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
