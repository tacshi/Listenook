import 'dart:ffi';

class UpdateManifestException implements Exception {
  const UpdateManifestException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateInstallException implements Exception {
  const UpdateInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.build = 0});

  final int major;
  final int minor;
  final int patch;
  final int build;

  String get name => '$major.$minor.$patch';
  String get label => '$name+$build';

  static AppVersion? tryParse(String value, {int? build}) {
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      build: build ?? int.tryParse(match.group(4) ?? '') ?? 0,
    );
  }

  @override
  int compareTo(AppVersion other) {
    for (final comparison in [
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
      build.compareTo(other.build),
    ]) {
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  bool operator <(AppVersion other) => compareTo(other) < 0;
  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <=(AppVersion other) => compareTo(other) <= 0;
  bool operator >=(AppVersion other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  @override
  String toString() => label;
}

enum UpdateInstallKind {
  appZip,
  innoSetup;

  static UpdateInstallKind? tryParse(Object? value) => switch (value) {
    'appZip' => UpdateInstallKind.appZip,
    'innoSetup' => UpdateInstallKind.innoSetup,
    _ => null,
  };
}

class UpdateAsset {
  const UpdateAsset({
    required this.kind,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.url,
    this.silentArgs = const [],
    this.minOsVersion,
  });

  final UpdateInstallKind kind;
  final String fileName;
  final int size;
  final String sha256;
  final Uri url;
  final List<String> silentArgs;
  final String? minOsVersion;

  static UpdateAsset parse(Object? raw) {
    if (raw is! Map) {
      throw const UpdateManifestException('The platform update is invalid.');
    }
    final kind = UpdateInstallKind.tryParse(raw['kind']);
    if (kind == null) {
      throw const UpdateManifestException(
        'The update uses an unsupported installer.',
      );
    }
    final fileName = '${raw['fileName'] ?? ''}'.trim();
    if (fileName.isEmpty || fileName.contains('/') || fileName.contains('\\')) {
      throw const UpdateManifestException('The update filename is invalid.');
    }
    final size = (raw['size'] as num?)?.toInt() ?? 0;
    if (size <= 0) {
      throw const UpdateManifestException('The update size is invalid.');
    }
    final digest = '${raw['sha256'] ?? ''}'.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const UpdateManifestException('The update checksum is invalid.');
    }
    final url = Uri.tryParse('${raw['url'] ?? ''}');
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      throw const UpdateManifestException('The update URL is invalid.');
    }
    final args = raw['silentArgs'];
    return UpdateAsset(
      kind: kind,
      fileName: fileName,
      size: size,
      sha256: digest,
      url: url,
      silentArgs: args is List
          ? args.whereType<String>().toList(growable: false)
          : const [],
      minOsVersion: raw['minOsVersion'] as String?,
    );
  }
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.asset,
    this.releasedAt,
    this.notesUrl,
  });

  final AppVersion version;
  final UpdateAsset asset;
  final DateTime? releasedAt;
  final Uri? notesUrl;

  static AppRelease parse(Object? raw) {
    if (raw is! Map) {
      throw const UpdateManifestException('The platform release is invalid.');
    }
    final versionName = raw['version'] as String?;
    final parsedBuild = (raw['build'] as num?)?.toInt();
    final version = versionName == null || parsedBuild == null
        ? null
        : AppVersion.tryParse(versionName, build: parsedBuild);
    if (version == null || parsedBuild! < 0) {
      throw const UpdateManifestException('The release version is invalid.');
    }
    final notes = Uri.tryParse('${raw['notesUrl'] ?? ''}');
    return AppRelease(
      version: version,
      asset: UpdateAsset.parse(raw),
      releasedAt: DateTime.tryParse('${raw['releasedAt'] ?? ''}')?.toUtc(),
      notesUrl: notes?.scheme == 'https' ? notes : null,
    );
  }
}

class UpdateManifest {
  const UpdateManifest(this._platforms);

  static const supportedSchema = 1;
  final Map<String, Object?> _platforms;

  AppRelease? forPlatform(String platformKey) {
    final raw = _platforms[platformKey];
    return raw == null ? null : AppRelease.parse(raw);
  }

  static UpdateManifest parse(Object? raw) {
    if (raw is! Map) {
      throw const UpdateManifestException('The update manifest is invalid.');
    }
    if (raw['schema'] != supportedSchema) {
      throw const UpdateManifestException(
        'The update manifest version is unsupported.',
      );
    }
    final platforms = raw['platforms'];
    if (platforms is! Map) {
      throw const UpdateManifestException(
        'The update manifest has no platforms.',
      );
    }
    final parsed = <String, Object?>{};
    for (final entry in platforms.entries) {
      if (entry.key is String) {
        parsed[entry.key as String] = entry.value;
      }
    }
    return UpdateManifest(Map.unmodifiable(parsed));
  }
}

String? updatePlatformKeyForAbi(Abi abi) => switch (abi) {
  Abi.macosArm64 => 'macos-arm64',
  Abi.macosX64 => 'macos-x64',
  Abi.windowsX64 => 'windows-x64',
  _ => null,
};

String? get currentUpdatePlatformKey => updatePlatformKeyForAbi(Abi.current());
