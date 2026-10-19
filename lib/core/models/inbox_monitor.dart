import 'json.dart';

const Set<String> supportedMonitoredMediaExtensions = {
  'mp3',
  'wav',
  'm4a',
  'ogg',
  'mp4',
  'mkv',
  'avi',
};

enum InboxMonitorStatus {
  unconfigured,
  scanning,
  active,
  paused,
  unavailable,
  error,
}

enum MonitoredFileDisposition { queued, completed, dismissed }

class InboxMonitorConfig {
  const InboxMonitorConfig({
    this.folderPath = '',
    this.paused = false,
    this.extensions = supportedMonitoredMediaExtensions,
    this.launchAtLogin = false,
    this.showTrayIcon = true,
    this.showDockIcon = true,
  });

  final String folderPath;
  final bool paused;
  final Set<String> extensions;
  final bool launchAtLogin;
  final bool showTrayIcon;

  /// macOS only. Hiding it also hides the app's menus, so the menu bar icon
  /// is the way back in: the two are never both off.
  final bool showDockIcon;

  bool get isConfigured => folderPath.trim().isNotEmpty;

  InboxMonitorConfig copyWith({
    String? folderPath,
    bool? paused,
    Set<String>? extensions,
    bool? launchAtLogin,
    bool? showTrayIcon,
    bool? showDockIcon,
  }) => InboxMonitorConfig(
    folderPath: folderPath ?? this.folderPath,
    paused: paused ?? this.paused,
    extensions: extensions ?? this.extensions,
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    showTrayIcon: showTrayIcon ?? this.showTrayIcon,
    showDockIcon: showDockIcon ?? this.showDockIcon,
  );

  Map<String, dynamic> toJson() => {
    'folder_path': folderPath,
    'paused': paused,
    'extensions': extensions.toList()..sort(),
    'launch_at_login': launchAtLogin,
    'show_tray_icon': showTrayIcon,
    'show_dock_icon': showDockIcon,
  };

  factory InboxMonitorConfig.fromJson(Map<String, dynamic>? json) {
    final extensions = jsonStrings(json?['extensions'])
        .map((value) => value.trim().toLowerCase().replaceFirst('.', ''))
        .where(supportedMonitoredMediaExtensions.contains)
        .toSet();
    final showTrayIcon = json?['show_tray_icon'] as bool? ?? true;
    return InboxMonitorConfig(
      folderPath: json?['folder_path'] as String? ?? '',
      paused: json?['paused'] as bool? ?? false,
      extensions: extensions.isEmpty
          ? supportedMonitoredMediaExtensions
          : extensions,
      launchAtLogin: json?['launch_at_login'] as bool? ?? false,
      showTrayIcon: showTrayIcon,
      showDockIcon: !showTrayIcon || (json?['show_dock_icon'] as bool? ?? true),
    );
  }
}

class SourceFingerprint {
  const SourceFingerprint({
    required this.identity,
    required this.path,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String identity;
  final String path;
  final int sizeBytes;
  final DateTime modifiedAt;

  bool sameVersion(SourceFingerprint other) =>
      identity == other.identity &&
      sizeBytes == other.sizeBytes &&
      modifiedAt.isAtSameMomentAs(other.modifiedAt);

  Map<String, dynamic> toJson() => {
    'identity': identity,
    'path': path,
    'size_bytes': sizeBytes,
    'modified_at': modifiedAt.toUtc().toIso8601String(),
  };

  factory SourceFingerprint.fromJson(Map<String, dynamic> json) =>
      SourceFingerprint(
        identity: json['identity'] as String? ?? json['path'] as String? ?? '',
        path: json['path'] as String? ?? '',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        modifiedAt:
            dateFromJson(json['modified_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

class MonitoredFileRecord {
  const MonitoredFileRecord({
    required this.fingerprint,
    required this.disposition,
    required this.updatedAt,
    this.jobId,
  });

  final SourceFingerprint fingerprint;
  final MonitoredFileDisposition disposition;
  final DateTime updatedAt;
  final String? jobId;

  MonitoredFileRecord copyWith({
    SourceFingerprint? fingerprint,
    MonitoredFileDisposition? disposition,
    DateTime? updatedAt,
    String? jobId,
  }) => MonitoredFileRecord(
    fingerprint: fingerprint ?? this.fingerprint,
    disposition: disposition ?? this.disposition,
    updatedAt: updatedAt ?? this.updatedAt,
    jobId: jobId ?? this.jobId,
  );

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint.toJson(),
    'disposition': disposition.name,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    if (jobId case final value?) 'job_id': value,
  };

  factory MonitoredFileRecord.fromJson(Map<String, dynamic> json) =>
      MonitoredFileRecord(
        fingerprint: SourceFingerprint.fromJson(
          (json['fingerprint'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        disposition:
            enumByName(MonitoredFileDisposition.values, json['disposition']) ??
            MonitoredFileDisposition.dismissed,
        updatedAt: dateFromJson(json['updated_at']) ?? DateTime.now().toUtc(),
        jobId: json['job_id'] as String?,
      );
}

class InboxMonitorStorage {
  const InboxMonitorStorage({
    this.config = const InboxMonitorConfig(),
    this.records = const {},
  });

  final InboxMonitorConfig config;
  final Map<String, MonitoredFileRecord> records;

  InboxMonitorStorage copyWith({
    InboxMonitorConfig? config,
    Map<String, MonitoredFileRecord>? records,
  }) => InboxMonitorStorage(
    config: config ?? this.config,
    records: records ?? this.records,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'config': config.toJson(),
    'records': {
      for (final entry in records.entries) entry.key: entry.value.toJson(),
    },
  };

  factory InboxMonitorStorage.fromJson(Map<String, dynamic>? json) {
    final rawRecords = json?['records'];
    final records = <String, MonitoredFileRecord>{};
    if (rawRecords is Map) {
      for (final entry in rawRecords.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final record = MonitoredFileRecord.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        );
        if (record.fingerprint.identity.isNotEmpty) {
          records[entry.key as String] = record;
        }
      }
    }
    return InboxMonitorStorage(
      config: InboxMonitorConfig.fromJson(
        (json?['config'] as Map?)?.cast<String, dynamic>(),
      ),
      records: records,
    );
  }
}
