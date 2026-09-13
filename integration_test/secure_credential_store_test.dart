import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:listenook/core/app_identity.dart';
import 'package:listenook/data/migrating_secure_value.dart';
import 'package:integration_test/integration_test.dart';
import 'package:listenook/data/local_repositories.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS Keychain can securely round-trip a credential', (
    tester,
  ) async {
    final store = SecureCredentialStore(
      storageKey: 'app.capyvibe.listenook.integration_test_key',
    );
    const value = 'listenook-keychain-round-trip';

    addTearDown(store.deleteApiKey);
    await store.writeApiKey(value);

    expect(await store.readApiKey(), value);
  });
  testWidgets(
    'native bundle identity and localized name channel are connected',
    (tester) async {
      final info = await PackageInfo.fromPlatform();
      expect(info.packageName, AppIdentity.bundleId);
      const channel = MethodChannel(AppIdentity.startupChannel);
      expect(await channel.invokeMethod<bool>('isLegacyRunning'), isA<bool>());
      for (final (language, name) in [('zh', '聆页'), ('en', 'Listenook')]) {
        await channel.invokeMethod<void>('setDisplayName', {
          'name': name,
          'languageCode': language,
        });
      }
    },
  );

  testWidgets('real Keychain migration preserves the isolated legacy value', (
    tester,
  ) async {
    const storage = FlutterSecureStorage();
    const key = '${AppIdentity.bundleId}.migration_integration_probe';
    const oldKey = '${AppIdentity.legacyBundleId}.migration_integration_probe';
    const secret = 'isolated-migration-fixture';
    Future<void> clearProbe() async {
      for (final (probeKey, options) in [
        (key, MigratingSecureValue.options),
        ('$key.migration_complete', MigratingSecureValue.options),
        (oldKey, MigratingSecureValue.legacyOptions),
      ]) {
        if (await storage.containsKey(key: probeKey, mOptions: options)) {
          await storage.delete(key: probeKey, mOptions: options);
        }
      }
    }

    await clearProbe();
    addTearDown(clearProbe);
    await storage.write(
      key: oldKey,
      value: secret,
      mOptions: MigratingSecureValue.legacyOptions,
    );
    final value = MigratingSecureValue(storage: storage, key: key);
    await value.migrate();
    expect(await value.read(), secret);
    expect(
      await storage.read(
        key: oldKey,
        mOptions: MigratingSecureValue.legacyOptions,
      ),
      secret,
    );
    await value.delete();
    await value.delete();
    await value.migrate();
    expect(await value.read(), isNull);
  });
}
