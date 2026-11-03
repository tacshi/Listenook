import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/app_identity.dart';
import 'app_data_migration.dart';

class CredentialMigrationTarget {
  const CredentialMigrationTarget(this.name, this.migrate, this.write);
  final String name;
  final Future<void> Function() migrate;
  final Future<void> Function(String) write;
}

class CredentialMigrationException extends AppMigrationException {
  const CredentialMigrationException(this.targets)
    : super('migration_credentials_failed');
  final List<CredentialMigrationTarget> targets;
}

/// A migration tombstone is stored alongside the secret, never in plaintext.
/// Normal reads never fall back to the old app after a user clears a key.
class MigratingSecureValue {
  MigratingSecureValue({
    required this.storage,
    required this.key,
    bool? isMacOS,
  }) : isMacOS = isMacOS ?? Platform.isMacOS;

  final FlutterSecureStorage storage;
  final String key;
  final bool isMacOS;
  String get _marker => '$key.migration_complete';
  static const options = MacOsOptions(
    accountName: AppIdentity.bundleId,
    accessibility: KeychainAccessibility.first_unlock,
    usesDataProtectionKeychain: false,
  );
  static const legacyOptions = MacOsOptions(
    accountName: AppIdentity.legacyBundleId,
    accessibility: KeychainAccessibility.first_unlock,
    usesDataProtectionKeychain: false,
  );
  static const olderOptions = MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock,
    usesDataProtectionKeychain: false,
  );
  // The DPAPI container is copied before this object is used. Disable the
  // plugin's destructive automatic migration from the old native backend.
  static const windowsOptions = WindowsOptions(useBackwardCompatibility: false);
  // Readable in the background after the first unlock, so jobs that resume
  // while the device is locked can still authenticate.
  static const iosOptions = IOSOptions(
    accountName: AppIdentity.bundleId,
    accessibility: KeychainAccessibility.first_unlock,
  );

  Future<bool> contains() => storage.containsKey(
    key: key,
    mOptions: options,
    wOptions: windowsOptions,
    iOptions: iosOptions,
  );

  Future<String?> read() async {
    final value = await storage.read(
      key: key,
      mOptions: options,
      wOptions: windowsOptions,
      iOptions: iosOptions,
    );
    return value == null || value.trim().isEmpty ? null : value.trim();
  }

  Future<void> migrate() async {
    if (await storage.read(
          key: _marker,
          mOptions: options,
          wOptions: windowsOptions,
          iOptions: iosOptions,
        ) ==
        '1') {
      return;
    }
    if (await read() == null) {
      final oldKey = key.replaceFirst(
        AppIdentity.bundleId,
        AppIdentity.legacyBundleId,
      );
      var previous = await storage.read(
        key: oldKey,
        mOptions: legacyOptions,
        wOptions: windowsOptions,
        iOptions: iosOptions,
      );
      if (isMacOS && (previous == null || previous.trim().isEmpty)) {
        previous = await storage.read(
          key: oldKey,
          mOptions: olderOptions,
          wOptions: windowsOptions,
          iOptions: iosOptions,
        );
      }
      if (previous != null && previous.trim().isNotEmpty) {
        await storage.write(
          key: key,
          value: previous.trim(),
          mOptions: options,
          wOptions: windowsOptions,
          iOptions: iosOptions,
        );
        if (await read() != previous.trim()) {
          throw StateError('Credential migration verification failed');
        }
      }
    }
    await _complete();
  }

  Future<void> _complete() => storage.write(
    key: _marker,
    value: '1',
    mOptions: options,
    wOptions: windowsOptions,
    iOptions: iosOptions,
  );

  Future<void> write(String value) async {
    await storage.write(
      key: key,
      value: value.trim(),
      mOptions: options,
      wOptions: windowsOptions,
      iOptions: iosOptions,
    );
    await _complete();
  }

  Future<void> delete() async {
    // Write first so an interrupted deletion cannot resurrect the legacy key.
    await _complete();
    // The Darwin plugin's synchronizable fallback can report an entitlement
    // error for an already absent login-keychain item.
    if (!await contains()) return;
    await storage.delete(
      key: key,
      mOptions: options,
      wOptions: windowsOptions,
      iOptions: iosOptions,
    );
  }
}
