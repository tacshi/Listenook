use std::collections::BTreeMap;

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};

pub const MANIFEST_VERSION: u32 = 15;
pub const MAX_MEDIA_DURATION_MS: i64 = 300 * 60 * 1000;

pub fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

pub fn iso_from_millis(milliseconds: i64) -> Option<String> {
    chrono::DateTime::from_timestamp_millis(milliseconds)
        .map(|time| time.to_rfc3339_opts(chrono::SecondsFormat::Micros, true))
}

macro_rules! named_enum {
    ($(#[$meta:meta])* $name:ident { $($variant:ident = $text:literal),+ $(,)? } default $default:ident) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub enum $name { $($variant),+ }

        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$variant),+];

            pub fn as_str(self) -> &'static str {
                match self { $($name::$variant => $text),+ }
            }

            pub fn parse(text: &str) -> Self {
                match text { $($text => $name::$variant,)+ _ => $name::$default }
            }
        }

        impl Default for $name {
            fn default() -> Self { $name::$default }
        }

        impl Serialize for $name {
            fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str(self.as_str())
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                let value = Value::deserialize(deserializer)?;
                Ok(value.as_str().map(Self::parse).unwrap_or_default())
            }
        }
    };
}

named_enum!(
    JobStatus {
        Pending = "pending", Probing = "probing", Ready = "ready", Downloading = "downloading",
        Converting = "converting", Uploading = "uploading", QueuedRemote = "queuedRemote",
        Processing = "processing", Fetching = "fetching", Aligning = "aligning",
        Completed = "completed", Empty = "empty", Failed = "failed", Cancelled = "cancelled",
        MissingSource = "missingSource", Paused = "paused",
    } default Pending
);

impl JobStatus {
    pub fn is_active(self) -> bool {
        use JobStatus::*;
        matches!(self, Probing | Downloading | Converting | Uploading | QueuedRemote | Processing | Fetching | Aligning)
    }

    pub fn is_terminal(self) -> bool {
        use JobStatus::*;
        matches!(self, Completed | Empty | Failed | Cancelled | MissingSource)
    }

    pub fn is_transcribable(self) -> bool {
        matches!(self, JobStatus::Ready | JobStatus::Paused)
    }

    pub fn is_retryable(self) -> bool {
        use JobStatus::*;
        matches!(self, Failed | Cancelled | MissingSource | Empty)
    }
}

named_enum!(CleanupState { None = "none", Pending = "pending", Complete = "complete" } default None);
named_enum!(JobSourceOrigin { Manual = "manual", MonitoredFolder = "monitoredFolder", Podcast = "podcast" } default Manual);
named_enum!(
    TranscriptionProvider {
        Soniox = "soniox", MossPro = "mossPro", MossLocal = "mossLocal", Qwen3Local = "qwen3Local",
    } default Soniox
);
named_enum!(
    TranscriptAcquisitionMode {
        Soniox = "soniox", MossPro = "mossPro", MossLocal = "mossLocal",
        PublisherCaptions = "publisherCaptions", Qwen3Local = "qwen3Local",
        ImportedSubtitles = "importedSubtitles",
    } default Soniox
);
named_enum!(
    TranslationStatus {
        Idle = "idle", Translating = "translating", Completed = "completed", Partial = "partial",
        Failed = "failed", Cancelled = "cancelled", Interrupted = "interrupted",
    } default Idle
);
named_enum!(
    AiGenerationStatus {
        Idle = "idle", Generating = "generating", Completed = "completed", Failed = "failed",
        Cancelled = "cancelled", Interrupted = "interrupted",
    } default Idle
);
named_enum!(
    AiBriefSection {
        Overview = "overview", Chapters = "chapters", KeyIdeas = "keyIdeas", Decisions = "decisions",
        ActionItems = "actionItems", OpenQuestions = "openQuestions", LanguageNotes = "languageNotes",
    } default Overview
);
named_enum!(
    AiInsightType {
        KeyIdea = "keyIdea", NotableMoment = "notableMoment", Decision = "decision",
        ActionItem = "actionItem", OpenQuestion = "openQuestion",
    } default KeyIdea
);
named_enum!(AiLanguageNoteKind { Vocabulary = "vocabulary", Expression = "expression", Grammar = "grammar" } default Vocabulary);
named_enum!(AiLearningLevel { Beginner = "beginner", Intermediate = "intermediate", Advanced = "advanced" } default Intermediate);
named_enum!(ThemeMode { System = "system", Light = "light", Dark = "dark" } default System);
named_enum!(LocaleMode { System = "system", English = "english", SimplifiedChinese = "simplifiedChinese" } default System);
named_enum!(ExportFormat { Txt = "txt", Markdown = "markdown", Srt = "srt", WebVtt = "webVtt" } default Txt);
named_enum!(
    ContentMode { Original = "original", Translated = "translated", Bilingual = "bilingual" } default Original
);
named_enum!(
    LlmProvider {
        Custom = "custom", OpenAi = "openAi", OpenRouter = "openRouter", DeepSeek = "deepSeek",
        Groq = "groq", NvidiaNim = "nvidiaNim", TogetherAi = "togetherAi", MistralAi = "mistralAi",
        LmStudio = "lmStudio", Ollama = "ollama", FireworksAi = "fireworksAi",
        Perplexity = "perplexity", VolcengineArk = "volcengineArk",
    } default Custom
);

impl LlmProvider {
    pub fn base_url(self) -> &'static str {
        match self {
            LlmProvider::Custom => "",
            LlmProvider::OpenAi => "https://api.openai.com/v1",
            LlmProvider::OpenRouter => "https://openrouter.ai/api/v1",
            LlmProvider::DeepSeek => "https://api.deepseek.com/v1",
            LlmProvider::Groq => "https://api.groq.com/openai/v1",
            LlmProvider::NvidiaNim => "https://integrate.api.nvidia.com/v1",
            LlmProvider::TogetherAi => "https://api.together.xyz/v1",
            LlmProvider::MistralAi => "https://api.mistral.ai/v1",
            LlmProvider::LmStudio => "http://localhost:1234/v1",
            LlmProvider::Ollama => "http://localhost:11434/v1",
            LlmProvider::FireworksAi => "https://api.fireworks.ai/inference/v1",
            LlmProvider::Perplexity => "https://api.perplexity.ai",
            LlmProvider::VolcengineArk => "https://ark.cn-beijing.volces.com/api/v3",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            LlmProvider::Custom => "Custom",
            LlmProvider::OpenAi => "OpenAI",
            LlmProvider::OpenRouter => "OpenRouter",
            LlmProvider::DeepSeek => "DeepSeek",
            LlmProvider::Groq => "Groq",
            LlmProvider::NvidiaNim => "NVIDIA NIM",
            LlmProvider::TogetherAi => "Together AI",
            LlmProvider::MistralAi => "Mistral AI",
            LlmProvider::LmStudio => "LM Studio",
            LlmProvider::Ollama => "Ollama",
            LlmProvider::FireworksAi => "Fireworks AI",
            LlmProvider::Perplexity => "Perplexity",
            LlmProvider::VolcengineArk => "Volcengine Ark",
        }
    }
}

fn is_false(value: &bool) -> bool {
    !*value
}

fn truthy() -> bool {
    true
}

fn loose_string<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<String>, D::Error> {
    Ok(match Value::deserialize(deserializer)? {
        Value::Null => None,
        Value::String(text) => Some(text),
        other => Some(other.to_string()),
    })
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Token {
    pub text: String,
    pub start_ms: i64,
    pub end_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub segment_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", deserialize_with = "loose_string")]
    pub speaker: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub translation_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_language: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Segment {
    pub id: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none", deserialize_with = "loose_string")]
    pub speaker: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub translated_text: Option<String>,
    #[serde(skip_serializing_if = "is_false")]
    pub preserve_boundary_before: bool,
}

impl Segment {
    pub fn has_translation(&self) -> bool {
        self.translated_text.as_deref().is_some_and(|t| !t.trim().is_empty())
    }

    pub fn content(&self, mode: ContentMode) -> String {
        let translated = self.translated_text.as_deref().map(str::trim).filter(|t| !t.is_empty());
        match (mode, translated) {
            (ContentMode::Translated, Some(translated)) => translated.to_owned(),
            (ContentMode::Bilingual, Some(translated)) => format!("{translated}\n{}", self.text),
            _ => self.text.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Speaker {
    #[serde(deserialize_with = "loose_id")]
    pub id: String,
    pub name: String,
}

fn loose_id<'de, D: Deserializer<'de>>(deserializer: D) -> Result<String, D::Error> {
    Ok(loose_string(deserializer)?.unwrap_or_default())
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Document {
    pub tokens: Vec<Token>,
    pub segments: Vec<Segment>,
    pub speakers: Vec<Speaker>,
    pub updated_at: String,
}

impl Document {
    pub fn speaker_name(&self, id: Option<&str>) -> String {
        let Some(id) = id.filter(|id| !id.is_empty()) else {
            return String::new();
        };
        self.speakers
            .iter()
            .find(|speaker| speaker.id == id)
            .map(|speaker| speaker.name.clone())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| format!("Speaker {id}"))
    }

    pub fn touch(&mut self) {
        self.updated_at = now_iso();
    }

    pub fn play_start(&self, index: usize) -> Option<i64> {
        let segment = self.segments.get(index)?;
        let before = index.checked_sub(1).map_or(0, |before| self.segments[before].end_ms);
        Some((segment.start_ms - LEAD_IN_MS).max(before).max(0).min(segment.start_ms))
    }

    pub fn segment_at(&self, position_ms: i64) -> Option<usize> {
        let after = self.segments.partition_point(|segment| segment.start_ms <= position_ms);
        if self.play_start(after).is_some_and(|start| start <= position_ms) {
            return Some(after);
        }
        after.checked_sub(1)
    }
}

pub const LEAD_IN_MS: i64 = 250;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct JobProgress {
    pub stage: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fraction: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl Default for JobProgress {
    fn default() -> Self {
        Self { stage: "pending".into(), fraction: None, detail: None }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MediaMetadata {
    pub size_bytes: i64,
    pub duration_ms: i64,
    pub has_audio: bool,
    pub has_video: bool,
    pub format_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub video_codec: Option<String>,
}

impl Default for MediaMetadata {
    fn default() -> Self {
        Self {
            size_bytes: 0,
            duration_ms: 0,
            has_audio: false,
            has_video: false,
            format_name: "unknown".into(),
            audio_codec: None,
            video_codec: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SonioxTranslationOptions {
    pub enabled: bool,
    pub target_language: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TranscriptionOptions {
    pub language_hints: Vec<String>,
    pub context_terms: Vec<String>,
    pub soniox_translation: SonioxTranslationOptions,
    pub enable_speaker_diarization: bool,
    pub enable_language_identification: bool,
}

impl Default for TranscriptionOptions {
    fn default() -> Self {
        Self {
            language_hints: Vec::new(),
            context_terms: Vec::new(),
            soniox_translation: SonioxTranslationOptions::default(),
            enable_speaker_diarization: true,
            enable_language_identification: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct TranslationOptions {
    pub enabled: bool,
    pub target_language: String,
    pub base_url: String,
    pub model: String,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct TranslationState {
    pub status: TranslationStatus,
    pub target_language: String,
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    pub completed_segments: u32,
    pub total_segments: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct PodcastTranscriptReference {
    pub url: String,
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rel: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct PodcastProvenance {
    pub feed_url: String,
    pub episode_id: String,
    pub enclosure_url: String,
    pub show_title: String,
    pub episode_title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artwork_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub published_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub transcripts: Vec<PodcastTranscriptReference>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct AiChapter {
    pub id: String,
    pub title: String,
    pub summary: String,
    pub evidence_segment_ids: Vec<String>,
    pub edited: bool,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct AiInsight {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: AiInsightType,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deadline: Option<String>,
    pub evidence_segment_ids: Vec<String>,
    pub edited: bool,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct AiLanguageNote {
    pub id: String,
    pub kind: AiLanguageNoteKind,
    pub term: String,
    pub explanation: String,
    pub source_excerpt: String,
    pub evidence_segment_ids: Vec<String>,
    pub edited: bool,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct AiBrief {
    pub overview: String,
    pub overview_evidence_segment_ids: Vec<String>,
    pub chapters: Vec<AiChapter>,
    pub insights: Vec<AiInsight>,
    pub language_notes: Vec<AiLanguageNote>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub learning_language: Option<String>,
    pub learning_level: AiLearningLevel,
    pub output_language: String,
    pub model: String,
    pub selected_sections: Vec<AiBriefSection>,
    pub generated_at: String,
    pub source_transcript_updated_at: String,
    pub edited: bool,
}

impl AiBrief {
    pub fn is_empty(&self) -> bool {
        self.overview.trim().is_empty()
            && self.chapters.is_empty()
            && self.insights.is_empty()
            && self.language_notes.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct AiGenerationState {
    pub status: AiGenerationStatus,
    pub stage: String,
    pub completed_chunks: u32,
    pub total_chunks: u32,
    pub output_language: String,
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Job {
    pub manifest_version: u32,
    pub id: String,
    pub batch_id: String,
    pub source_path: String,
    pub created_at: String,
    pub updated_at: String,
    pub status: JobStatus,
    pub queue_index: i64,
    pub progress: JobProgress,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<MediaMetadata>,
    pub options: TranscriptionOptions,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document: Option<Document>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_file_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_transcription_id: Option<String>,
    pub cleanup_state: CleanupState,
    pub translation_options: TranslationOptions,
    pub translation_state: TranslationState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ai_brief: Option<AiBrief>,
    pub ai_generation_state: AiGenerationState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_title: Option<String>,
    pub source_origin: JobSourceOrigin,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group_id: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub tag_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub podcast_provenance: Option<PodcastProvenance>,
    pub transcript_acquisition_mode: TranscriptAcquisitionMode,
    pub transcription_provider: TranscriptionProvider,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Default for Job {
    fn default() -> Self {
        let now = now_iso();
        Self {
            manifest_version: MANIFEST_VERSION,
            id: String::new(),
            batch_id: "recovered".into(),
            source_path: String::new(),
            created_at: now.clone(),
            updated_at: now,
            status: JobStatus::Pending,
            queue_index: 0,
            progress: JobProgress::default(),
            metadata: None,
            options: TranscriptionOptions::default(),
            document: None,
            error_code: None,
            error_message: None,
            remote_file_id: None,
            remote_transcription_id: None,
            cleanup_state: CleanupState::None,
            translation_options: TranslationOptions::default(),
            translation_state: TranslationState::default(),
            ai_brief: None,
            ai_generation_state: AiGenerationState::default(),
            display_title: None,
            source_origin: JobSourceOrigin::Manual,
            group_id: None,
            tag_ids: Vec::new(),
            podcast_provenance: None,
            transcript_acquisition_mode: TranscriptAcquisitionMode::Soniox,
            transcription_provider: TranscriptionProvider::Soniox,
            extra: Map::new(),
        }
    }
}

impl Job {
    pub fn is_valid_id(id: &str) -> bool {
        !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    }

    pub fn file_name(&self) -> String {
        self.source_path.rsplit(['/', '\\']).next().unwrap_or(&self.source_path).to_owned()
    }

    pub fn title(&self) -> String {
        if let Some(title) = self.display_title.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
            return title.to_owned();
        }
        if let Some(podcast) = &self.podcast_provenance
            && !podcast.episode_title.trim().is_empty()
        {
            return podcast.episode_title.trim().to_owned();
        }
        let name = self.file_name();
        match name.rsplit_once('.') {
            Some((stem, _)) if !stem.is_empty() => stem.to_owned(),
            _ => name,
        }
    }

    pub fn duration_ms(&self) -> i64 {
        self.metadata.as_ref().map_or(0, |m| m.duration_ms)
    }

    pub fn has_video(&self) -> bool {
        self.metadata.as_ref().is_some_and(|m| m.has_video)
    }

    pub fn is_busy(&self) -> bool {
        self.status.is_active()
            || self.translation_state.status == TranslationStatus::Translating
            || self.ai_generation_state.status == AiGenerationStatus::Generating
    }

    pub fn has_transcript(&self) -> bool {
        self.document.as_ref().is_some_and(|d| !d.segments.is_empty())
    }

    pub fn touch(&mut self) {
        self.updated_at = now_iso();
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Named {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LibraryCatalog {
    pub version: u32,
    pub groups: Vec<Named>,
    pub tags: Vec<Named>,
}

impl Default for LibraryCatalog {
    fn default() -> Self {
        Self { version: 1, groups: Vec::new(), tags: Vec::new() }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ExportOptions {
    pub format: ExportFormat,
    pub show_speakers: bool,
    pub show_timestamps: bool,
    pub locale_code: String,
    pub content_mode: ContentMode,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            format: ExportFormat::Txt,
            show_speakers: true,
            show_timestamps: false,
            locale_code: "en".into(),
            content_mode: ContentMode::Original,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct LlmProviderSettings {
    pub provider: LlmProvider,
    pub base_url: String,
    pub model: String,
}

impl LlmProviderSettings {
    pub fn endpoint(&self) -> String {
        self.base_url.trim().trim_end_matches('/').to_owned()
    }

    pub fn is_loopback(&self) -> bool {
        let url = self.endpoint();
        let host = url.split("://").nth(1).unwrap_or("").split(['/', ':']).next().unwrap_or("");
        matches!(host, "localhost" | "127.0.0.1") || url.contains("://[::1]")
    }

    pub fn validate(&self) -> Option<&'static str> {
        let url = self.endpoint();
        let Some((scheme, rest)) = url.split_once("://") else {
            return Some("translation_invalid_url");
        };
        let host = rest.split('/').next().unwrap_or("");
        if !matches!(scheme, "http" | "https")
            || host.is_empty()
            || host.contains('@')
            || rest.contains('?')
            || rest.contains('#')
        {
            return Some("translation_invalid_url");
        }
        if scheme != "https" && !self.is_loopback() {
            return Some("translation_https_required");
        }
        if self.model.trim().is_empty() {
            return Some("translation_model_required");
        }
        None
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct TranslationPreferences {
    pub target_language: String,
    pub auto_translate: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub manifest_version: u32,
    pub theme_mode: ThemeMode,
    pub locale_mode: LocaleMode,
    pub show_speakers: bool,
    pub show_timestamps: bool,
    pub blind_listening_enabled: bool,
    pub mimic_rep_goal: u32,
    pub mimic_pause_seconds: u32,
    pub export_options: ExportOptions,
    pub llm_provider_settings: LlmProviderSettings,
    pub translation_preferences: TranslationPreferences,
    pub soniox_translation: SonioxTranslationOptions,
    pub default_transcription_provider: TranscriptionProvider,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub playback_positions_ms: BTreeMap<String, i64>,
    #[serde(default = "truthy")]
    pub auto_align_transcripts: bool,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            manifest_version: MANIFEST_VERSION,
            theme_mode: ThemeMode::System,
            locale_mode: LocaleMode::System,
            show_speakers: true,
            show_timestamps: false,
            blind_listening_enabled: false,
            mimic_rep_goal: 3,
            mimic_pause_seconds: 0,
            export_options: ExportOptions::default(),
            llm_provider_settings: LlmProviderSettings::default(),
            translation_preferences: TranslationPreferences::default(),
            soniox_translation: SonioxTranslationOptions::default(),
            default_transcription_provider: TranscriptionProvider::Soniox,
            playback_positions_ms: BTreeMap::new(),
            auto_align_transcripts: true,
            extra: Map::new(),
        }
    }
}

impl Settings {
    pub fn sanitized(mut self) -> Self {
        if self.mimic_rep_goal == 0 {
            self.mimic_rep_goal = 3;
        }
        if self.mimic_pause_seconds > 10 {
            self.mimic_pause_seconds = 0;
        }
        self.manifest_version = MANIFEST_VERSION;
        self
    }
}

pub const TRANSLATION_LANGUAGES: &[(&str, &str)] = &[
    ("en", "English"),
    ("zh-Hans", "Simplified Chinese"),
    ("zh-Hant", "Traditional Chinese"),
    ("ja", "Japanese"),
    ("ko", "Korean"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("de", "German"),
    ("it", "Italian"),
    ("pt", "Portuguese"),
    ("ru", "Russian"),
    ("ar", "Arabic"),
    ("hi", "Hindi"),
    ("vi", "Vietnamese"),
    ("th", "Thai"),
    ("yue", "Cantonese"),
    ("nl", "Dutch"),
    ("pl", "Polish"),
    ("tr", "Turkish"),
    ("uk", "Ukrainian"),
    ("cs", "Czech"),
    ("sv", "Swedish"),
    ("da", "Danish"),
    ("fi", "Finnish"),
    ("el", "Greek"),
    ("he", "Hebrew"),
    ("id", "Indonesian"),
    ("ms", "Malay"),
];

pub fn language_name(code: &str) -> Option<&'static str> {
    TRANSLATION_LANGUAGES.iter().find(|(c, _)| *c == code).map(|(_, name)| *name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_manifest_of_the_flutter_app_reads_and_keeps_unknown_keys() {
        let json = r#"{"manifest_version":15,"id":"a-1","source_path":"/m/talk.mp3","status":"queuedRemote",
            "tag_ids":["x"],"forced_alignment":{"status":"completed"},
            "document":{"segments":[{"id":"segment-1","start_ms":0,"end_ms":900,"text":"Hi.","speaker":1}],
            "speakers":[{"id":1,"name":"Ann"}]}}"#;
        let job: Job = serde_json::from_str(json).unwrap();
        assert_eq!(job.status, JobStatus::QueuedRemote);
        assert_eq!(job.title(), "talk");
        let document = job.document.as_ref().unwrap();
        assert_eq!(document.speaker_name(Some("1")), "Ann");
        assert_eq!(document.speaker_name(Some("7")), "Speaker 7");
        let written = serde_json::to_value(&job).unwrap();
        assert_eq!(written["tag_ids"][0], "x");
        assert_eq!(written["forced_alignment"]["status"], "completed");
    }

    #[test]
    fn a_sentence_plays_from_a_little_before_its_marked_start() {
        let segment = |start_ms, end_ms| Segment { start_ms, end_ms, ..Default::default() };
        let document = Document {
            segments: vec![segment(210, 5070), segment(5200, 9000), segment(9900, 12000), segment(11900, 13000)],
            ..Default::default()
        };
        assert_eq!(document.play_start(0), Some(0));
        assert_eq!(document.play_start(1), Some(5070));
        assert_eq!(document.play_start(2), Some(9650));
        assert_eq!(document.play_start(3), Some(11900));
        assert_eq!(document.play_start(4), None);
        assert_eq!(document.segment_at(0), Some(0));
        assert_eq!(document.segment_at(5069), Some(0));
        assert_eq!(document.segment_at(5070), Some(1));
        assert_eq!(document.segment_at(9649), Some(1));
        assert_eq!(document.segment_at(9650), Some(2));
        assert_eq!(document.segment_at(11950), Some(3));
        assert_eq!(Document::default().segment_at(100), None);
    }

    #[test]
    fn an_unknown_enum_name_reads_as_the_default() {
        let job: Job = serde_json::from_str(r#"{"id":"a","status":"teleporting"}"#).unwrap();
        assert_eq!(job.status, JobStatus::Pending);
    }

    #[test]
    fn llm_settings_validate_as_the_app_does() {
        let mut settings = LlmProviderSettings { base_url: "http://example.com/v1".into(), ..Default::default() };
        assert_eq!(settings.validate(), Some("translation_https_required"));
        settings.base_url = "http://localhost:1234/v1/".into();
        assert_eq!(settings.validate(), Some("translation_model_required"));
        settings.model = "m".into();
        assert_eq!(settings.validate(), None);
        assert!(settings.is_loopback());
    }
}
