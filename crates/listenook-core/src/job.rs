//! What happens to a recording over its life: transcribing it, its transcript and what is made
//! from it (a translation, a brief, the ads found in it), and how the library files it. Code
//! outside a [`Job`] reads it through these and changes it through these, so each change leaves
//! it whole: a failure says why, a new transcript drops what was made from the old one.

use std::{cmp::Ordering, sync::Arc};

use serde_json::Value;

use crate::models::{
    AdFinding, AdScan, AiBrief, AiBriefSection, AiGenerationState, AiGenerationStatus, AiLearningLevel, CleanupState,
    Document, Job, JobProgress, JobSourceOrigin, JobStatus, MediaMetadata, PodcastProvenance, Settings,
    TranscriptAcquisitionMode, TranscriptionOptions, TranscriptionProvider, TranslationOptions, TranslationState,
    TranslationStatus, now_iso,
};

/// Where a job keeps the record of timing its words.
const ALIGNMENT: &str = "forced_alignment";

/// Something that happens to a recording: code outside a [`Job`] changes it only by
/// [`apply`](Job::apply)ing these.
#[derive(Debug)]
pub enum Change<'a> {
    /// Takes the options for transcribing and translating it from `settings`, with the
    /// languages and terms given for this one.
    ApplyOptions(&'a Settings, Vec<String>, Vec<String>),
    /// Becomes the podcast episode `podcast` says, to download to `path`: what it is called,
    /// the language it is said in, and whether its publisher's transcript comes with it.
    DownloadEpisode(String, PodcastProvenance),
    /// Its downloaded episode came without a transcript: it waits to be transcribed.
    AwaitsTranscription,
    /// Its media is now at `path`, the file it had being called `name`.
    TakeMedia(String, &'a str),
    /// Calls it `title` in the library.
    Rename(&'a str),
    /// Files it in the group `id`, or in none.
    FileIn(Option<&'a str>),
    /// Takes it out of the group `id`, if it is in it.
    LeaveGroup(&'a str),
    /// Tags it with `id`, or untags it when it has the tag.
    ToggleTag(&'a str),
    DropTag(&'a str),
    /// Starts work at `stage` as `status`, with nothing failed.
    Start(JobStatus, &'a str),
    /// Moves on to `stage` as `status`, how far it is not known yet.
    Advance(JobStatus, &'a str),
    /// How far `stage` is.
    SetProgress(&'a str, Option<f64>),
    /// The work failed with the error `code`: its media is gone, or it failed otherwise.
    Fail(&'a str, Option<String>),
    /// The work is done: it has a transcript, or found no speech to transcribe.
    Finish(bool),
    /// The person stopped the work before it had a transcript.
    Cancel,
    /// Waits to be transcribed from the start, or for its media to be found when it is `missing`.
    ReadyAgain(bool),
    /// Forgets what was sent to a transcription service, to send it again.
    ForgetUpload,
    /// Its media reached a transcription service as `file_id`, to delete there once done.
    Uploaded(String),
    /// The service queued transcribing it as `transcription_id`.
    Queued(String),
    /// What it left with a transcription service is deleted there.
    CleanedUp,
    /// Notes what its media is, unless it is known.
    NoteMedia(MediaMetadata),
    /// Puts `document` in place of its transcript, got the way `mode` says (by its provider
    /// when `None`), dropping what was made from the one it replaces.
    ReplaceTranscript(Document, Option<TranscriptAcquisitionMode>),
    /// Its transcript came translated into `target` by `model`, `translated` of its `total`
    /// sentences.
    TranslatedWithTranscript(&'a str, &'a str, u32, u32),
    /// Its words start being timed.
    BeginAlignment,
    /// Timing its words ended, as `record` tells.
    EndAlignment(Value),
    /// Picks up where the app left it when it stopped: work that was running is not, and a
    /// download cut short failed.
    Recover,
    /// Finds its media at `path`: one that was missing is ready again.
    Relink(String),
    /// Starts translating `total` sentences into `target` with `model`.
    BeginTranslation(&'a str, &'a str, u32),
    /// Puts each translated sentence, by ID, in place: `done` of them so far.
    AddTranslations(Vec<(String, String)>, u32),
    /// Translating ended as `status`, with the error `code` to show if any.
    EndTranslation(TranslationStatus, Option<String>),
    /// The person stopped translating: what was translated stays.
    StopTranslation,
    /// Lets go of how translating went, as when it is dismissed.
    DismissTranslation,
    /// Starts writing a brief in `output_language` with `model`, of `sections` at `level`,
    /// studying the highlights first when there are some.
    BeginBrief(&'a str, &'a str, Vec<AiBriefSection>, AiLearningLevel, bool),
    /// Writing the brief is at `stage`, with the questions of it answered and how many it has.
    BriefAt(&'a str, Option<(u32, u32)>),
    BriefMade(AiBrief),
    BriefFailed(String),
    BriefCancelled,
    /// Starts looking for its ads, unless a search is running.
    BeginAdScan,
    /// The chunks of the transcript searched for ads so far, and how many there are.
    AdScanAt(u32, u32),
    /// The search for ads ended, having searched `total` chunks and found `found`.
    AdsFound(Vec<AdFinding>, u32),
    AdScanFailed(String),
    /// Forgets the ads found, skipped or turned down, and any search for them.
    ForgetAds,
    /// Marks it changed now, for sync to tell it from an older copy.
    Touch,
}

/// Where a search found a recording.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Found {
    /// In its title or its file's name.
    Name,
    /// In a sentence of its transcript: the line that has it, and when it is said.
    Sentence { start_ms: i64, text: String },
}

impl Job {
    /// Applies `change` to it.
    pub fn apply(&mut self, change: Change<'_>) {
        match change {
            Change::ApplyOptions(settings, language_hints, context_terms) => {
                self.apply_options(settings, language_hints, context_terms)
            }
            Change::DownloadEpisode(path, podcast) => self.download_episode(path, podcast),
            Change::AwaitsTranscription => self.awaits_transcription(),
            Change::TakeMedia(path, name) => self.take_media(path, name),
            Change::Rename(title) => self.rename(title),
            Change::FileIn(group) => self.file_in(group),
            Change::LeaveGroup(id) => self.leave_group(id),
            Change::ToggleTag(id) => self.toggle_tag(id),
            Change::DropTag(id) => self.drop_tag(id),
            Change::Start(status, stage) => self.start(status, stage),
            Change::Advance(status, stage) => self.advance(status, stage),
            Change::SetProgress(stage, fraction) => self.set_progress(stage, fraction),
            Change::Fail(code, message) => self.fail(code, message),
            Change::Finish(empty) => self.finish(empty),
            Change::Cancel => self.cancel(),
            Change::ReadyAgain(missing) => self.ready_again(missing),
            Change::ForgetUpload => self.forget_upload(),
            Change::Uploaded(file_id) => self.uploaded(file_id),
            Change::Queued(transcription_id) => self.queued(transcription_id),
            Change::CleanedUp => self.cleaned_up(),
            Change::NoteMedia(metadata) => self.note_media(metadata),
            Change::ReplaceTranscript(document, mode) => self.replace_transcript(document, mode),
            Change::TranslatedWithTranscript(target, model, translated, total) => {
                self.translated_with_transcript(target, model, translated, total)
            }
            Change::BeginAlignment => self.begin_alignment(),
            Change::EndAlignment(record) => self.end_alignment(record),
            Change::Recover => self.recover(),
            Change::Relink(path) => self.relink(path),
            Change::BeginTranslation(target, model, total) => self.begin_translation(target, model, total),
            Change::AddTranslations(lines, done) => self.add_translations(lines, done),
            Change::EndTranslation(status, code) => self.end_translation(status, code),
            Change::StopTranslation => self.stop_translation(),
            Change::DismissTranslation => self.dismiss_translation(),
            Change::BeginBrief(output_language, model, sections, level, studying) => {
                self.begin_brief(output_language, model, sections, level, studying)
            }
            Change::BriefAt(stage, counts) => self.brief_at(stage, counts),
            Change::BriefMade(brief) => self.brief_made(brief),
            Change::BriefFailed(code) => self.brief_failed(code),
            Change::BriefCancelled => self.brief_cancelled(),
            Change::BeginAdScan => self.begin_ad_scan(),
            Change::AdScanAt(done, total) => self.ad_scan_at(done, total),
            Change::AdsFound(found, total) => self.ads_found(found, total),
            Change::AdScanFailed(code) => self.ad_scan_failed(code),
            Change::ForgetAds => self.forget_ads(),
            Change::Touch => self.touch(),
        }
    }

    /// A recording of the media at `path`, ready to transcribe.
    pub fn new(id: String, path: &str, origin: JobSourceOrigin) -> Job {
        Job {
            id,
            batch_id: "inbox".into(),
            source_path: path.to_owned(),
            status: JobStatus::Ready,
            source_origin: origin,
            progress: JobProgress { stage: "ready".into(), ..JobProgress::default() },
            ..Job::default()
        }
    }

    pub fn status(&self) -> JobStatus {
        self.status
    }

    /// How far the stage it is at has gone, when that is known.
    pub fn fraction(&self) -> Option<f32> {
        self.progress.fraction.map(|fraction| fraction as f32)
    }

    pub fn provider(&self) -> TranscriptionProvider {
        self.transcription_provider
    }

    /// The transcript, shared: it changes only through the job.
    pub fn document(&self) -> Option<Arc<Document>> {
        self.document.clone()
    }

    pub fn brief(&self) -> Option<AiBrief> {
        self.ai_brief.clone()
    }

    pub fn has_brief(&self) -> bool {
        self.ai_brief.is_some()
    }

    /// How writing its brief went last.
    pub fn brief_state(&self) -> AiGenerationState {
        self.ai_generation_state.clone()
    }

    /// How translating it went last.
    pub fn translation(&self) -> TranslationState {
        self.translation_state.clone()
    }

    /// How looking for its ads went last, and what was found.
    pub fn ads(&self) -> AdScan {
        self.ad_scan.clone()
    }

    pub fn is_scanning_for_ads(&self) -> bool {
        self.ad_scan.status == AiGenerationStatus::Generating
    }

    pub fn podcast(&self) -> Option<PodcastProvenance> {
        self.podcast_provenance.clone()
    }

    /// Whether it is the podcast episode `episode_id`.
    pub fn is_episode(&self, episode_id: &str) -> bool {
        self.podcast_provenance.as_ref().is_some_and(|podcast| podcast.episode_id == episode_id)
    }

    pub fn options(&self) -> TranscriptionOptions {
        self.options.clone()
    }

    pub fn translation_options(&self) -> TranslationOptions {
        self.translation_options.clone()
    }

    pub fn in_group(&self, id: &str) -> bool {
        self.group_id.as_deref() == Some(id)
    }

    pub fn has_tag(&self, id: &str) -> bool {
        self.tag_ids.iter().any(|tag| tag == id)
    }

    /// Orders it against `other` by when each was added.
    pub fn cmp_added(&self, other: &Job) -> Ordering {
        self.created_at.cmp(&other.created_at)
    }

    /// Whether its media was sent to a transcription service, and is still there.
    pub fn is_uploaded(&self) -> bool {
        self.remote_file_id.is_some()
    }

    /// Whether a subtitle file can become its transcript now: not while it is being downloaded
    /// or transcribed, whose work the new transcript would cut short.
    /// Where `needle`, in lower case, is in this recording: its name first, then the first
    /// sentence shown that has it, in its words or their translation. A single character is
    /// looked for in names only, as nearly every sentence has it.
    pub fn find(&self, needle: &str) -> Option<Found> {
        if self.title().to_lowercase().contains(needle) || self.file_name().to_lowercase().contains(needle) {
            return Some(Found::Name);
        }
        if needle.chars().count() < 2 {
            return None;
        }
        self.document.as_ref()?.segments.iter().filter(|segment| !segment.skipped).find_map(|segment| {
            let has = |text: &&str| text.to_lowercase().contains(needle);
            let text = Some(segment.text.as_str()).filter(has).or(segment.translated_text.as_deref().filter(has))?;
            Some(Found::Sentence { start_ms: segment.start_ms, text: text.trim().to_owned() })
        })
    }

    pub fn takes_subtitles(&self) -> bool {
        !self.status.is_active() || self.status == JobStatus::Probing
    }

    /// Whether a finished job left its media with a service, as deleting it there failed.
    pub fn needs_cleanup(&self) -> bool {
        self.cleanup_state == CleanupState::Pending && self.status.is_terminal()
    }

    /// Takes the options for transcribing and translating it from `settings`, with the
    /// languages and terms given for this one.
    fn apply_options(&mut self, settings: &Settings, language_hints: Vec<String>, context_terms: Vec<String>) {
        self.transcription_provider = settings.default_transcription_provider;
        self.options.language_hints = language_hints;
        self.options.context_terms = context_terms;
        self.options.soniox_translation = settings.soniox_translation.clone();
        let preferences = &settings.translation_preferences;
        self.translation_options.enabled = preferences.auto_translate;
        self.translation_options.target_language = Some(preferences.target_language.clone())
            .filter(|target| !target.is_empty())
            .unwrap_or_else(|| "en".into());
        self.translation_options.base_url = settings.llm_provider_settings.endpoint();
        self.translation_options.model = settings.llm_provider_settings.model.clone();
    }

    /// Becomes the podcast episode `podcast` says, to download to `path`: what it is called,
    /// the language it is said in, and whether its publisher's transcript comes with it.
    fn download_episode(&mut self, path: String, podcast: PodcastProvenance) {
        self.source_path = path;
        self.display_title = Some(podcast.episode_title.clone());
        if let Some(language) = podcast.language.as_deref().and_then(|l| l.split(['-', '_']).next()) {
            self.options.language_hints = vec![language.to_lowercase()];
        }
        if !podcast.transcripts.is_empty() {
            self.transcript_acquisition_mode = TranscriptAcquisitionMode::PublisherCaptions;
        }
        self.podcast_provenance = Some(podcast);
        self.start(JobStatus::Downloading, "downloading");
    }

    /// Its downloaded episode came without a transcript: it waits to be transcribed.
    fn awaits_transcription(&mut self) {
        self.transcript_acquisition_mode = TranscriptAcquisitionMode::parse(self.transcription_provider.as_str());
        self.advance(JobStatus::Ready, "ready");
    }

    /// A recording another device sent with its file named for sync keeps, as its title, the
    /// name its file had there. Whether it took it.
    pub fn keep_title(&mut self, name: &str) -> bool {
        let lost = format!("sync-{}", self.id);
        let title = match name.rsplit_once('.') {
            Some((stem, _)) if !stem.is_empty() => stem,
            _ => name,
        }
        .trim();
        if self.title() != lost || title.is_empty() || title == lost {
            return false;
        }
        self.display_title = Some(title.to_owned());
        true
    }

    /// Its media is now at `path`, the file it had being called `name`.
    fn take_media(&mut self, path: String, name: &str) {
        self.source_path = path;
        self.keep_title(name);
    }

    /// Calls it `title` in the library.
    fn rename(&mut self, title: &str) {
        self.display_title = Some(title.trim().to_owned()).filter(|title| !title.is_empty());
    }

    /// Files it in the group `id`, or in none.
    fn file_in(&mut self, group: Option<&str>) {
        self.group_id = group.map(str::to_owned);
    }

    /// Takes it out of the group `id`, if it is in it.
    fn leave_group(&mut self, id: &str) {
        if self.in_group(id) {
            self.group_id = None;
        }
    }

    /// Tags it with `id`, or untags it when it has the tag.
    fn toggle_tag(&mut self, id: &str) {
        if self.has_tag(id) {
            self.tag_ids.retain(|tag| tag != id);
        } else {
            self.tag_ids.push(id.to_owned());
            self.tag_ids.sort();
        }
    }

    fn drop_tag(&mut self, id: &str) {
        self.tag_ids.retain(|tag| tag != id);
    }

    /// Starts work at `stage` as `status`, with nothing failed.
    fn start(&mut self, status: JobStatus, stage: &str) {
        self.advance(status, stage);
        self.error_code = None;
        self.error_message = None;
    }

    /// Moves on to `stage` as `status`, how far it is not known yet.
    fn advance(&mut self, status: JobStatus, stage: &str) {
        self.status = status;
        self.set_progress(stage, None);
    }

    /// How far `stage` is.
    fn set_progress(&mut self, stage: &str, fraction: Option<f64>) {
        self.progress = JobProgress { stage: stage.to_owned(), fraction, detail: None };
    }

    /// The work failed with the error `code`: its media is gone, or it failed otherwise.
    fn fail(&mut self, code: &str, message: Option<String>) {
        self.status = if code == "missing_source" { JobStatus::MissingSource } else { JobStatus::Failed };
        self.progress.stage = "failed".into();
        self.error_code = Some(code.to_owned());
        self.error_message = message;
    }

    /// The work is done: it has a transcript, or found no speech to transcribe.
    fn finish(&mut self, empty: bool) {
        self.status = if empty { JobStatus::Empty } else { JobStatus::Completed };
        self.set_progress("complete", Some(1.0));
        self.error_code = None;
        self.error_message = None;
    }

    /// The person stopped the work before it had a transcript.
    fn cancel(&mut self) {
        self.status = JobStatus::Cancelled;
        self.progress.stage = "cancelled".into();
        self.error_code = Some("cancelled".into());
    }

    /// Waits to be transcribed from the start, or for its media to be found when it is `missing`.
    fn ready_again(&mut self, missing: bool) {
        self.advance(if missing { JobStatus::MissingSource } else { JobStatus::Ready }, "ready");
        self.error_code = missing.then(|| "missing_source".into());
        self.error_message = None;
        self.forget_upload();
    }

    /// Forgets what was sent to a transcription service, to send it again.
    fn forget_upload(&mut self) {
        self.remote_file_id = None;
        self.remote_transcription_id = None;
        self.cleanup_state = CleanupState::None;
    }

    /// Its media reached a transcription service as `file_id`, to delete there once done.
    fn uploaded(&mut self, file_id: String) {
        self.remote_file_id = Some(file_id);
        self.cleanup_state = CleanupState::Pending;
    }

    /// The service queued transcribing it as `transcription_id`.
    fn queued(&mut self, transcription_id: String) {
        self.remote_transcription_id = Some(transcription_id);
        self.advance(JobStatus::QueuedRemote, "queued_remote");
    }

    /// What it left with a transcription service is deleted there.
    fn cleaned_up(&mut self) {
        self.cleanup_state = CleanupState::Complete;
    }

    /// Notes what its media is, unless it is known. Media noted without its length (a podcast
    /// just downloaded, with no captions to tell it) is not known yet.
    fn note_media(&mut self, metadata: MediaMetadata) {
        if self.metadata.as_ref().is_none_or(|known| known.duration_ms <= 0) {
            self.metadata = Some(metadata);
        }
    }

    /// Puts `document` in place of its transcript, got the way `mode` says (by its provider
    /// when `None`), dropping what was made from the one it replaces.
    fn replace_transcript(&mut self, document: Document, mode: Option<TranscriptAcquisitionMode>) {
        self.document = Some(Arc::new(document));
        self.ai_brief = None;
        self.ai_generation_state = AiGenerationState::default();
        self.ad_scan = AdScan::default();
        self.translation_state = TranslationState::default();
        self.extra.remove(ALIGNMENT);
        self.transcript_acquisition_mode =
            mode.unwrap_or_else(|| TranscriptAcquisitionMode::parse(self.transcription_provider.as_str()));
    }

    /// Its transcript came translated into `target` by `model`, `translated` of its `total`
    /// sentences.
    fn translated_with_transcript(&mut self, target: &str, model: &str, translated: u32, total: u32) {
        self.translation_state = TranslationState {
            status: if translated == total { TranslationStatus::Completed } else { TranslationStatus::Partial },
            target_language: target.to_owned(),
            model: model.to_owned(),
            origin: Some("soniox".into()),
            completed_segments: translated,
            total_segments: total,
            ..TranslationState::default()
        };
    }

    /// Changes its transcript, as an edit the person or a task made.
    pub fn edit_document(&mut self, change: impl FnOnce(&mut Document)) {
        if let Some(document) = &mut self.document {
            let document = Arc::make_mut(document);
            change(document);
            document.touch();
        }
    }

    /// Mends its transcript as it is read, as a newer version reads it: saved so with its next
    /// change, which this is not.
    pub fn repair_document(&mut self, repair: impl FnOnce(&mut Document)) {
        if let Some(document) = &mut self.document {
            repair(Arc::make_mut(document));
        }
    }

    /// Its words start being timed.
    fn begin_alignment(&mut self) {
        self.advance(JobStatus::Aligning, "aligning");
        self.extra.insert(ALIGNMENT.into(), serde_json::json!({"status": "queued"}));
    }

    /// Timing its words ended, as `record` tells.
    fn end_alignment(&mut self, record: Value) {
        self.extra.insert(ALIGNMENT.into(), record);
        self.status = JobStatus::Completed;
        self.set_progress("complete", Some(1.0));
    }

    /// Picks up where the app left it when it stopped: work that was running is not, and a
    /// download cut short failed.
    fn recover(&mut self) {
        if self.status == JobStatus::Downloading {
            self.status = JobStatus::Failed;
            self.error_code = Some("podcast_download_failed".into());
        } else if self.status.is_active() || self.status == JobStatus::Pending {
            let status = if self.has_transcript() { JobStatus::Completed } else { JobStatus::Ready };
            self.advance(status, "ready");
        }
        if self.translation_state.status == TranslationStatus::Translating {
            self.translation_state.status = if self.translation_state.completed_segments > 0 {
                TranslationStatus::Partial
            } else {
                TranslationStatus::Interrupted
            };
        }
        if self.ai_generation_state.status == AiGenerationStatus::Generating {
            self.ai_generation_state.status = AiGenerationStatus::Interrupted;
        }
        if self.ad_scan.status == AiGenerationStatus::Generating {
            // A search cut short finds nothing: tapping Find ads starts it again.
            self.ad_scan = AdScan::default();
        }
    }

    /// Finds its media at `path`: one that was missing is ready again.
    fn relink(&mut self, path: String) {
        self.source_path = path;
        if self.status == JobStatus::MissingSource {
            let status = if self.has_transcript() { JobStatus::Completed } else { JobStatus::Ready };
            self.advance(status, "ready");
        }
        if self.error_code.as_deref() == Some("missing_source") {
            self.error_code = None;
            self.error_message = None;
        }
    }

    /// Starts translating `total` sentences into `target` with `model`.
    fn begin_translation(&mut self, target: &str, model: &str, total: u32) {
        self.translation_state = TranslationState {
            status: TranslationStatus::Translating,
            target_language: target.to_owned(),
            model: model.to_owned(),
            origin: Some("llm".into()),
            completed_segments: 0,
            total_segments: total,
            ..TranslationState::default()
        };
    }

    /// Puts each translated sentence, by ID, in place: `done` of them so far.
    fn add_translations(&mut self, lines: Vec<(String, String)>, done: u32) {
        self.edit_document(|document| {
            for (id, line) in lines {
                if let Some(segment) = document.segments.iter_mut().find(|segment| segment.id == id) {
                    segment.translated_text = Some(line);
                }
            }
        });
        self.translation_state.completed_segments = done;
    }

    /// Translating ended as `status`, with the error `code` to show if any.
    fn end_translation(&mut self, status: TranslationStatus, code: Option<String>) {
        self.translation_state.status = status;
        self.translation_state.error_code = code;
    }

    /// The person stopped translating: what was translated stays.
    fn stop_translation(&mut self) {
        self.translation_state.status = if self.translation_state.completed_segments > 0 {
            TranslationStatus::Partial
        } else {
            TranslationStatus::Cancelled
        };
    }

    /// Lets go of how translating went, as when it is dismissed.
    fn dismiss_translation(&mut self) {
        self.end_translation(TranslationStatus::Idle, None);
    }

    /// Starts writing a brief in `output_language` with `model`, of `sections` at `level`,
    /// studying the highlights first when there are some.
    fn begin_brief(
        &mut self,
        output_language: &str,
        model: &str,
        sections: Vec<AiBriefSection>,
        level: AiLearningLevel,
        studying: bool,
    ) {
        self.ai_generation_state = AiGenerationState {
            status: AiGenerationStatus::Generating,
            stage: if studying { "studying" } else { "analyzing" }.into(),
            output_language: output_language.to_owned(),
            model: model.to_owned(),
            selected_sections: sections,
            learning_level: level,
            ..AiGenerationState::default()
        };
    }

    /// Writing the brief is at `stage`, with the questions of it answered and how many it has.
    fn brief_at(&mut self, stage: &str, counts: Option<(u32, u32)>) {
        self.ai_generation_state.stage = stage.to_owned();
        if let Some((done, total)) = counts {
            self.ai_generation_state.completed_chunks = done;
            self.ai_generation_state.total_chunks = total;
        }
    }

    fn brief_made(&mut self, brief: AiBrief) {
        self.ai_brief = Some(brief);
        self.ai_generation_state.status = AiGenerationStatus::Completed;
        self.ai_generation_state.error_code = None;
    }

    fn brief_failed(&mut self, code: String) {
        self.ai_generation_state.status = AiGenerationStatus::Failed;
        self.ai_generation_state.error_code = Some(code);
    }

    fn brief_cancelled(&mut self) {
        self.ai_generation_state.status = AiGenerationStatus::Cancelled;
    }

    /// Changes the brief it has as the person edits it, marking it edited.
    pub fn edit_brief(&mut self, change: impl FnOnce(&mut AiBrief)) {
        if let Some(brief) = &mut self.ai_brief {
            change(brief);
            brief.edited = true;
        }
    }

    /// Starts looking for its ads, unless a search is running.
    fn begin_ad_scan(&mut self) {
        self.ad_scan = AdScan { status: AiGenerationStatus::Generating, ..AdScan::default() };
    }

    /// The chunks of the transcript searched for ads so far, and how many there are.
    fn ad_scan_at(&mut self, done: u32, total: u32) {
        self.ad_scan.completed_chunks = done;
        self.ad_scan.total_chunks = total;
    }

    /// The search for ads ended, having searched `total` chunks and found `found`.
    fn ads_found(&mut self, found: Vec<AdFinding>, total: u32) {
        self.ad_scan = AdScan {
            status: AiGenerationStatus::Completed,
            completed_chunks: total,
            total_chunks: total,
            found,
            error_code: None,
        };
    }

    fn ad_scan_failed(&mut self, code: String) {
        self.ad_scan = AdScan { status: AiGenerationStatus::Failed, error_code: Some(code), ..AdScan::default() };
    }

    /// Forgets the ads found, skipped or turned down, and any search for them.
    fn forget_ads(&mut self) {
        self.ad_scan = AdScan::default();
    }

    /// Marks it changed now, for sync to tell it from an older copy.
    fn touch(&mut self) {
        self.updated_at = now_iso();
    }
}
