import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/core/app_identity.dart';
import 'package:listenook/data/migrating_secure_value.dart';

class MemoryStorage extends Fake implements FlutterSecureStorage {
  final values = <String, String>{};
  bool failOldRead = false;
  bool failWrite = false;

  String address(String service, String key) => '$service/$key';

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String;
    final options = invocation.namedArguments[#mOptions] as MacOsOptions;
    final service = options.toMap()['accountName'] ?? 'default';
    final address = this.address(service, key);
    if (failOldRead && service == AppIdentity.legacyBundleId) {
      throw StateError('Keychain denied access');
    }
    if (invocation.memberName == #read) {
      return Future<String?>.value(values[address]);
    }
    if (invocation.memberName == #containsKey) {
      return Future<bool>.value(values.containsKey(address));
    }
    if (invocation.memberName == #write) {
      if (failWrite) throw StateError('Keychain write failed');
      values[address] = invocation.namedArguments[#value] as String;
      return Future<void>.value();
    }
    if (invocation.memberName == #delete) {
      values.remove(address);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  for (final suffix in [
    'soniox_api_key',
    'moss_api_key',
    'openai_compatible_translation_api_key',
  ]) {
    test(
      'migrates $suffix without removing the old key; deletion stays deleted',
      () async {
        final storage = MemoryStorage();
        final old = storage.address(
          AppIdentity.legacyBundleId,
          '${AppIdentity.legacyBundleId}.$suffix',
        );
        storage.values[old] = 'old-value';
        final key = '${AppIdentity.bundleId}.$suffix';
        final value = MigratingSecureValue(
          storage: storage,
          key: key,
          isMacOS: true,
        );
        await value.migrate();
        expect(await value.read(), 'old-value');
        expect(storage.values[old], 'old-value');
        await value.delete();
        await MigratingSecureValue(
          storage: storage,
          key: key,
          isMacOS: true,
        ).migrate();
        expect(await value.read(), isNull);
        expect(storage.values[old], 'old-value');
      },
    );
  }

  test('new credentials take priority over legacy values', () async {
    final storage = MemoryStorage()..failOldRead = true;
    final value = MigratingSecureValue(
      storage: storage,
      key: '${AppIdentity.bundleId}.soniox_api_key',
      isMacOS: true,
    );
    await value.write('new-value');
    await value.migrate();
    expect(await value.read(), 'new-value');
  });

  test(
    'denied legacy access can be retried without a false completion marker',
    () async {
      final storage = MemoryStorage()..failOldRead = true;
      final key = '${AppIdentity.bundleId}.soniox_api_key';
      final value = MigratingSecureValue(
        storage: storage,
        key: key,
        isMacOS: true,
      );
      await expectLater(value.migrate(), throwsStateError);
      storage.failOldRead = false;
      storage.values[storage.address(
            AppIdentity.legacyBundleId,
            '${AppIdentity.legacyBundleId}.soniox_api_key',
          )] =
          'recovered';
      await value.migrate();
      expect(await value.read(), 'recovered');
    },
  );

  test('supports the original default-service Keychain format', () async {
    final storage = MemoryStorage();
    final service =
        MigratingSecureValue.olderOptions.toMap()['accountName'] ?? 'default';
    storage.values[storage.address(
          service,
          '${AppIdentity.legacyBundleId}.soniox_api_key',
        )] =
        'older';
    final value = MigratingSecureValue(
      storage: storage,
      key: '${AppIdentity.bundleId}.soniox_api_key',
      isMacOS: true,
    );
    await value.migrate();
    expect(await value.read(), 'older');
  });

  test('a failed new-key write does not mark migration complete', () async {
    final storage = MemoryStorage();
    storage.values[storage.address(
          AppIdentity.legacyBundleId,
          '${AppIdentity.legacyBundleId}.soniox_api_key',
        )] =
        'retained';
    final value = MigratingSecureValue(
      storage: storage,
      key: '${AppIdentity.bundleId}.soniox_api_key',
      isMacOS: true,
    );
    storage.failWrite = true;
    await expectLater(value.migrate(), throwsStateError);
    storage.failWrite = false;
    await value.migrate();
    expect(await value.read(), 'retained');
  });
}
