//! The interface's two languages. English text is the key; a string
//! without a Chinese entry shows in English.

use crate::models::JobStatus;

/// An interface language.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Lang {
    #[default]
    En,
    Zh,
}

impl Lang {
    /// The app's name in this language.
    pub fn app_name(self) -> &'static str {
        match self {
            Lang::En => "Listenook",
            Lang::Zh => "聆页",
        }
    }

    /// The exporters' locale code.
    pub fn code(self) -> &'static str {
        match self {
            Lang::En => "en",
            Lang::Zh => "zh",
        }
    }

    /// The language of a system locale such as `zh-Hans-CN`.
    pub fn of_locale(locale: &str) -> Lang {
        if locale.to_ascii_lowercase().starts_with("zh") { Lang::Zh } else { Lang::En }
    }
}

const ZH: &[(&str, &str)] = &[
    ("Inbox", "收件箱"),
    ("Podcast", "播客"),
    ("Workspace", "工作区"),
    ("Library", "资料库"),
    ("Settings", "设置"),
    ("Settings…", "设置…"),
    ("Transcribe", "开始转写"),
    ("Add media & subtitles…", "添加媒体和字幕…"),
    ("Add media…", "添加媒体…"),
    ("Batch options", "批处理选项"),
    ("Ready", "就绪"),
    ("Completed", "已完成"),
    ("Needs attention", "需要处理"),
    ("Processing", "处理中"),
    ("Transcript", "转写"),
    ("AI Brief", "AI 简报"),
    ("Original", "原文"),
    ("Translated", "译文"),
    ("Bilingual", "双语"),
    ("Blind listening", "盲听"),
    ("Mimic", "跟读"),
    ("Reps", "遍数"),
    ("Pause", "间隔"),
    ("Auto", "自动"),
    ("Type answer", "输入答案"),
    ("Type what you hear", "输入你听到的内容"),
    ("Check", "检查"),
    ("Replay", "重播"),
    ("Next", "下一句"),
    ("Matches transcript", "与转写一致"),
    ("Listen again and retry.", "再听一遍后重试。"),
    ("Word checking supports English only.", "单词检查仅支持英语。"),
    ("Repeat sentence", "重复播放此句"),
    ("Stop repeating sentence", "停止重复此句"),
    ("Previous sentence", "上一句"),
    ("Next sentence", "下一句"),
    ("Search transcript", "搜索转写内容"),
    ("Search your library", "搜索资料库"),
    ("Discover", "发现"),
    ("Following", "已关注"),
    ("Downloads", "已下载"),
    ("Deep listen", "精听这一集"),
    ("No transcript open", "未打开转写"),
    ("Open a completed transcript from Library.", "从资料库打开一份已完成的转写。"),
    ("Browse Library", "浏览资料库"),
    ("Theme", "主题"),
    ("Language", "语言"),
    ("System", "跟随系统"),
    ("Light", "浅色"),
    ("Dark", "深色"),
    ("Save", "保存"),
    ("Cancel", "取消"),
    ("Export", "导出"),
    ("Export…", "导出…"),
    ("Copy", "复制"),
    ("Remove", "移除"),
    ("Retry", "重试"),
    ("Open", "打开"),
    ("Rename…", "重命名…"),
    ("Rename", "重命名"),
    ("Delete", "删除"),
    ("Close", "关闭"),
    ("Done", "完成"),
    ("Test", "测试"),
    ("Play", "播放"),
    ("Pause playback", "暂停"),
    ("Follow", "关注"),
    ("Unfollow", "取消关注"),
    ("Download", "下载"),
    ("Downloaded", "已下载"),
    ("General", "通用"),
    ("Transcription", "转写"),
    ("AI", "AI"),
    ("Shortcuts", "快捷键"),
    ("About", "关于"),
    ("Speaker labels", "说话人标签"),
    ("Timestamps", "时间戳"),
    ("Playback speed", "播放速度"),
    ("Translate with LLM…", "用 LLM 翻译…"),
    ("Translate", "翻译"),
    ("Target language", "目标语言"),
    ("Language hints", "语言提示"),
    ("Automatic", "自动"),
    ("Names and context terms", "名称和上下文术语"),
    ("Translate automatically after transcription", "转写后自动翻译"),
    ("Drop media here", "将媒体拖到这里"),
    (
        "Audio or video, with matching SRT, WebVTT or ASS subtitles · up to 5 hours each",
        "音频或视频，可附同名 SRT、WebVTT 或 ASS 字幕 · 每个最长 5 小时",
    ),
    ("Your completed transcripts will appear here.", "已完成的转写会显示在这里。"),
    ("Follow a show to see new episodes here.", "关注节目后，新剧集会显示在这里。"),
    ("Downloaded episodes will appear here.", "已下载的剧集会显示在这里。"),
    ("Search podcasts", "搜索播客"),
    ("Paste a public RSS URL", "粘贴公开的 RSS 地址"),
    ("Add by URL", "通过链接添加"),
    ("RSS URL", "RSS 地址"),
    ("English worth studying", "值得精听的英语节目"),
    ("No podcasts matched that search.", "没有找到匹配的播客。"),
    ("Create AI Brief…", "创建 AI 简报…"),
    ("Refresh AI Brief…", "刷新 AI 简报…"),
    ("No AI Brief yet", "还没有 AI 简报"),
    ("Overview", "概览"),
    ("Chapters", "章节"),
    ("Key ideas", "要点"),
    ("Decisions", "决定"),
    ("Action items", "行动项"),
    ("Open questions", "待解决问题"),
    ("Language notes", "语言笔记"),
    ("Generate", "生成"),
    ("Transcript copied", "已复制转写"),
    ("Export complete", "导出完成"),
    ("Something went wrong. Try again.", "出了点问题，请重试。"),
    ("Provider", "服务商"),
    ("API key", "API 密钥"),
    ("Base URL", "Base URL"),
    ("Model", "模型"),
    ("Check for updates", "检查更新"),
    ("Restart to update", "重启以更新"),
    ("Pending", "等待中"),
    ("Inspecting", "检查中"),
    ("Downloading", "下载中"),
    ("Converting", "转换中"),
    ("Uploading", "上传中"),
    ("Queued by transcription provider", "服务商排队中"),
    ("Transcribing", "转写中"),
    ("Fetching transcript", "获取转写"),
    ("Generating precise timeline", "生成精确时间轴"),
    ("No speech found", "未发现语音"),
    ("Failed", "失败"),
    ("Cancelled", "已取消"),
    ("Source missing", "源文件缺失"),
    ("Paused", "已暂停"),
    ("All", "全部"),
    ("Show in Finder", "在访达中显示"),
    ("Reveal current sentence", "显示当前句"),
    ("Focus current sentence", "定位当前句"),
    ("Edit", "编辑"),
    ("Edit translation", "编辑译文"),
    ("Copy transcript", "复制转写"),
    ("Sentence", "句子"),
    ("MOSS — on this Mac", "MOSS — 本机"),
    ("Qwen3 — on this Mac", "Qwen3 — 本机"),
    ("This model is not downloaded yet.", "该模型尚未下载。"),
    ("On this Mac", "本机"),
    (
        "Transcribe without sending audio anywhere. Each model is downloaded once.",
        "无需上传音频即可转写。每个模型只需下载一次。",
    ),
    ("Multilingual, with speaker labels", "多语言，带说话人标签"),
    ("Multilingual, follows language hints and context terms", "多语言，支持语言提示和上下文词"),
    ("Word timing", "逐词时间轴"),
    ("Word timing, precise", "逐词时间轴（精确）"),
    (
        "Highlights each word as it is spoken, for MOSS and Qwen3 transcripts",
        "播放时逐词高亮，适用于 MOSS 和 Qwen3 转写",
    ),
    ("Larger and slower; a little more exact", "更大更慢，略为精确"),
    ("Time each word after transcription", "转写后生成逐词时间轴"),
    ("Word timing model", "逐词时间轴模型"),
    ("Standard", "标准"),
    ("Precise", "精确"),
    ("Resume", "继续"),
    ("The download is deleted. You can download it again later.", "已下载的内容将被删除，之后可重新下载。"),
    ("Time the words", "生成逐词时间轴"),
    ("Multilingual; follows a language hint and context terms", "多语言，支持语言提示和上下文词"),
    ("Qwen3, large", "Qwen3（大）"),
    ("More accurate on difficult audio; several times slower", "对较难的音频更准确，但慢数倍"),
    ("Qwen3 model", "Qwen3 模型"),
    ("Large", "大"),
    (
        "Needed by Qwen3 for sentence times; highlights each word as it is spoken",
        "Qwen3 需要它来确定句子时间；播放时逐词高亮",
    ),
    ("Time each word of MOSS transcripts", "为 MOSS 转写生成逐词时间轴"),
    ("A new version is available:", "有新版本可用："),
    (
        "A subtitle file with the same name becomes its transcript. Up to 5 hours each.",
        "同名字幕文件会成为它的转写。每个文件最长 5 小时。",
    ),
    ("AI Brief copied", "AI 简报已复制"),
    ("AI provider", "AI 服务商"),
    ("AI-generated draft · verify against evidence", "AI 生成的草稿 · 请对照原文核实"),
    ("Add", "添加"),
    ("Added to your Library.", "已添加到资料库。"),
    ("Analyzing the transcript…", "正在分析转写…"),
    ("Appearance", "外观"),
    ("Background", "后台"),
    (
        "Audio and video that appear in this folder, and its subfolders, are added to the Library. Nothing is transcribed until you ask.",
        "出现在此文件夹及其子文件夹中的音频和视频会被添加到资料库。在你开始之前不会转写任何内容。",
    ),
    ("Back", "返回"),
    ("Back to Library", "返回资料库"),
    ("Browse", "浏览"),
    ("Change folder…", "更换文件夹…"),
    ("Checking for updates…", "正在检查更新…"),
    ("Choose folder…", "选择文件夹…"),
    ("Configure the AI provider in Settings before creating a brief.", "请先在设置中配置 AI 服务商，再生成简报。"),
    ("Configure the AI provider in Settings before translating.", "请先在设置中配置 AI 服务商，再进行翻译。"),
    ("Content", "内容"),
    ("Couldn’t check for updates.", "无法检查更新。"),
    ("Couldn’t save the file. Choose another folder and try again.", "无法保存文件。请选择其他文件夹后重试。"),
    ("Couldn’t save the key. Unlock your keychain and try again.", "无法保存密钥。请解锁钥匙串后重试。"),
    ("Couldn’t show the file. It may have been moved.", "无法显示该文件，它可能已被移动。"),
    ("Create AI Brief", "生成 AI 简报"),
    (
        "Create an evidence-backed overview, chapters, decisions, actions, and open questions.",
        "生成有原文依据的概览、章节、决定、行动项和待解决问题。",
    ),
    ("Delete group", "删除分组"),
    ("Delete group…", "删除分组…"),
    ("Download it from the release page.", "请从发布页面下载。"),
    ("Downloading and installing the update…", "正在下载并安装更新…"),
    ("Drop audio or video here", "将音频或视频拖到这里"),
    (
        "Each sentence plays, then waits for you to say it. Press a sentence to practice it.",
        "每句播放后会等你跟读。点按一句即可练习它。",
    ),
    ("Export shown as ZIP…", "将显示的项目导出为 ZIP…"),
    ("Export transcript", "导出转写"),
    ("Format", "格式"),
    ("Full screen", "全屏"),
    ("Group", "分组"),
    ("Group…", "分组…"),
    ("Groups", "分组"),
    ("Has captions", "有字幕"),
    ("In Library", "已在资料库"),
    ("In progress", "进行中"),
    ("Include sections", "包含的部分"),
    (
        "Its edits, translation and AI Brief are replaced by the subtitle file.",
        "它的编辑、译文和 AI 简报将被字幕文件取代。",
    ),
    ("Its recordings stay in the Library.", "其中的录音会保留在资料库中。"),
    (
        "Its transcript, translation and AI Brief are deleted. The media file stays where it is.",
        "它的转写、译文和 AI 简报会被删除。媒体文件保留在原处。",
    ),
    ("Key saved in the system keychain.", "密钥已保存到系统钥匙串。"),
    ("Key saved.", "密钥已保存。"),
    ("Show Dock icon", "显示程序坞图标"),
    ("Repeat the sentence while held", "按住时重复当前句"),
    ("Minimize", "最小化"),
    ("Exit full screen", "退出全屏"),
    ("Subtitles", "字幕"),
    ("Transcription options", "转写选项"),
    ("Starts hidden in the menu bar.", "启动后隐藏在菜单栏中。"),
    ("Starts hidden in the system tray.", "启动后隐藏在系统托盘中。"),
    ("Show the Dock icon first, so Listenook stays reachable.", "请先显示程序坞图标，以便随时打开聆页。"),
    ("When hidden, the menu bar icon opens Listenook and its settings.", "隐藏后，可通过菜单栏图标打开聆页和设置。"),
    ("Show the menu bar icon first, so Listenook stays reachable.", "请先显示菜单栏图标，以便随时打开聆页。"),
    ("New group", "新建分组"),
    ("Delete tag…", "删除标签…"),
    ("Delete tag", "删除标签"),
    ("Rename tag", "重命名标签"),
    ("It is taken off its recordings, which stay in the Library.", "它会从带有它的录音上移除，录音仍保留在资料库中。"),
    ("Create", "创建"),
    ("Group actions", "分组操作"),
    ("Tag actions", "标签操作"),
    ("Add media", "添加媒体"),
    ("Dismiss", "知道了"),
    ("Open feed", "打开订阅源"),
    ("Open Settings…", "打开设置…"),
    ("Show in folder", "在文件夹中显示"),
    ("Qwen3 — on this device", "Qwen3 — 本机"),
    ("MOSS — on this device", "MOSS — 本机"),
    ("On this device", "本机"),
    ("Play or pause with Ctrl+Alt+Space", "用 Ctrl+Alt+空格 播放或暂停"),
    ("There is no transcript to open yet.", "还没有可打开的转写稿。"),
    (
        "Its transcript, translation and AI Brief are deleted, and so is Listenook’s copy of the media.",
        "其转写稿、翻译和 AI 简报将被删除，聆页保存的媒体副本也会一并删除。",
    ),
    (
        "Language codes separated by commas. Leave empty to detect automatically.",
        "语言代码以逗号分隔。留空则自动检测。",
    ),
    (
        "Listenook has no backend. Cloud transcription sends media directly to the provider you choose when you start a job; translation and AI Briefs send transcript text to your AI endpoint. API keys are kept in the system keychain. Transcripts and settings stay on this computer.",
        "聆页没有后端服务。云端转写会在你开始任务时把媒体直接发送给你选择的服务商；翻译和 AI 简报会把转写文本发送到你的 AI 端点。API 密钥保存在系统钥匙串中。转写和设置都留在这台电脑上。",
    ),
    ("Listenook is up to date.", "聆页已是最新版本。"),
    ("Merge with next", "与下一句合并"),
    ("Model:", "模型："),
    (
        "Multilingual transcription with speaker labels through MOSI. Language and context are automatic.",
        "通过 MOSI 进行带说话人标签的多语言转写。语言和上下文自动处理。",
    ),
    ("Name", "名称"),
    ("New tag", "新标签"),
    ("No API key is required for a provider on this computer.", "本机上的服务商无需 API 密钥。"),
    ("No group", "无分组"),
    ("No new audio or video files were found.", "没有找到新的音频或视频文件。"),
    ("No recordings match your search.", "没有符合搜索的录音。"),
    ("No sentences match your search.", "没有符合搜索的句子。"),
    ("Not transcribed", "未转写"),
    ("Nothing here.", "这里什么都没有。"),
    (
        "One OpenAI-compatible endpoint shared by translation and AI Briefs. Transcript text is sent to it only when you translate or create a brief.",
        "翻译和 AI 简报共用一个兼容 OpenAI 的端点。只有在你翻译或生成简报时，转写文本才会发送给它。",
    ),
    ("Open release page", "打开发布页面"),
    ("Or a new group", "或新建分组"),
    ("Organizing the brief…", "正在整理简报…"),
    ("Output language", "输出语言"),
    ("Paste your API key", "粘贴你的 API 密钥"),
    ("Podcast search and artwork are provided by Apple Podcasts.", "播客搜索和封面由 Apple 播客提供。"),
    ("Podcasts", "播客"),
    ("Preparing this recording for playback…", "正在准备播放此录音…"),
    ("Press Test to list the models your endpoint offers.", "点按“测试”以列出端点提供的模型。"),
    ("Privacy", "隐私"),
    ("Product names, people, acronyms…", "产品名、人名、缩写…"),
    ("Proficiency", "水平"),
    ("Remove…", "移除…"),
    ("Rename group", "重命名分组"),
    ("Rename speaker", "重命名说话人"),
    ("Replace", "替换"),
    ("Replace existing translations", "替换已有译文"),
    ("Replace this transcript?", "替换这份转写？"),
    ("Saved", "已保存"),
    ("Select a sentence to practice.", "选择一句进行练习。"),
    ("Setup required", "需要设置"),
    ("Some sentences are not translated; they are exported in the original.", "部分句子没有译文，将以原文导出。"),
    (
        "Speaker labels, word timing, language detection and optional translation during transcription.",
        "说话人标签、逐词时间轴、语言检测，并可在转写时翻译。",
    ),
    ("Split at cursor", "在光标处拆分"),
    ("Stop watching", "停止监视"),
    ("Subtitle formats always include timestamps.", "字幕格式始终包含时间戳。"),
    ("Subtitles imported.", "字幕已导入。"),
    ("Tags", "标签"),
    ("Tags…", "标签…"),
    ("Testing…", "正在测试…"),
    ("There is no transcript to export yet.", "还没有可导出的转写。"),
    ("This episode is already in your Library.", "这一集已在资料库中。"),
    ("This provider has no API key yet.", "该服务商还没有 API 密钥。"),
    ("This recording has no transcript", "此录音没有转写"),
    ("This recording's format cannot be played here.", "此录音的格式无法在这里播放。"),
    ("Title", "标题"),
    ("Transcribe all", "全部转写"),
    ("Transcribe it from the Library first.", "请先在资料库中转写它。"),
    ("Translate after transcription", "转写后翻译"),
    ("Translate again", "重新翻译"),
    ("Translate during transcription", "转写时翻译"),
    ("Translate with LLM", "用大模型翻译"),
    ("Translating", "翻译中"),
    ("Translation stopped before it finished.", "翻译在完成前已停止。"),
    ("Updates apply to the installed app, not to a development run.", "更新只适用于已安装的应用，不适用于开发运行。"),
    ("Use a subtitle file…", "使用字幕文件…"),
    ("Watched folder", "监视文件夹"),
    ("Watching", "正在监视"),
    ("Your turn…", "轮到你了…"),
    ("key is valid.", "密钥有效。"),
    ("models available.", "个可用模型。"),
    ("sentences", "句"),
    ("Video", "视频"),
    ("Practice", "练习"),
    ("Search", "搜索"),
    ("Stop", "停止"),
    ("Translation", "译文"),
    ("Worth studying", "值得精听"),
    ("Popular", "热门"),
    ("News English", "新闻英语"),
    ("Explainers", "讲解"),
    ("Interviews", "访谈"),
    ("Science in English", "科学英语"),
    ("Business English", "商务英语"),
    ("Stories", "故事"),
    ("Application", "应用"),
    ("Playback", "播放"),
    ("Transcribe everything that is ready", "转写所有就绪的录音"),
    ("Play or pause", "播放或暂停"),
    ("Save an edit, or check your answer", "保存编辑，或检查你的答案"),
    ("Cancel an edit, close search, or go back", "取消编辑、关闭搜索或返回"),
    ("Version", "版本"),
    ("Vocabulary", "词汇"),
    ("Expression", "表达"),
    ("Grammar", "语法"),
    ("Target reps", "目标遍数"),
    ("Close player", "关闭播放器"),
    ("Hide sidebar", "隐藏边栏"),
    ("Show sidebar", "显示边栏"),
    ("Show or hide the sidebar", "显示或隐藏边栏"),
    ("Video on top", "视频在上方"),
    ("Video at the side", "视频在侧边"),
    ("Relink media…", "重新关联媒体…"),
    ("Media relinked.", "媒体已重新关联。"),
    ("Save episode as…", "将单集另存为…"),
    ("Saved.", "已保存。"),
    ("Choose a subtitle file", "选择字幕文件"),
    ("Several subtitle files match", "有多个字幕文件匹配"),
    ("Subtitle file", "字幕文件"),
    ("Not now", "暂不"),
    ("Use it", "使用"),
    ("Open Listenook at login", "登录时打开聆页"),
    ("Open video…", "打开视频…"),
    ("Subtitles off", "关闭字幕"),
    ("Previous subtitle", "上一条字幕"),
    ("Next subtitle", "下一条字幕"),
    ("Repeat this subtitle", "重复当前字幕"),
    ("Add audio or video", "添加音频或视频"),
    ("Change folder", "更换文件夹"),
    ("Choose folder", "选择文件夹"),
    ("Open Settings", "打开设置"),
    ("Open video", "打开视频"),
    ("Refresh AI Brief", "刷新 AI 简报"),
    ("Export shown as ZIP", "将显示的项目导出为 ZIP"),
    ("File", "文件"),
    ("View", "显示"),
    ("Window", "窗口"),
    ("About Listenook", "关于聆页"),
    ("Hide Listenook", "隐藏聆页"),
    ("Hide Others", "隐藏其他"),
    ("Show All", "全部显示"),
    ("Close Window", "关闭窗口"),
    ("Undo", "撤销"),
    ("Redo", "重做"),
    ("Cut", "剪切"),
    ("Paste", "粘贴"),
    ("Select All", "全选"),
    ("Show or Hide Sidebar", "显示或隐藏边栏"),
    ("Enter or Leave Full Screen", "进入或退出全屏"),
    ("Zoom", "缩放"),
    (
        "Choose audio or video from the Files app. Up to 5 hours each.",
        "从“文件”App 中选取音频或视频。每个文件最长 5 小时。",
    ),
    (
        "Put files in the Listenook folder in the Files app, then tap Add media. Up to 5 hours each.",
        "把文件放进“文件”App 中的“聆页”文件夹，然后轻点“添加媒体”。每个文件最长 5 小时。",
    ),
    (
        "Put audio or video in the Listenook folder in the Files app, then tap + again.",
        "请把音频或视频放进“文件”App 中的“聆页”文件夹，然后再次轻点 +。",
    ),
    ("Saved to the Listenook folder in Files, under Exports.", "已保存到“文件”App 中“聆页”文件夹的 Exports 下。"),
    ("Open Listenook", "打开聆页"),
    ("Pause watching", "暂停监视"),
    ("Resume watching", "继续监视"),
    ("Quit Listenook", "退出聆页"),
    ("Keep Listenook in the menu bar", "在菜单栏中保留聆页"),
    ("Closing the window then hides it; Listenook keeps running.", "关闭窗口后只是隐藏，聆页会继续运行。"),
    ("Keep Listenook in the tray", "在托盘中保留聆页"),
    ("Download finished", "下载完成"),
    ("Transcription finished", "转写完成"),
    ("Download failed", "下载失败"),
    ("Transcription failed", "转写失败"),
    ("Notify me when transcriptions and downloads finish", "转写和下载完成时通知我"),
    ("From any app", "在任何应用中"),
    ("Play or pause with ⌃⌥Space", "用 ⌃⌥空格 播放或暂停"),
    (
        "Works while another app is in front. Off unless you turn it on: it takes the keystroke from every app.",
        "其他应用在前台时也有效。默认关闭：开启后它会占用所有应用中的这个按键。",
    ),
];

/// `text` in `lang`.
pub fn tr(lang: Lang, text: &'static str) -> &'static str {
    match lang {
        Lang::En => text,
        Lang::Zh => ZH.iter().find(|(en, _)| *en == text).map_or(text, |(_, zh)| zh),
    }
}

/// A job status as the user reads it (English; pass through [`tr`]).
pub fn status_label(status: JobStatus) -> &'static str {
    match status {
        JobStatus::Pending => "Pending",
        JobStatus::Probing => "Inspecting",
        JobStatus::Ready => "Ready",
        JobStatus::Downloading => "Downloading",
        JobStatus::Converting => "Converting",
        JobStatus::Uploading => "Uploading",
        JobStatus::QueuedRemote => "Queued by transcription provider",
        JobStatus::Processing => "Transcribing",
        JobStatus::Fetching => "Fetching transcript",
        JobStatus::Aligning => "Generating precise timeline",
        JobStatus::Completed => "Completed",
        JobStatus::Empty => "No speech found",
        JobStatus::Failed => "Failed",
        JobStatus::Cancelled => "Cancelled",
        JobStatus::MissingSource => "Source missing",
        JobStatus::Paused => "Paused",
    }
}

/// What to tell the user for an error code: what happened and what to do.
pub fn error_message(lang: Lang, code: &str) -> String {
    let (en, zh) = match code {
        "missing_credentials" | "moss_missing_credentials" => {
            ("Add an API key for this provider in Settings.", "请先在设置中添加该服务商的 API 密钥。")
        }
        "bad_credentials"
        | "moss_bad_credentials"
        | "llm_bad_credentials"
        | "translation_bad_credentials"
        | "ai_brief_bad_credentials" => {
            ("The API key was rejected. Check it in Settings.", "API 密钥被拒绝，请在设置中检查。")
        }
        "rate_limit" | "moss_rate_limit" | "translation_rate_limit" | "ai_brief_rate_limit" => {
            ("The provider is rate limiting requests. Try again shortly.", "服务商正在限流，请稍后重试。")
        }
        "exhausted_balance" | "moss_exhausted_balance" | "budget_exhausted" => {
            ("The provider account is out of credit.", "服务商账户余额不足。")
        }
        "server_failure" | "moss_server_failure" => {
            ("The provider had a server error. Try again.", "服务商服务器出错，请重试。")
        }
        "invalid_media" | "moss_invalid_media" => ("The provider could not read this media.", "服务商无法读取该媒体。"),
        "moss_file_too_large" => ("MOSS accepts files up to 512 MB.", "MOSS 最大支持 512 MB 的文件。"),
        "missing_source" => {
            ("The source file is missing. Relink it or remove the item.", "源文件缺失，请重新关联或移除该项。")
        }
        "unsupported_format" => ("This file type is not supported.", "不支持该文件类型。"),
        "duration_limit" => ("Files can be up to 300 minutes long.", "文件最长 300 分钟。"),
        "provider_unavailable" => (
            "This provider is not available in this version. Choose Soniox or MOSS Pro.",
            "此版本不支持该服务商，请选择 Soniox 或 MOSS Pro。",
        ),
        "local_stt_unsupported" | "local_worker_unsupported" | "local_worker_missing" => (
            "Transcription on this Mac needs Apple silicon and the speech helper that ships with the app.",
            "本机转写需要 Apple 芯片以及随应用附带的语音组件。",
        ),
        "local_stt_model_missing" => ("Download this model in Settings first.", "请先在设置中下载该模型。"),
        "local_worker_failed" | "local_worker_invalid_output" | "local_worker_launch_failed" => {
            ("Transcription on this Mac stopped unexpectedly. Try again.", "本机转写意外中止，请重试。")
        }
        "model_download_failed" => {
            ("The download failed. Check the connection and resume.", "下载失败，请检查网络后继续。")
        }
        "model_size_mismatch" | "model_checksum_mismatch" => {
            ("The download was damaged. Download it again.", "下载内容已损坏，请重新下载。")
        }
        "cancelled" => ("Cancelled.", "已取消。"),
        "subtitle_no_valid_cues" => ("The subtitle file has no readable cues.", "字幕文件中没有可读取的字幕。"),
        "subtitle_read_failed" => ("The subtitle file could not be read.", "无法读取字幕文件。"),
        "translation_invalid_url" => ("Enter a valid http or https base URL.", "请输入有效的 http 或 https Base URL。"),
        "translation_https_required" => ("Remote endpoints must use https.", "远程端点必须使用 https。"),
        "translation_model_required" => ("Choose a model.", "请选择模型。"),
        "translation_missing_credentials" | "ai_brief_missing_credentials" | "llm_missing_credentials" => {
            ("Add an API key for the AI provider in Settings.", "请在设置中添加 AI 服务商的 API 密钥。")
        }
        "translation_incomplete_response" => {
            ("Some sentences were not translated. Translate again to finish.", "部分句子未翻译，可再次翻译以完成。")
        }
        "translation_invalid_language" => ("Choose a target language.", "请选择目标语言。"),
        "ai_brief_no_supported_content" | "ai_brief_invalid_response" => (
            "The model returned nothing usable. Try again or choose another model.",
            "模型未返回可用内容，请重试或更换模型。",
        ),
        "ai_brief_empty_transcript" => ("There is no transcript to brief.", "没有可生成简报的转写。"),
        "podcast_search_failed" | "podcast_feed_failed" | "podcast_lookup_failed" => (
            "Couldn’t reach the podcast service. Check your connection and try again.",
            "无法连接播客服务，请检查网络后重试。",
        ),
        "podcast_invalid_feed" => ("That address is not a podcast feed.", "该地址不是播客订阅源。"),
        "podcast_feed_empty" => ("The feed has no playable episodes.", "该订阅源没有可播放的剧集。"),
        "podcast_download_failed" => ("The download failed. Try again.", "下载失败，请重试。"),
        "podcast_transcript_missing" | "podcast_transcript_failed" | "podcast_transcript_untimed" => {
            ("The publisher’s captions could not be used.", "无法使用发布方提供的字幕。")
        }
        "network_error" | "llm_network_error" | "translation_network_error" => {
            ("Couldn’t connect. Check your connection and try again.", "无法连接，请检查网络后重试。")
        }
        _ => ("Something went wrong. Try again.", "出了点问题，请重试。"),
    };
    match lang {
        Lang::En => en.to_owned(),
        Lang::Zh => zh.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chinese_falls_back_to_english() {
        assert_eq!(tr(Lang::Zh, "Inbox"), "收件箱");
        assert_eq!(tr(Lang::Zh, "Unlisted"), "Unlisted");
        assert_eq!(tr(Lang::En, "Inbox"), "Inbox");
        assert_eq!(Lang::of_locale("zh-Hans-CN"), Lang::Zh);
        assert_eq!(tr(Lang::Zh, status_label(JobStatus::Processing)), "转写中");
    }
}
