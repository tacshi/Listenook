import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/data/app_data_migration.dart';

void main() {
  late Directory fixture;
  late Directory oldRoot;
  late Directory target;
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp(
      'listenook-migration-test-',
    );
    oldRoot = Directory('${fixture.path}/old/MeowSTT');
    target = Directory('${fixture.path}/new');
  });
  tearDown(() => fixture.delete(recursive: true));

  Future<File> put(String relative, String contents, {Directory? root}) async {
    final file = File('${(root ?? oldRoot).path}/$relative');
    await file.parent.create(recursive: true);
    return file.writeAsString(contents);
  }

  AppDataMigration migration({
    Future<bool> Function()? running,
    Future<void> Function(File, File)? copy,
    bool windows = false,
  }) => AppDataMigration(
    destination: target,
    legacyRoot: oldRoot,
    isLegacyRunning: running ?? () async => false,
    windows: windows,
    copyFile: copy,
  );

  test(
    'fresh installation initializes once without probing old processes',
    () async {
      await migration(
        running: () async => throw StateError('unexpected'),
      ).run();
      expect(
        File('${target.path}/${AppDataMigration.markerName}').existsSync(),
        isTrue,
      );
      expect(oldRoot.existsSync(), isFalse);
    },
  );

  test(
    'copies library, models and audio while only relocating owned paths',
    () async {
      final original = jsonEncode({
        'source_path': '${oldRoot.path}/podcasts/one/audio.m4a',
        'display_title': 'MeowSTT is mentioned here',
        'source_fingerprint': {
          'path': '${oldRoot.path}/podcasts/one/audio.m4a',
          'identity': '${oldRoot.path}/podcasts/one/audio.m4a',
        },
        'document': {
          'text': 'Keep ${oldRoot.path} and MeowSTT in this transcript',
        },
        'imported_subtitle_provenance': {
          'source_path': '/Users/demo/MeowSTT/sub.srt',
          'cue_snapshot': [
            {'text': 'MeowSTT', 'start_ms': 10},
          ],
        },
      });
      await put('jobs/one/manifest.json', original);
      await put('settings.json', '{"locale_mode":"simplifiedChinese"}');
      await put('podcasts/one/audio.m4a', 'audio data');
      await put('podcast_catalog.json', '{"shows":[]}');
      await put('podcast_playback.json', '{"one":42}');
      await put('models/qwen/weights.bin', 'model data');
      await put('models/.qwen-new.part/weights.bin', 'incomplete');
      await put('temporary/input.wav', 'temporary');
      await put('updates/old.zip', 'old update');
      final owned = '${oldRoot.path}/podcasts/one/audio.m4a';
      await put(
        'inbox_monitor.json',
        jsonEncode({
          'config': {'folder_path': oldRoot.path},
          'records': {
            owned: {
              'fingerprint': {'path': owned, 'identity': owned},
              'disposition': 'imported',
              'job_id': 'one',
            },
          },
        }),
      );

      await migration().run();
      final data = jsonDecode(
        File('${target.path}/jobs/one/manifest.json').readAsStringSync(),
      );
      expect(data['source_path'], '${target.path}/podcasts/one/audio.m4a');
      expect(data['source_fingerprint']['identity'], data['source_path']);
      expect(
        data['document']['text'],
        'Keep ${oldRoot.path} and MeowSTT in this transcript',
      );
      expect(data['display_title'], 'MeowSTT is mentioned here');
      expect(
        data['imported_subtitle_provenance']['source_path'],
        '/Users/demo/MeowSTT/sub.srt',
      );
      expect(
        data['imported_subtitle_provenance']['cue_snapshot'][0]['text'],
        'MeowSTT',
      );
      expect(
        File('${oldRoot.path}/jobs/one/manifest.json').readAsStringSync(),
        original,
      );
      for (final file in [
        'podcasts/one/audio.m4a',
        'models/qwen/weights.bin',
        'settings.json',
        'podcast_catalog.json',
        'podcast_playback.json',
      ]) {
        expect(
          File('${target.path}/$file').readAsBytesSync(),
          File('${oldRoot.path}/$file').readAsBytesSync(),
        );
      }
      for (final path in ['models/.qwen-new.part', 'temporary', 'updates']) {
        expect(Directory('${target.path}/$path').existsSync(), isFalse);
      }
      final ledger = jsonDecode(
        File('${target.path}/inbox_monitor.json').readAsStringSync(),
      );
      expect(ledger['config']['folder_path'], target.path);
      expect((ledger['records'] as Map).keys, [
        '${target.path}/podcasts/one/audio.m4a',
      ]);
    },
  );

  test(
    'existing new data wins and a second launch never reimports old data',
    () async {
      await put('settings.json', '{"old":true}');
      await put('settings.json', '{"new":true}', root: target);
      await migration(running: () async => true).run();
      expect(
        File('${target.path}/settings.json').readAsStringSync(),
        '{"new":true}',
      );
      await put('settings.json', '{"old":"changed"}');
      await migration().run();
      expect(
        File('${target.path}/settings.json').readAsStringSync(),
        '{"new":true}',
      );
    },
  );

  test(
    'old app running prevents a partial library from becoming active',
    () async {
      await put('settings.json', '{}');
      await expectLater(
        migration(running: () async => true).run(),
        throwsA(
          isA<AppMigrationException>().having(
            (e) => e.code,
            'code',
            'migration_legacy_running',
          ),
        ),
      );
      expect(File('${target.path}/settings.json').existsSync(), isFalse);
      await migration().run();
      expect(File('${target.path}/settings.json').existsSync(), isTrue);
    },
  );

  test(
    'failed copy can retry without deleting or modifying the old library',
    () async {
      await put('settings.json', '{"retained":true}');
      await expectLater(
        migration(
          copy: (_, _) async {
            throw const FileSystemException('No space left');
          },
        ).run(),
        throwsA(isA<AppMigrationException>()),
      );
      expect(File('${target.path}/settings.json').existsSync(), isFalse);
      expect(
        File('${oldRoot.path}/settings.json').readAsStringSync(),
        '{"retained":true}',
      );
      await migration().run();
      expect(
        File('${target.path}/settings.json').readAsStringSync(),
        '{"retained":true}',
      );
    },
  );

  test('concurrent startup requests share the same migration', () async {
    await put('settings.json', '{}');
    var copies = 0;
    final service = migration(
      copy: (source, destination) async {
        copies++;
        await source.copy(destination.path);
      },
    );
    await Future.wait([service.run(), migration().run(), service.run()]);
    expect(copies, 1);
  });

  test(
    'copies Windows encrypted credentials from above the old data root',
    () async {
      await put('settings.json', '{}');
      final encrypted = File(
        '${oldRoot.parent.path}/flutter_secure_storage.dat',
      );
      await encrypted.writeAsBytes([0, 255, 17, 34, 200]);
      await migration(windows: true).run();
      expect(
        File('${target.path}/flutter_secure_storage.dat').readAsBytesSync(),
        [0, 255, 17, 34, 200],
      );
      expect(encrypted.existsSync(), isTrue);
    },
  );

  test('does not follow links into external media', () async {
    await put('settings.json', '{}');
    final external = await put('outside/media.mp3', 'external', root: fixture);
    await Link('${oldRoot.path}/linked.mp3').create(external.path);
    await expectLater(migration().run(), throwsA(isA<AppMigrationException>()));
    expect(external.readAsStringSync(), 'external');
    expect(File('${target.path}/settings.json').existsSync(), isFalse);
  });

  test(
    'source modification detected before commit leaves old data intact',
    () async {
      await put('settings.json', '{}');
      await expectLater(
        migration(
          copy: (source, destination) async {
            await source.copy(destination.path);
            await source.writeAsString('{"changed":true}');
          },
        ).run(),
        throwsA(isA<AppMigrationException>()),
      );
      expect(
        File('${target.path}/${AppDataMigration.markerName}').existsSync(),
        isFalse,
      );
    },
  );
}
