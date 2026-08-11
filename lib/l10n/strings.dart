import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/models.dart';

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

  String translationLanguageName(String code) =>
      (isZh ? _translationLanguagesZh[code] : null) ??
      _translationLanguagesEn[code] ??
      code;

  String translationProviderName(TranslationProviderTemplate provider) =>
      switch (provider) {
        TranslationProviderTemplate.custom => t('provider_custom'),
        TranslationProviderTemplate.openAi => 'OpenAI',
        TranslationProviderTemplate.deepSeek => 'DeepSeek',
        TranslationProviderTemplate.groq => 'Groq',
        TranslationProviderTemplate.nvidiaNim => 'NVIDIA NIM',
        TranslationProviderTemplate.togetherAi => 'Together AI',
        TranslationProviderTemplate.mistralAi => 'Mistral AI',
        TranslationProviderTemplate.lmStudio =>
          isZh ? 'LM Studio（本地）' : 'LM Studio (Local)',
        TranslationProviderTemplate.ollama =>
          isZh ? 'Ollama OpenAI API（本地）' : 'Ollama OpenAI API (Local)',
        TranslationProviderTemplate.fireworksAi => 'Fireworks AI',
        TranslationProviderTemplate.perplexity => 'Perplexity',
        TranslationProviderTemplate.volcengineArk =>
          isZh ? '火山方舟（豆包）' : 'Volcengine Ark (Doubao)',
      };

  String translationProviderHelp(TranslationProviderTemplate provider) =>
      switch (provider) {
        TranslationProviderTemplate.lmStudio => t('provider_help_lm_studio'),
        TranslationProviderTemplate.ollama => t('provider_help_ollama'),
        TranslationProviderTemplate.volcengineArk => t(
          'provider_help_volcengine',
        ),
        _ => '',
      };

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
    'expand_file_queue': 'Expand file queue',
    'collapse_file_queue': 'Collapse file queue',
    'show_sidebar': 'Show sidebar',
    'hide_sidebar': 'Hide sidebar',
    'resize_review_panels': 'Resize media and transcript panels',
    'fullscreen': 'Fullscreen',
    'exit_fullscreen': 'Exit fullscreen',
    'fullscreen_shortcuts': 'Fullscreen shortcuts',
    'shortcut_play_pause': 'Play / pause',
    'shortcut_seek_backward': 'Back 5s',
    'shortcut_seek_forward': 'Forward 5s',
    'shortcut_decrease_speed': 'Speed −0.25×',
    'shortcut_increase_speed': 'Speed +0.25×',
    'play': 'Play',
    'pause': 'Pause',
    'batch_zip': 'Package batch as ZIP',
    'copy': 'Copy',
    'copied': 'Transcript copied',
    'edit': 'Edit',
    'repeat_sentence': 'Repeat sentence',
    'stop_repeating_sentence': 'Stop repeating sentence',
    'focus_current_sentence': 'Focus current sentence',
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
    'llm_translation': 'LLM Translation',
    'provider_template': 'Provider template',
    'provider_custom': 'Custom',
    'provider_popular': 'Popular',
    'provider_local': 'Local',
    'provider_other': 'Other',
    'provider_help_lm_studio':
        'Start LM Studio with its local server enabled before testing.',
    'provider_help_ollama':
        'Start Ollama locally before testing this OpenAI-compatible endpoint.',
    'provider_help_volcengine':
        'Use the endpoint ID from Volcengine Ark as the model name.',
    'base_url': 'Base URL',
    'model': 'Model',
    'api_key': 'API key',
    'translation_model_hint': 'Required; model ID from your endpoint',
    'translation_test_to_select_model': 'Test the connection to select a model',
    'translation_select_model': 'Select a model',
    'translation_local_no_key':
        'No API key is required for this local provider.',
    'translation_key_hint': 'Required for remote endpoints',
    'translation_key_retained_hint': 'Leave blank to keep the stored key',
    'translation_configured': 'Translation is configured',
    'translation_not_configured': 'Choose a provider and test the connection',
    'translation_connection_ok': 'Connection successful',
    'translation_connection_failed': 'Connection test failed',
    'translation_connection_no_models':
        'Connection successful. Model discovery is unavailable; enter a model manually.',
    'translation_saved': 'Translation settings saved securely.',
    'translation_privacy_link': 'How transcript text is shared',
    'translation_privacy_title': 'Optional LLM translation',
    'translation_privacy_body':
        'When you translate, transcript text—not media—is sent to the configured OpenAI-compatible endpoint. That endpoint may have its own retention and privacy policy.',
    'target_language': 'Target language',
    'auto_translate': 'Translate automatically after transcription',
    'auto_translate_requires_config':
        'Configure the translation endpoint and model in Settings first.',
    'translate': 'Translate',
    'retry_missing': 'Retry missing',
    'retranslate_all': 'Retranslate all',
    'retranslate_segment': 'Retranslate segment',
    'edit_translation': 'Edit translation',
    'translation_progress': 'Translating {done} of {total}',
    'translation_partial': 'Translation is incomplete',
    'translation_cancelled': 'Translation cancelled',
    'translation_dialog_title': 'Translate transcript',
    'translation_model_label': 'Configured model: {model}',
    'translation_replace_title': 'Replace existing translation?',
    'translation_replace_body':
        'Changing the target language replaces the current translated text. Original text is not changed.',
    'original': 'Original',
    'translated': 'Translated',
    'bilingual': 'Bilingual',
    'export_content': 'Content',
    'partial_export_warning':
        'Some segments are not translated. Original text will be used for those segments.',
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
        'Media is uploaded directly to Soniox. Optional translation sends transcript text to your configured LLM endpoint. MeowSTT stores local paths and transcripts, and deletes only the remote Soniox items it created.',
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
        'MeowSTT is a bring-your-own-key desktop app. Media is sent to Soniox only when you transcribe. If you enable translation, transcript text is sent separately to your configured LLM endpoint. Local history contains file paths and transcript data—not media copies.',
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
    'error_translation_invalid_url': 'Enter a valid translation base URL.',
    'error_translation_https_required':
        'Remote translation endpoints must use HTTPS.',
    'error_translation_model_required': 'Enter a model before translating.',
    'error_translation_missing_credentials':
        'An API key is required for this translation endpoint.',
    'error_translation_bad_credentials':
        'The translation API key was rejected.',
    'error_translation_endpoint_or_model_not_found':
        'The translation endpoint or model was not found.',
    'error_translation_rate_limit':
        'The translation service is rate-limited. Try again later.',
    'error_translation_timeout': 'The translation request timed out.',
    'error_translation_network_error':
        'Could not reach the translation endpoint.',
    'error_translation_server_failure':
        'The translation service is temporarily unavailable.',
    'error_translation_request_failed': 'The translation request failed.',
    'error_translation_invalid_response':
        'The translation endpoint returned an invalid response.',
    'error_translation_invalid_language':
        'The selected target language is not supported.',
    'error_translation_unavailable':
        'Translation is unavailable in this build.',
    'error_translation_incomplete_response':
        'Some translated lines were missing from the response.',
    'error_translation_interrupted':
        'Translation was interrupted. Retry missing segments when ready.',
    'error_translation_cancelled': 'Translation was cancelled.',
    'error_translation_target_change_confirmation_required':
        'Confirm before replacing the existing target language.',
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
    'expand_file_queue': '展开文件队列',
    'collapse_file_queue': '收起文件队列',
    'show_sidebar': '显示侧边栏',
    'hide_sidebar': '隐藏侧边栏',
    'resize_review_panels': '调整媒体与转写面板宽度',
    'fullscreen': '全屏',
    'exit_fullscreen': '退出全屏',
    'fullscreen_shortcuts': '全屏快捷键',
    'shortcut_play_pause': '播放/暂停',
    'shortcut_seek_backward': '后退 5 秒',
    'shortcut_seek_forward': '前进 5 秒',
    'shortcut_decrease_speed': '速度 −0.25×',
    'shortcut_increase_speed': '速度 +0.25×',
    'play': '播放',
    'pause': '暂停',
    'batch_zip': '将批量结果打包为 ZIP',
    'copy': '复制',
    'copied': '已复制转写内容',
    'edit': '编辑',
    'repeat_sentence': '重复播放此句',
    'stop_repeating_sentence': '停止重复此句',
    'focus_current_sentence': '定位当前句',
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
    'llm_translation': 'LLM 翻译',
    'provider_template': '提供商模板',
    'provider_custom': '自定义',
    'provider_popular': '热门',
    'provider_local': '本地',
    'provider_other': '其他',
    'provider_help_lm_studio': '测试前请先在 LM Studio 中启用本地服务器。',
    'provider_help_ollama': '测试前请先在本地启动 Ollama。',
    'provider_help_volcengine': '请将火山方舟的接入点 ID 作为模型名称。',
    'base_url': '基础 URL',
    'model': '模型',
    'api_key': 'API 密钥',
    'translation_model_hint': '必填；填写端点支持的模型 ID',
    'translation_test_to_select_model': '测试连接后选择模型',
    'translation_select_model': '选择模型',
    'translation_local_no_key': '此本地提供商无需 API 密钥。',
    'translation_key_hint': '远程端点需要 API 密钥',
    'translation_key_retained_hint': '留空可保留已存储的密钥',
    'translation_configured': '翻译已配置',
    'translation_not_configured': '请选择提供商并测试连接',
    'translation_connection_ok': '连接成功',
    'translation_connection_failed': '连接测试失败',
    'translation_connection_no_models': '连接成功，但无法发现模型；请手动填写模型。',
    'translation_saved': '翻译设置已安全保存。',
    'translation_privacy_link': '转写文本如何发送',
    'translation_privacy_title': '可选的 LLM 翻译',
    'translation_privacy_body':
        '翻译时，转写文本（不包含媒体）会发送到你配置的 OpenAI 兼容端点。该端点可能有自己的数据保留和隐私政策。',
    'target_language': '目标语言',
    'auto_translate': '转写完成后自动翻译',
    'auto_translate_requires_config': '请先在“设置”中配置翻译端点和模型。',
    'translate': '翻译',
    'retry_missing': '重试缺失内容',
    'retranslate_all': '全部重新翻译',
    'retranslate_segment': '重新翻译此段',
    'edit_translation': '编辑翻译',
    'translation_progress': '正在翻译第 {done}/{total} 段',
    'translation_partial': '翻译不完整',
    'translation_cancelled': '翻译已取消',
    'translation_dialog_title': '翻译转写内容',
    'translation_model_label': '当前模型：{model}',
    'translation_replace_title': '替换现有翻译？',
    'translation_replace_body': '更改目标语言会替换当前译文，但不会修改原文。',
    'original': '原文',
    'translated': '译文',
    'bilingual': '双语',
    'export_content': '导出内容',
    'partial_export_warning': '部分段落尚未翻译，这些段落将使用原文。',
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
        '媒体会直接上传到 Soniox。可选翻译会把转写文本发送到你配置的 LLM 端点。MeowSTT 保存本地路径和转写内容，并且只删除由本应用创建的 Soniox 远程项目。',
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
        'MeowSTT 使用你自己的 API 密钥。只有开始转写后媒体才会发送到 Soniox；启用翻译后，转写文本会另行发送到你配置的 LLM 端点。历史记录只保存文件路径和转写数据，不复制原始媒体。',
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
    'error_translation_invalid_url': '请输入有效的翻译基础 URL。',
    'error_translation_https_required': '远程翻译端点必须使用 HTTPS。',
    'error_translation_model_required': '请先填写翻译模型。',
    'error_translation_missing_credentials': '此翻译端点需要 API 密钥。',
    'error_translation_bad_credentials': '翻译 API 密钥被拒绝。',
    'error_translation_endpoint_or_model_not_found': '未找到翻译端点或模型。',
    'error_translation_rate_limit': '翻译服务请求过多，请稍后重试。',
    'error_translation_timeout': '翻译请求超时。',
    'error_translation_network_error': '无法连接翻译端点。',
    'error_translation_server_failure': '翻译服务暂时不可用。',
    'error_translation_request_failed': '翻译请求失败。',
    'error_translation_invalid_response': '翻译端点返回了无效响应。',
    'error_translation_invalid_language': '不支持所选目标语言。',
    'error_translation_unavailable': '此版本无法使用翻译功能。',
    'error_translation_incomplete_response': '响应中缺少部分译文。',
    'error_translation_interrupted': '翻译已中断，可在准备好后重试缺失内容。',
    'error_translation_cancelled': '翻译已取消。',
    'error_translation_target_change_confirmation_required': '替换现有目标语言前请先确认。',
    'error_unexpected': '出现问题，请重试。',
    'error_unknown': '出现问题，请重试。',
  };

  static const _translationLanguagesEn = <String, String>{
    'en': 'English',
    'zh-Hans': 'Chinese (Simplified)',
    'zh-Hant': 'Chinese (Traditional)',
    'ja': 'Japanese',
    'ko': 'Korean',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'it': 'Italian',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'ar': 'Arabic',
    'hi': 'Hindi',
    'vi': 'Vietnamese',
    'th': 'Thai',
    'yue': 'Cantonese',
    'nl': 'Dutch',
    'pl': 'Polish',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'cs': 'Czech',
    'sv': 'Swedish',
    'da': 'Danish',
    'fi': 'Finnish',
    'el': 'Greek',
    'he': 'Hebrew',
    'id': 'Indonesian',
    'ms': 'Malay',
  };

  static const _translationLanguagesZh = <String, String>{
    'en': '英语',
    'zh-Hans': '简体中文',
    'zh-Hant': '繁体中文',
    'ja': '日语',
    'ko': '韩语',
    'es': '西班牙语',
    'fr': '法语',
    'de': '德语',
    'it': '意大利语',
    'pt': '葡萄牙语',
    'ru': '俄语',
    'ar': '阿拉伯语',
    'hi': '印地语',
    'vi': '越南语',
    'th': '泰语',
    'yue': '粤语',
    'nl': '荷兰语',
    'pl': '波兰语',
    'tr': '土耳其语',
    'uk': '乌克兰语',
    'cs': '捷克语',
    'sv': '瑞典语',
    'da': '丹麦语',
    'fi': '芬兰语',
    'el': '希腊语',
    'he': '希伯来语',
    'id': '印度尼西亚语',
    'ms': '马来语',
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
