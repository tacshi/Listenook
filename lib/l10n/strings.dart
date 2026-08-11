import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class AppStrings {
  const AppStrings(this.locale);

  final Locale locale;
  bool get isZh => locale.languageCode == 'zh';

  static const supportedLocales = [Locale('en'), Locale('zh', 'CN')];
  static const delegate = _AppStringsDelegate();

  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings) ??
      const AppStrings(Locale('en'));

  String t(String key) => (isZh ? _zh[key] : null) ?? _en[key] ?? key;

  String error(String? code, {String? englishFallback}) {
    final canonical = switch (code?.toLowerCase()) {
      'authentication_error' || 'unauthorized' => 'bad_credentials',
      'insufficient_funds' || 'insufficient_balance' => 'exhausted_balance',
      'quota_exceeded' || 'rate_limit_exceeded' => 'rate_limit',
      'unsupported_audio_format' || 'invalid_audio' => 'invalid_media',
      final value? when value.isNotEmpty => value,
      _ => 'unknown',
    };
    final key = 'error_$canonical';
    final localized = isZh ? _zh[key] : _en[key];
    if (localized != null) return localized;
    if (!isZh && englishFallback?.trim().isNotEmpty == true) {
      return englishFallback!.trim();
    }
    return isZh ? _zh['error_unknown']! : _en['error_unknown']!;
  }

  String speakerName(String storedName) {
    final match = RegExp(r'^Speaker (\d+)$').firstMatch(storedName);
    if (match == null) return storedName;
    return t('speaker_number').replaceFirst('{number}', match.group(1)!);
  }

  @visibleForTesting
  static Set<String> get missingChineseKeys =>
      _en.keys.toSet()..removeAll(_zh.keys);

  @visibleForTesting
  static Set<String> get unexpectedChineseKeys =>
      _zh.keys.toSet()..removeAll(_en.keys);

  static const _en = <String, String>{
    'workspace': 'Workspace',
    'library': 'Library',
    'settings': 'Settings',
    'settings_transcription': 'Transcription',
    'settings_system_about': 'System & About',
    'add_files': 'Add files',
    'add_folder': 'Add folder',
    'new_transcription': 'New transcription',
    'new_session_title': 'Start a new transcription?',
    'new_session_body':
        '{count} untranscribed files will be removed. Completed transcripts stay in your library.',
    'start_new': 'Start new',
    'transcribe': 'Transcribe',
    'drop_title': 'Drop audio, video, or folders',
    'drop_subtitle': 'Review everything before MeowSTT uploads anything.',
    'supported': 'Batch drop · recursive folders · up to 5 hours each',
    'ready': 'Ready',
    'completed': 'Completed',
    'failed': 'Needs attention',
    'processing': 'Processing',
    'paused': 'Paused for next run',
    'cancel': 'Cancel',
    'retry': 'Retry',
    'remove': 'Remove',
    'export': 'Export',
    'export_all': 'Export all',
    'batch_zip': 'Package batch as ZIP',
    'copy': 'Copy',
    'copied': 'Transcript copied',
    'search_transcript': 'Search transcript',
    'search_library': 'Search your library',
    'no_history': 'Your completed transcripts will appear here.',
    'speaker_labels': 'Speaker labels',
    'timestamps': 'Timestamps',
    'language_hints': 'Language hints',
    'language_hints_hint': 'en, zh, ja',
    'context_terms': 'Names and context terms',
    'context_terms_hint': 'Product names, people, acronyms…',
    'concurrency': 'Concurrent jobs',
    'appearance': 'Appearance',
    'theme': 'Theme',
    'locale': 'Language',
    'system': 'System',
    'light': 'Light',
    'dark': 'Dark',
    'english': 'English',
    'chinese': '简体中文',
    'soniox_key': 'Soniox API key',
    'key_configured': 'Securely stored on this device',
    'key_missing': 'Add your Soniox key to transcribe',
    'key_hint': 'soniox_••••••••••••••••',
    'paste': 'Paste',
    'save': 'Save',
    'test': 'Test',
    'key_valid': 'Soniox key is valid.',
    'key_saved': 'Soniox key saved securely.',
    'key_save_failed':
        'Could not save the key securely. Check Keychain access and try again.',
    'privacy': 'Privacy',
    'privacy_body':
        'Media is uploaded directly to Soniox. MeowSTT stores only local paths and transcripts, and deletes only the remote files and transcriptions it created.',
    'ffmpeg': 'FFmpeg diagnostics',
    'refresh': 'Refresh',
    'available': 'Available',
    'unavailable': 'Unavailable',
    'checking': 'Checking…',
    'notices': 'Third-party notices',
    'notices_body':
        'The bundled FFmpeg helpers are distributed under GPL-3.0-or-later. Soniox is a third-party transcription provider. Full helper provenance and license texts are included with each distribution.',
    'welcome_title': 'Your recordings stay yours',
    'welcome_body':
        'MeowSTT is a bring-your-own-key desktop app. When you start a job, its media is uploaded directly to Soniox for transcription. Local history contains file paths and transcript data—not media copies.',
    'continue': 'Continue',
    'stay': 'Stay',
    'quit_resume': 'Quit & resume later',
    'cancel_quit': 'Cancel remote jobs & quit',
    'quit_title': 'Transcription is still active',
    'quit_body': 'MeowSTT can safely resume remote processing next time.',
    'source_missing': 'Source missing',
    'relink': 'Relink',
    'delete_history': 'Remove from library',
    'clear_all': 'Clear All',
    'clear_history_title': 'Clear inactive history?',
    'clear_history_body':
        'This permanently removes {count} inactive items and their local transcripts. Original media files are not deleted.',
    'open': 'Open',
    'all': 'All',
    'last_7_days': 'Last 7 days',
    'under_30m': 'Under 30 min',
    'over_30m': '30 min+',
    'details': 'Batch options',
    'review_cost': 'Nothing uploads until you press Transcribe.',
    'choose_export_folder': 'Choose an export folder',
    'exported': 'Export complete',
    'rename_speaker': 'Rename speaker',
    'plain_text': 'Plain text',
    'markdown': 'Markdown',
    'srt': 'SRT subtitle',
    'vtt': 'WebVTT subtitle',
    'automatic': 'Automatic',
    'none': 'None',
    'diarization_reversible':
        'Diarization remains enabled, so this setting is always reversible.',
    'subtitle_timing_kept': 'Subtitle exports always keep cue timing.',
    'subtitle_timing_required': 'Always included in subtitle formats',
    'more_actions': 'More actions',
    'audio_video': 'Audio and video',
    'zip_archive': 'ZIP archive',
    'job_pending': 'Pending',
    'job_probing': 'Inspecting',
    'job_ready': 'Ready',
    'job_converting': 'Converting',
    'job_uploading': 'Uploading',
    'job_queuedRemote': 'Queued by Soniox',
    'job_processing': 'Transcribing',
    'job_fetching': 'Fetching transcript',
    'job_completed': 'Completed',
    'job_empty': 'No speech found',
    'job_failed': 'Failed',
    'job_cancelled': 'Cancelled',
    'job_missingSource': 'Source missing',
    'job_paused': 'Paused',
    'speaker_number': 'Speaker {number}',
    'error_missing_credentials': 'A Soniox API key is required.',
    'error_bad_credentials': 'The Soniox API key is invalid.',
    'error_exhausted_balance': 'The Soniox account has insufficient balance.',
    'error_rate_limit':
        'Soniox is busy or the account quota was reached. Try again later.',
    'error_invalid_media': 'Soniox could not process this media file.',
    'error_server_failure': 'Soniox is temporarily unavailable. Try again.',
    'error_request_failed': 'The Soniox request failed. Try again.',
    'error_invalid_response': 'Soniox returned an invalid response.',
    'error_missing_source':
        'The source file is missing. Relink it to continue.',
    'error_unreadable_source': 'The source file cannot be read.',
    'error_no_audio': 'No audio stream was found in this file.',
    'error_duration_limit': 'Files can be up to 300 minutes long.',
    'error_conversion_failed': 'FFmpeg could not extract the audio.',
    'error_ffmpeg_missing':
        'FFmpeg and ffprobe were not found. Open Settings for diagnostics.',
    'error_ffmpeg_unavailable': 'FFmpeg diagnostics failed.',
    'error_media_error': 'The media file could not be inspected.',
    'error_cancelled': 'Cancelled by the user.',
    'error_transcription_failed': 'Soniox could not transcribe this file.',
    'error_unexpected': 'Something went wrong. Try again.',
    'error_unknown': 'Something went wrong. Try again.',
  };

  static const _zh = <String, String>{
    'workspace': '工作区',
    'library': '资料库',
    'settings': '设置',
    'settings_transcription': '转写',
    'settings_system_about': '系统与关于',
    'add_files': '添加文件',
    'add_folder': '添加文件夹',
    'new_transcription': '新建转写',
    'new_session_title': '开始新的转写？',
    'new_session_body': '{count} 个尚未转写的文件将被移除。已完成的转写仍会保留在资料库中。',
    'start_new': '开始新转写',
    'transcribe': '开始转写',
    'drop_title': '拖入音频、视频或文件夹',
    'drop_subtitle': '上传前先检查文件和选项。',
    'supported': '批量拖放 · 递归文件夹 · 单文件最长 5 小时',
    'ready': '就绪',
    'completed': '已完成',
    'failed': '需要处理',
    'processing': '处理中',
    'paused': '等待下次开始',
    'cancel': '取消',
    'retry': '重试',
    'remove': '移除',
    'export': '导出',
    'export_all': '全部导出',
    'batch_zip': '将批量结果打包为 ZIP',
    'copy': '复制',
    'copied': '已复制转写内容',
    'search_transcript': '搜索转写内容',
    'search_library': '搜索资料库',
    'no_history': '完成的转写会显示在这里。',
    'speaker_labels': '显示说话人',
    'timestamps': '显示时间戳',
    'language_hints': '语言提示',
    'language_hints_hint': 'en, zh, ja',
    'context_terms': '姓名与上下文词语',
    'context_terms_hint': '产品名称、人名、缩写…',
    'concurrency': '并行任务数',
    'appearance': '外观',
    'theme': '主题',
    'locale': '语言',
    'system': '跟随系统',
    'light': '浅色',
    'dark': '深色',
    'english': '英语',
    'chinese': '简体中文',
    'soniox_key': 'Soniox API 密钥',
    'key_configured': '已安全存储在此设备',
    'key_missing': '添加 Soniox 密钥后即可转写',
    'key_hint': 'soniox_••••••••••••••••',
    'paste': '粘贴',
    'save': '保存',
    'test': '测试',
    'key_valid': 'Soniox 密钥有效。',
    'key_saved': 'Soniox 密钥已安全保存。',
    'key_save_failed': '无法安全保存密钥。请检查“钥匙串”访问权限后重试。',
    'privacy': '隐私',
    'privacy_body':
        '媒体会直接上传到 Soniox。MeowSTT 仅保存本地路径和转写内容，并且只删除由本应用创建的远程文件与转写任务。',
    'ffmpeg': 'FFmpeg 诊断',
    'refresh': '刷新',
    'available': '可用',
    'unavailable': '不可用',
    'checking': '正在检查…',
    'notices': '第三方声明',
    'notices_body':
        '随附的 FFmpeg 辅助程序按 GPL-3.0-or-later 许可证分发。Soniox 是第三方转写服务提供商。每个发行包均包含辅助程序的完整来源信息和许可证文本。',
    'welcome_title': '你的录音始终属于你',
    'welcome_body':
        'MeowSTT 使用你自己的 Soniox 密钥。开始任务后，媒体会直接上传到 Soniox。历史记录只保存文件路径和转写数据，不复制原始媒体。',
    'continue': '继续',
    'stay': '留在应用',
    'quit_resume': '退出并稍后继续',
    'cancel_quit': '取消远程任务并退出',
    'quit_title': '转写仍在进行',
    'quit_body': 'MeowSTT 下次启动时可以安全地继续远程处理。',
    'source_missing': '源文件丢失',
    'relink': '重新关联',
    'delete_history': '从资料库移除',
    'clear_all': '全部清除',
    'clear_history_title': '清除非活动历史记录？',
    'clear_history_body': '这将永久移除 {count} 条非活动记录及其本地转写内容，但不会删除原始媒体文件。',
    'open': '打开',
    'all': '全部',
    'last_7_days': '最近 7 天',
    'under_30m': '30 分钟以内',
    'over_30m': '30 分钟以上',
    'details': '批处理选项',
    'review_cost': '点击“开始转写”之前不会上传任何内容。',
    'choose_export_folder': '选择导出文件夹',
    'exported': '导出完成',
    'rename_speaker': '重命名说话人',
    'plain_text': '纯文本',
    'markdown': 'Markdown',
    'srt': 'SRT 字幕',
    'vtt': 'WebVTT 字幕',
    'automatic': '自动识别',
    'none': '无',
    'diarization_reversible': '说话人分离始终启用，因此可随时切换此设置。',
    'subtitle_timing_kept': '字幕导出始终保留时间轴。',
    'subtitle_timing_required': '字幕格式始终包含时间轴',
    'more_actions': '更多操作',
    'audio_video': '音频和视频',
    'zip_archive': 'ZIP 压缩包',
    'job_pending': '等待中',
    'job_probing': '正在检查',
    'job_ready': '就绪',
    'job_converting': '正在转换',
    'job_uploading': '正在上传',
    'job_queuedRemote': 'Soniox 队列中',
    'job_processing': '正在转写',
    'job_fetching': '正在获取转写',
    'job_completed': '已完成',
    'job_empty': '未检测到语音',
    'job_failed': '失败',
    'job_cancelled': '已取消',
    'job_missingSource': '源文件丢失',
    'job_paused': '已暂停',
    'speaker_number': '说话人 {number}',
    'error_missing_credentials': '需要填写 Soniox API 密钥。',
    'error_bad_credentials': 'Soniox API 密钥无效。',
    'error_exhausted_balance': 'Soniox 账户余额不足。',
    'error_rate_limit': 'Soniox 当前繁忙或账户已达到配额，请稍后重试。',
    'error_invalid_media': 'Soniox 无法处理此媒体文件。',
    'error_server_failure': 'Soniox 暂时不可用，请稍后重试。',
    'error_request_failed': 'Soniox 请求失败，请重试。',
    'error_invalid_response': 'Soniox 返回了无效响应。',
    'error_missing_source': '源文件丢失，请重新关联后继续。',
    'error_unreadable_source': '无法读取源文件。',
    'error_no_audio': '此文件中未找到音频流。',
    'error_duration_limit': '文件时长不能超过 300 分钟。',
    'error_conversion_failed': 'FFmpeg 无法提取音频。',
    'error_ffmpeg_missing': '未找到 FFmpeg 和 ffprobe，请打开“设置”查看诊断。',
    'error_ffmpeg_unavailable': 'FFmpeg 诊断失败。',
    'error_media_error': '无法检查此媒体文件。',
    'error_cancelled': '已由用户取消。',
    'error_transcription_failed': 'Soniox 无法转写此文件。',
    'error_unexpected': '出现问题，请重试。',
    'error_unknown': '出现问题，请重试。',
  };
}

class _AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppStringsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'en' || locale.languageCode == 'zh';

  @override
  Future<AppStrings> load(Locale locale) =>
      SynchronousFuture(AppStrings(locale));

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppStrings> old) => false;
}

extension StringsContext on BuildContext {
  AppStrings get strings => AppStrings.of(this);
}
