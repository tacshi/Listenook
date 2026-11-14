use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    rc::Rc,
};

use listenook_core::{
    AiGenerationStatus, Document, Job, JobProgress, JobSourceOrigin, JobStatus, LibraryCatalog, LocaleMode, Named,
    Settings, ThemeMode, TranscriptAcquisitionMode, TranslationStatus, l10n::Lang, subtitles,
};
use nsh_core::prelude::*;

use super::{
    monitor::{self, MonitorConfig, MonitorFile, Seen},
    persist,
    podcast::PodcastState,
    sync::SyncState,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub(crate) enum Place {
    #[default]
    Library,
    Podcasts,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) enum Filter {
    #[default]
    All,
    InProgress,
    Group(String),
    Tag(String),
}

impl Filter {
    pub(crate) fn admits(&self, job: &Job) -> bool {
        match self {
            Filter::All => true,
            Filter::InProgress => !job.has_transcript() || job.is_busy(),
            Filter::Group(id) => job.group_id.as_deref() == Some(id.as_str()),
            Filter::Tag(id) => job.tag_ids.iter().any(|tag| tag == id),
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) struct Store {
    owner: Owner,
    root: Stored<Option<PathBuf>>,
    jobs: Signal<Vec<Rc<Job>>>,
    settings: Signal<Settings>,
    catalog: Signal<LibraryCatalog>,
    monitor: Signal<MonitorFile>,
    last_scan: Stored<BTreeMap<String, Seen>>,
    place: Signal<Place>,
    filter: Signal<Filter>,
    open_job: Signal<Option<String>>,
    open_video: Signal<Option<String>>,
    players: Signal<usize>,
    video_only: Signal<bool>,
    settings_open: Signal<bool>,
    update_check: Signal<bool>,
    immersive: Signal<bool>,
    sidebar_hidden: Signal<bool>,
    focused: Signal<bool>,
    drawer: Signal<bool>,
    subtitle_choices: Signal<Vec<(String, Vec<String>)>>,
    language_hints: Signal<String>,
    context_terms: Signal<String>,
    running: Stored<HashMap<String, Spawned<()>>>,
    pub(crate) podcast: PodcastState,
    pub(crate) sync: SyncState,
}

#[derive(Clone, Default)]
struct Handle(Option<Store>);

pub(crate) fn store() -> Store {
    global::<Handle>().get_untracked().0.expect("the root component makes the store")
}

fn recovered(mut job: Job) -> Job {
    if job.status == JobStatus::Downloading {
        job.status = JobStatus::Failed;
        job.error_code = Some("podcast_download_failed".into());
    } else if job.status.is_active() || job.status == JobStatus::Pending {
        job.status = if job.has_transcript() { JobStatus::Completed } else { JobStatus::Ready };
        job.progress = JobProgress { stage: "ready".into(), fraction: None, detail: None };
    }
    if job.translation_state.status == TranslationStatus::Translating {
        job.translation_state.status = if job.translation_state.completed_segments > 0 {
            TranslationStatus::Partial
        } else {
            TranslationStatus::Interrupted
        };
    }
    if job.ai_generation_state.status == AiGenerationStatus::Generating {
        job.ai_generation_state.status = AiGenerationStatus::Interrupted;
    }
    job
}

fn rehomed(mut job: Job, root: &std::path::Path) -> Job {
    if let Some(path) = persist::rehomed(&job.source_path, root, |path| path.exists()) {
        job.source_path = path;
        if job.status == JobStatus::MissingSource {
            job.status = if job.has_transcript() { JobStatus::Completed } else { JobStatus::Ready };
            job.progress = JobProgress { stage: "ready".into(), fraction: None, detail: None };
        }
        if job.error_code.as_deref() == Some("missing_source") {
            job.error_code = None;
            job.error_message = None;
        }
    }
    job
}

impl Store {
    pub(crate) fn install() -> Store {
        persist::learn_data_root();
        let root = persist::data_root();
        let library_catalog = root.as_deref().map(persist::load_library_catalog).unwrap_or_default();
        let root_listened = root.as_deref().map(persist::load_listening).unwrap_or_default();
        let root_monitor = root.as_deref().map(persist::load_monitor).unwrap_or_default();
        let (jobs, settings, catalog) = match &root {
            Some(root) => (
                persist::load_jobs(root)
                    .into_iter()
                    .map(recovered)
                    .map(|job| rehomed(job, root))
                    .map(Rc::new)
                    .collect(),
                persist::load_settings(root),
                persist::load_catalog(root),
            ),
            None => (Vec::new(), Settings::default(), Default::default()),
        };
        let store = Store {
            owner: Owner::current(),
            root: stored(root),
            jobs: signal(jobs),
            settings: signal(settings),
            catalog: signal(library_catalog),
            monitor: signal(root_monitor),
            last_scan: stored(BTreeMap::new()),
            place: signal(Place::default()),
            filter: signal(Filter::default()),
            settings_open: signal(false),
            update_check: signal(false),
            immersive: signal(false),
            sidebar_hidden: signal(false),
            focused: signal(true),
            drawer: signal(false),
            subtitle_choices: signal(Vec::new()),
            open_job: signal(None),
            open_video: signal(None),
            players: signal(0),
            video_only: signal(false),
            language_hints: signal(String::new()),
            context_terms: signal(String::new()),
            running: stored(HashMap::new()),
            podcast: PodcastState::new(catalog, root_listened),
            sync: SyncState::new(),
        };
        match std::env::var("LISTENOOK_START").as_deref() {
            Ok("reader") => {
                let newest = store
                    .jobs
                    .with_untracked(|jobs| jobs.iter().find(|job| job.has_transcript()).map(|job| job.id.clone()));
                store.open_job.set(newest);
            }
            Ok("podcasts") => store.place.set(Place::Podcasts),
            Ok("import") => {
                spawn(async {
                    timer(std::time::Duration::from_millis(500)).await;
                    crate::util::import_shared();
                });
            }
            Ok("settings") => store.settings_open.set(true),
            Ok(start) if start == "sync" || start.starts_with("sync:") => {
                let address = start.strip_prefix("sync:").map(str::to_owned);
                spawn(async move {
                    timer(std::time::Duration::from_millis(500)).await;
                    let sync = crate::state::store().sync;
                    sync.show();
                    if let Some(address) = address {
                        sync.connect(address);
                    }
                });
            }
            _ => {}
        }
        store.podcast.set_rate(store.saved_rate("podcast_rate"));
        store.sidebar_hidden.set(
            store.settings.with_untracked(|s| s.extra.get("sidebar_hidden").and_then(|v| v.as_bool()).unwrap_or(false)),
        );
        if let Some(temporary) = store.data_root().map(|root| root.join("temporary")) {
            for entry in std::fs::read_dir(temporary).into_iter().flatten().flatten() {
                if entry.file_name().to_string_lossy().starts_with("player-") {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
        global::<Handle>().set(Handle(Some(store)));
        store.configure_sync();
        let root = store.data_root();
        cleanup(move || crate::services::sync::release(&root));
        store
    }

    pub(crate) fn data_root(&self) -> Option<PathBuf> {
        self.root.with(|root| root.clone())
    }

    pub(crate) fn place(&self) -> Place {
        self.place.get()
    }

    pub(crate) fn go(&self, place: Place) {
        batch(|| {
            self.open_job.set(None);
            self.open_video.set(None);
            self.place.set(place);
        });
    }

    pub(crate) fn filter(&self) -> Filter {
        self.filter.get()
    }

    pub(crate) fn show(&self, filter: Filter) {
        batch(|| {
            self.open_job.set(None);
            self.open_video.set(None);
            self.place.set(Place::Library);
            self.filter.set(filter);
        });
    }

    pub(crate) fn open_job_id(&self) -> Option<String> {
        self.open_job.get()
    }

    pub(crate) fn open_transcript(&self, id: &str) {
        batch(|| {
            self.open_video.set(None);
            self.open_job.set(Some(id.to_owned()));
        });
    }

    pub(crate) fn open_video_path(&self) -> Option<String> {
        self.open_video.get()
    }

    pub(crate) fn open_video(&self, path: &str) {
        if crate::platform::is_phone() || !crate::pages::open_player(path) {
            self.open_video.set(Some(path.to_owned()));
        }
    }

    pub(crate) fn video_playing(&self) -> bool {
        self.open_video.with(Option::is_some) || self.players.get() > 0
    }

    pub(crate) fn player_opened(&self) {
        self.players.update(|count| *count += 1);
    }

    pub(crate) fn player_closed(&self) -> bool {
        self.players.update(|count| *count = count.saturating_sub(1));
        self.players.get_untracked() == 0 && self.video_only.get_untracked() && !untracked(|| self.tray_enabled())
    }

    pub(crate) fn video_only(&self) -> bool {
        self.video_only.get_untracked()
    }

    pub(crate) fn set_video_only(&self, only: bool) {
        self.video_only.set(only);
    }

    pub(crate) fn close_video(&self) {
        self.open_video.set(None);
    }

    pub(crate) fn close_reader(&self) {
        self.open_job.set(None);
    }

    pub(crate) fn immersive(&self) -> bool {
        self.immersive.get()
    }

    pub(crate) fn subtitle_choice(&self) -> Option<(String, Vec<String>)> {
        self.subtitle_choices.with(|choices| choices.first().cloned())
    }

    pub(crate) fn subtitle_chosen(&self) {
        self.subtitle_choices.update(|choices| {
            if !choices.is_empty() {
                choices.remove(0);
            }
        });
    }

    pub(crate) fn focused(&self) -> bool {
        self.focused.get_untracked()
    }

    pub(crate) fn set_focused(&self, focused: bool) {
        self.focused.set(focused);
    }

    pub(crate) fn sidebar_hidden(&self) -> bool {
        self.sidebar_hidden.get()
    }

    pub(crate) fn drawer(&self) -> bool {
        self.drawer.get()
    }

    pub(crate) fn set_drawer(&self, out: bool) {
        self.drawer.set(out);
    }

    pub(crate) fn drawer_now(&self) -> bool {
        self.drawer.get_untracked()
    }

    pub(crate) fn toggle_sidebar(&self) {
        if untracked(crate::platform::compact) {
            self.drawer.set(!self.drawer.get_untracked());
            return;
        }
        let hidden = !self.sidebar_hidden.get_untracked();
        if self.open_job.get_untracked().is_none() {
            crate::ui::tokens::motion::reflow();
        }
        self.sidebar_hidden.set(hidden);
        self.update_settings(|s| {
            s.extra.insert("sidebar_hidden".into(), hidden.into());
        });
    }

    pub(crate) fn set_immersive(&self, on: bool) {
        self.immersive.set(on);
    }

    pub(crate) fn settings_open(&self) -> Signal<bool> {
        self.settings_open
    }

    pub(crate) fn update_check(&self) -> Signal<bool> {
        self.update_check
    }

    pub(crate) fn check_for_updates(&self) {
        self.update_check.set(true);
        self.settings_open.set(true);
    }

    pub(crate) fn settings(&self) -> Settings {
        self.settings.get()
    }

    pub(crate) fn setting<T>(&self, read: impl FnOnce(&Settings) -> T) -> T {
        self.settings.with(read)
    }

    pub(crate) fn update_settings(&self, change: impl FnOnce(&mut Settings)) {
        self.settings.update(change);
        if let Some(root) = self.data_root() {
            let settings = self.settings.get_untracked();
            if let Err(error) = persist::save_settings(&root, &settings) {
                log::error!("saving settings: {error}");
            }
        }
    }

    pub(crate) fn lang(&self) -> Lang {
        match self.settings.with(|s| s.locale_mode) {
            LocaleMode::English => Lang::En,
            LocaleMode::SimplifiedChinese => Lang::Zh,
            LocaleMode::System => Lang::of_locale(&locale().to_string()),
        }
    }

    pub(crate) fn appearance(&self) -> Appearance {
        match self.settings.with(|s| s.theme_mode) {
            ThemeMode::System => Appearance::System,
            ThemeMode::Light => Appearance::Light,
            ThemeMode::Dark => Appearance::Dark,
        }
    }

    pub(crate) fn language_hints(&self) -> Signal<String> {
        self.language_hints
    }

    pub(crate) fn context_terms(&self) -> Signal<String> {
        self.context_terms
    }

    pub(crate) fn jobs(&self) -> Vec<Rc<Job>> {
        self.jobs.get()
    }

    pub(crate) fn job(&self, id: &str) -> Option<Rc<Job>> {
        self.jobs.with(|jobs| jobs.iter().find(|job| job.id == id).cloned())
    }

    pub(crate) fn job_now(&self, id: &str) -> Option<Rc<Job>> {
        self.jobs.with_untracked(|jobs| jobs.iter().find(|job| job.id == id).cloned())
    }

    pub(crate) fn library(&self) -> Vec<Rc<Job>> {
        let filter = self.filter.get();
        self.jobs.with(|jobs| jobs.iter().filter(|job| filter.admits(job)).cloned().collect())
    }

    pub(crate) fn count(&self, filter: &Filter) -> usize {
        self.jobs.with(|jobs| jobs.iter().filter(|job| filter.admits(job)).count())
    }

    fn save(&self, job: &Job) {
        if let Some(root) = self.data_root()
            && let Err(error) = persist::save_job(&root, job)
        {
            log::error!("saving job {}: {error}", job.id);
        }
    }

    fn insert(&self, job: Job) {
        self.save(&job);
        self.jobs.update(|jobs| jobs.insert(0, Rc::new(job)));
    }

    pub(crate) fn update_job(&self, id: &str, change: impl FnOnce(&mut Job)) {
        self.change_job(id, true, change);
    }

    pub(crate) fn set_progress(&self, id: &str, stage: &str, fraction: Option<f64>) {
        self.change_job(id, false, |job| {
            job.progress = JobProgress { stage: stage.to_owned(), fraction, detail: None };
        });
    }

    fn change_job(&self, id: &str, persist: bool, change: impl FnOnce(&mut Job)) {
        let mut changed = None;
        let mut finished = None;
        self.jobs.update(|jobs| {
            if let Some(job) = jobs.iter_mut().find(|job| job.id == id) {
                let job = Rc::make_mut(job);
                let was = job.status;
                change(job);
                job.touch();
                if job.status != was {
                    finished = Some(was);
                }
                changed = Some(job.clone());
            }
        });
        if let (Some(job), Some(was)) = (&changed, finished) {
            crate::services::notify::job_changed(job, was);
        }
        if persist && let Some(job) = changed {
            self.save(&job);
        }
    }

    pub(crate) fn update_document(&self, id: &str, change: impl FnOnce(&mut Document)) {
        self.update_job(id, |job| {
            if let Some(document) = &mut job.document {
                change(document);
                document.touch();
            }
        });
    }

    pub(crate) fn new_job(&self, path: &str, origin: JobSourceOrigin) -> Job {
        let mut job = Job {
            id: uuid::Uuid::new_v4().to_string(),
            batch_id: "inbox".into(),
            source_path: path.to_owned(),
            status: JobStatus::Ready,
            source_origin: origin,
            ..Job::default()
        };
        job.progress.stage = "ready".into();
        self.apply_options(&mut job);
        job
    }

    pub(crate) fn apply_options(&self, job: &mut Job) {
        let settings = self.settings.get_untracked();
        let split = |text: String| -> Vec<String> {
            text.split([',', '\n']).map(|part| part.trim().to_owned()).filter(|part| !part.is_empty()).collect()
        };
        job.transcription_provider = settings.default_transcription_provider;
        job.options.language_hints = split(self.language_hints.get_untracked());
        job.options.context_terms = split(self.context_terms.get_untracked());
        job.options.soniox_translation = settings.soniox_translation.clone();
        job.translation_options.enabled = settings.translation_preferences.auto_translate;
        job.translation_options.target_language = Some(settings.translation_preferences.target_language.clone())
            .filter(|target| !target.is_empty())
            .unwrap_or_else(|| "en".into());
        job.translation_options.base_url = settings.llm_provider_settings.endpoint();
        job.translation_options.model = settings.llm_provider_settings.model.clone();
    }

    pub(crate) fn add_job(&self, job: Job) {
        self.insert(job);
    }

    pub(crate) fn add_files(&self, paths: &[String]) -> usize {
        let media: Vec<&String> = paths.iter().filter(|path| subtitles::is_media(path)).collect();
        let mut added = 0;
        for path in media {
            let known = self
                .jobs
                .with_untracked(|jobs| jobs.iter().any(|job| &job.source_path == path && !job.status.is_terminal()));
            if known {
                continue;
            }
            let mut job = self.new_job(path, JobSourceOrigin::Manual);
            let subtitle =
                paths.iter().find(|other| subtitles::is_subtitle(other) && subtitles::pairs_with(other, path)).cloned();
            let beside = if subtitle.is_none() { sibling_subtitles(path) } else { Vec::new() };
            let subtitle = subtitle.or_else(|| (beside.len() == 1).then(|| beside[0].clone()));
            if let Some(subtitle) = subtitle {
                match std::fs::read(&subtitle).map_err(|_| "subtitle_read_failed").and_then(|bytes| {
                    subtitles::import_subtitles(&subtitles::decode(&bytes), &subtitles::extension(&subtitle), None)
                }) {
                    Ok(imported) => {
                        job.document = Some(imported.document);
                        job.status = JobStatus::Completed;
                        job.progress = JobProgress { stage: "complete".into(), fraction: Some(1.0), detail: None };
                        job.transcript_acquisition_mode = TranscriptAcquisitionMode::ImportedSubtitles;
                    }
                    Err(code) => log::warn!("subtitle {subtitle}: {code}"),
                }
            }
            if beside.len() > 1 {
                self.subtitle_choices.update(|choices| choices.push((job.id.clone(), beside)));
            }
            self.insert(job);
            added += 1;
        }
        added
    }

    pub(crate) fn remove_job(&self, id: &str) {
        self.erase_job(id);
        self.note_removed(id, &listenook_core::models::now_iso());
    }

    fn note_removed(&self, id: &str, at: &str) {
        let Some(root) = self.data_root() else {
            return;
        };
        let mut removed = persist::load_removed(&root);
        if removed.get(id).is_some_and(|known| listenook_core::sync::removal_stands(known, at)) {
            return;
        }
        removed.insert(id.to_owned(), at.to_owned());
        if let Err(error) = persist::save_removed(&root, &removed) {
            log::error!("saving the removed recordings: {error}");
        }
    }

    pub(crate) fn adopt_removals(&self, theirs: &listenook_core::sync::Removed) {
        for (id, at) in theirs {
            match self.job_now(id) {
                Some(job) if job.is_busy() || !listenook_core::sync::removal_stands(at, &job.updated_at) => {}
                Some(_) => {
                    self.erase_job(id);
                    self.note_removed(id, at);
                }
                None => self.note_removed(id, at),
            }
        }
    }

    fn erase_job(&self, id: &str) {
        for key in [id.to_owned(), format!("{id}:translate"), format!("{id}:brief")] {
            self.cancel_work(&key);
        }
        if let (Some(root), Some(job)) = (self.data_root(), self.job_now(id))
            && std::path::Path::new(&job.source_path).starts_with(root.join("media"))
        {
            let _ = std::fs::remove_file(&job.source_path);
        }
        batch(|| {
            if self.open_job.get_untracked().as_deref() == Some(id) {
                self.open_job.set(None);
            }
            self.jobs.update(|jobs| jobs.retain(|job| job.id != id));
        });
        if let Some(root) = self.data_root() {
            let _ = persist::delete_job(&root, id);
            let _ = std::fs::remove_dir_all(root.join("podcasts").join(id));
        }
        crate::services::playable::forget(id);
    }

    pub(crate) fn saved_rate(&self, key: &str) -> f32 {
        self.settings
            .with_untracked(|s| s.extra.get(key).and_then(serde_json::Value::as_f64))
            .map_or(1.0, |rate| (rate as f32).clamp(0.5, 2.0))
    }

    pub(crate) fn save_rate(&self, key: &'static str, rate: f32) {
        self.update_settings(|s| drop(s.extra.insert(key.into(), f64::from(rate).into())));
    }

    pub(crate) fn catalog(&self) -> LibraryCatalog {
        self.catalog.get()
    }

    fn change_catalog(&self, change: impl FnOnce(&mut LibraryCatalog)) {
        self.catalog.update(change);
        if let Some(root) = self.data_root()
            && let Err(error) = persist::save_library_catalog(&root, &self.catalog.get_untracked())
        {
            log::error!("saving the library catalog: {error}");
        }
    }

    pub(crate) fn add_group(&self, name: &str) -> Option<String> {
        let name = name.trim();
        if name.is_empty() {
            return None;
        }
        if let Some(existing) =
            self.catalog.with_untracked(|c| c.groups.iter().find(|g| g.name == name).map(|g| g.id.clone()))
        {
            return Some(existing);
        }
        let id = uuid::Uuid::new_v4().to_string();
        self.change_catalog(|catalog| catalog.groups.push(Named { id: id.clone(), name: name.to_owned() }));
        Some(id)
    }

    pub(crate) fn rename_group(&self, id: &str, name: &str) {
        let name = name.trim().to_owned();
        if !name.is_empty() {
            self.change_catalog(|catalog| {
                if let Some(group) = catalog.groups.iter_mut().find(|g| g.id == id) {
                    group.name = name;
                }
            });
        }
    }

    pub(crate) fn delete_group(&self, id: &str) {
        let members: Vec<String> = self.jobs.with_untracked(|jobs| {
            jobs.iter().filter(|job| job.group_id.as_deref() == Some(id)).map(|job| job.id.clone()).collect()
        });
        for job in members {
            self.update_job(&job, |job| job.group_id = None);
        }
        self.change_catalog(|catalog| catalog.groups.retain(|g| g.id != id));
        if self.filter.get_untracked() == Filter::Group(id.to_owned()) {
            self.filter.set(Filter::All);
        }
    }

    pub(crate) fn set_group(&self, job_id: &str, group_id: Option<String>) {
        self.update_job(job_id, |job| job.group_id = group_id);
    }

    pub(crate) fn add_tag(&self, name: &str) -> Option<String> {
        let name = name.trim();
        if name.is_empty() {
            return None;
        }
        if let Some(existing) =
            self.catalog.with_untracked(|c| c.tags.iter().find(|t| t.name == name).map(|t| t.id.clone()))
        {
            return Some(existing);
        }
        let id = uuid::Uuid::new_v4().to_string();
        self.change_catalog(|catalog| catalog.tags.push(Named { id: id.clone(), name: name.to_owned() }));
        Some(id)
    }

    pub(crate) fn rename_tag(&self, id: &str, name: &str) {
        let name = name.trim().to_owned();
        if name.is_empty() {
            return;
        }
        self.change_catalog(|catalog| {
            if let Some(tag) = catalog.tags.iter_mut().find(|t| t.id == id) {
                tag.name = name;
            }
        });
    }

    pub(crate) fn delete_tag(&self, id: &str) {
        let tagged: Vec<String> = self.jobs.with_untracked(|jobs| {
            jobs.iter().filter(|job| job.tag_ids.iter().any(|tag| tag == id)).map(|job| job.id.clone()).collect()
        });
        for job in tagged {
            self.update_job(&job, |job| job.tag_ids.retain(|tag| tag != id));
        }
        self.change_catalog(|catalog| catalog.tags.retain(|t| t.id != id));
        if self.filter.get_untracked() == Filter::Tag(id.to_owned()) {
            self.filter.set(Filter::All);
        }
    }

    pub(crate) fn toggle_tag(&self, job_id: &str, name: &str) {
        let Some(tag) = self.add_tag(name) else {
            return;
        };
        self.update_job(job_id, |job| {
            if job.tag_ids.contains(&tag) {
                job.tag_ids.retain(|other| other != &tag);
            } else {
                job.tag_ids.push(tag.clone());
                job.tag_ids.sort();
            }
        });
    }

    pub(crate) fn monitor(&self) -> MonitorConfig {
        self.monitor.with(|file| file.config.clone())
    }

    fn change_monitor(&self, change: impl FnOnce(&mut MonitorFile)) {
        self.monitor.update(change);
        if let Some(root) = self.data_root()
            && let Err(error) = persist::save_monitor(&root, &self.monitor.get_untracked())
        {
            log::error!("saving the folder monitor: {error}");
        }
    }

    pub(crate) fn tray_enabled(&self) -> bool {
        self.monitor.with(|file| {
            file.config.extra.get("show_tray_icon").and_then(|v| v.as_bool()).unwrap_or(cfg!(target_os = "macos"))
        })
    }

    pub(crate) fn set_tray_enabled(&self, enabled: bool) {
        if !enabled && !untracked(|| self.dock_visible()) {
            return;
        }
        self.change_monitor(|file| {
            file.config.extra.insert("show_tray_icon".into(), enabled.into());
        });
    }

    pub(crate) fn dock_visible(&self) -> bool {
        !cfg!(target_os = "macos")
            || !self.tray_enabled()
            || self
                .monitor
                .with(|file| file.config.extra.get("show_dock_icon").and_then(|v| v.as_bool()).unwrap_or(true))
    }

    pub(crate) fn set_dock_visible(&self, visible: bool) {
        if !visible && !untracked(|| self.tray_enabled()) {
            return;
        }
        self.change_monitor(|file| {
            file.config.extra.insert("show_dock_icon".into(), visible.into());
        });
    }

    pub(crate) fn opens_at_login(&self) -> bool {
        self.monitor.with(|file| file.config.extra.get("launch_at_login").and_then(|v| v.as_bool()).unwrap_or(false))
    }

    pub(crate) fn set_opens_at_login(&self, enabled: bool) {
        if crate::services::login::set(enabled) {
            self.change_monitor(|file| {
                file.config.extra.insert("launch_at_login".into(), enabled.into());
            });
        }
    }

    pub(crate) fn watch_folder(&self, folder: &str) {
        self.last_scan.replace(BTreeMap::new());
        self.change_monitor(|file| {
            file.config.folder_path = folder.to_owned();
            file.config.paused = false;
        });
    }

    pub(crate) fn set_monitor_paused(&self, paused: bool) {
        self.change_monitor(|file| file.config.paused = paused);
    }

    pub(crate) fn scan_watched_folder(&self) {
        let config = self.monitor();
        if config.folder_path.is_empty() || config.paused {
            return;
        }
        let store = *self;
        self.run(async move {
            let folder = PathBuf::from(config.folder_path);
            let Ok(Some(now)) = blocking(move || monitor::scan(&folder)).await else {
                return;
            };
            let last = store.last_scan.replace(now.clone());
            let taken = store.monitor.with_untracked(|file| monitor::settled(&last, &now, file));
            if taken.is_empty() {
                return;
            }
            store.change_monitor(|file| {
                for path in &taken {
                    if let Some(state) = now.get(path) {
                        file.record(path, state, None);
                    }
                }
            });
            let added = store.add_files(&taken);
            if added > 0 {
                crate::ui::toast(
                    crate::ui::Tone::Info,
                    format!(
                        "{added} {}",
                        listenook_core::l10n::tr(store.lang(), "new recordings from the watched folder.")
                    ),
                );
            }
        });
    }

    pub(crate) fn sync_visible(&self) -> bool {
        self.settings.with(|s| s.extra.get("sync_visible").and_then(|v| v.as_bool()).unwrap_or(false))
    }

    pub(crate) fn sync_decided(&self) -> bool {
        self.settings.with_untracked(|s| s.extra.contains_key("sync_visible"))
    }

    pub(crate) fn set_sync_visible(&self, visible: bool) {
        self.update_settings(|s| drop(s.extra.insert("sync_visible".into(), visible.into())));
        self.configure_sync();
    }

    pub(crate) fn device_name(&self) -> String {
        self.settings
            .with(|s| s.extra.get("sync_device_name").and_then(|v| v.as_str()).map(str::to_owned))
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| DEFAULT_DEVICE_NAME.with(|name| name.clone()))
    }

    pub(crate) fn set_device_name(&self, name: &str) {
        let name: String = name.chars().take(64).collect();
        self.update_settings(|s| drop(s.extra.insert("sync_device_name".into(), name.into())));
        self.configure_sync();
    }

    fn configure_sync(&self) {
        let visible = untracked(|| self.sync_visible());
        let known =
            self.settings.with_untracked(|s| s.extra.get("sync_device_id").and_then(|v| v.as_str()).map(str::to_owned));
        let id = match known {
            Some(id) => id,
            None if visible => {
                let id = uuid::Uuid::new_v4().to_string();
                self.update_settings(|s| drop(s.extra.insert("sync_device_id".into(), id.clone().into())));
                id
            }
            None => String::new(),
        };
        crate::services::sync::configure(self.data_root(), id, untracked(|| self.device_name()), visible);
    }

    pub(crate) fn busy_ids(&self) -> std::collections::HashSet<String> {
        self.jobs.with_untracked(|jobs| {
            jobs.iter()
                .filter(|job| job.is_busy() || job.status == JobStatus::Pending)
                .map(|job| job.id.clone())
                .collect()
        })
    }

    pub(crate) fn adopt_catalog(&self, theirs: &LibraryCatalog) -> HashMap<String, String> {
        let mut merged = self.catalog.get_untracked();
        let map = listenook_core::sync::merge_catalog(&mut merged, theirs);
        if merged != self.catalog.get_untracked() {
            self.change_catalog(|catalog| *catalog = merged);
        }
        map
    }

    pub(crate) fn adopt_job(&self, job: Job, map: &HashMap<String, String>) {
        let Some(root) = self.data_root() else {
            return;
        };
        let existing = self.job_now(&job.id);
        if existing.as_ref().is_some_and(|existing| existing.is_busy()) {
            return;
        }
        let mut job = recovered(job);
        listenook_core::sync::rehome(&mut job, map);
        let name = job.file_name();
        let brought = root.join("media").join(listenook_core::sync::media_file_name(&job.id, &job.file_name()));
        let mut removed = persist::load_removed(&root);
        if let Some(at) = removed.get(&job.id) {
            if listenook_core::sync::removal_stands(at, &job.updated_at) {
                let _ = std::fs::remove_file(&brought);
                return;
            }
            removed.remove(&job.id);
            if let Err(error) = persist::save_removed(&root, &removed) {
                log::error!("saving the removed recordings: {error}");
            }
        }
        let kept = existing.as_ref().map(|existing| existing.source_path.clone()).filter(|path| is_file(path));
        if let Some(path) = kept {
            job.source_path = path;
        } else if brought.is_file() {
            job.source_path = brought.to_string_lossy().into_owned();
        }
        listenook_core::sync::keep_title(&mut job, &name);
        found_again(&mut job);
        self.save(&job);
        let id = job.id.clone();
        self.jobs.update(|jobs| match jobs.iter_mut().find(|other| other.id == id) {
            Some(place) => *place = Rc::new(job),
            None => {
                jobs.push(Rc::new(job));
                jobs.sort_by(|a, b| b.created_at.cmp(&a.created_at));
            }
        });
        if existing.is_some() {
            crate::services::playable::forget(&id);
        }
    }

    pub(crate) fn adopt_media(&self, id: &str, path: &std::path::Path) {
        let mut changed = None;
        self.jobs.update(|jobs| {
            if let Some(job) = jobs.iter_mut().find(|job| job.id == id).filter(|job| !is_file(&job.source_path)) {
                let job = Rc::make_mut(job);
                let name = job.file_name();
                job.source_path = path.to_string_lossy().into_owned();
                listenook_core::sync::keep_title(job, &name);
                found_again(job);
                changed = Some(job.clone());
            }
        });
        if let Some(job) = changed {
            self.save(&job);
            crate::services::playable::forget(id);
        }
    }

    pub(crate) fn adopt_name(&self, id: &str, name: &str) {
        let mut changed = None;
        self.jobs.update(|jobs| {
            if let Some(job) = jobs.iter_mut().find(|job| job.id == id) {
                let mut named = (**job).clone();
                if listenook_core::sync::keep_title(&mut named, name) {
                    *job = Rc::new(named.clone());
                    changed = Some(named);
                }
            }
        });
        if let Some(job) = changed {
            self.save(&job);
        }
    }

    pub(crate) fn run_for(&self, id: &str, work: impl Future<Output = ()> + 'static) {
        self.cancel_work(id);
        let (store, key) = (*self, id.to_owned());
        let task = self.owner.run(|| {
            spawn(async move {
                work.await;
                store.running.with(|running| running.remove(&key));
            })
        });
        self.running.with(|running| running.insert(id.to_owned(), task));
    }

    pub(crate) fn run(&self, work: impl Future<Output = ()> + 'static) {
        drop(self.owner.run(|| spawn(work)));
    }

    pub(crate) fn cancel_work(&self, id: &str) -> bool {
        match self.running.with(|running| running.remove(id)) {
            Some(task) => {
                task.cancel();
                true
            }
            None => false,
        }
    }
}

thread_local! {
    static DEFAULT_DEVICE_NAME: String = crate::services::sync::default_name();
}

fn is_file(path: &str) -> bool {
    !path.is_empty() && std::path::Path::new(path).is_file()
}

fn found_again(job: &mut Job) {
    if !is_file(&job.source_path) {
        return;
    }
    if job.status == JobStatus::MissingSource {
        job.status = if job.has_transcript() { JobStatus::Completed } else { JobStatus::Ready };
        job.progress = JobProgress { stage: "ready".into(), fraction: None, detail: None };
    }
    if job.error_code.as_deref() == Some("missing_source") {
        job.error_code = None;
        job.error_message = None;
    }
}

fn sibling_subtitles(media: &str) -> Vec<String> {
    let Some(directory) = std::path::Path::new(media).parent() else {
        return Vec::new();
    };
    let mut found: Vec<String> = std::fs::read_dir(directory)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| entry.path().to_str().map(str::to_owned))
        .filter(|path| subtitles::is_subtitle(path) && subtitles::pairs_with(path, media))
        .collect();
    found.sort();
    found
}
