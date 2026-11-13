//! The app's state: jobs, settings and where the user is. Its signals stay
//! private; pages read through these methods (tracked where they are read)
//! and change state only through them, and every change that should outlive
//! the run is written to disk here.

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

/// A top-level place in the app. A recording that is open covers either.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub(crate) enum Place {
    #[default]
    Library,
    Podcasts,
}

/// Which recordings the Library lists.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) enum Filter {
    /// Every recording.
    #[default]
    All,
    /// Not transcribed yet, being worked on, or failed.
    InProgress,
    /// The recordings of one group, by its id.
    Group(String),
    /// The recordings with one tag, by its id.
    Tag(String),
}

impl Filter {
    /// Whether a job belongs under the filter.
    pub(crate) fn admits(&self, job: &Job) -> bool {
        match self {
            Filter::All => true,
            Filter::InProgress => !job.has_transcript() || job.is_busy(),
            Filter::Group(id) => job.group_id.as_deref() == Some(id.as_str()),
            Filter::Tag(id) => job.tag_ids.iter().any(|tag| tag == id),
        }
    }
}

/// The app's store. `Copy`: closures capture it as they do a signal.
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
    /// The video open in the player, over everything else.
    open_video: Signal<Option<String>>,
    /// How many videos play in windows of their own, and whether the app
    /// was opened only to play one (its main window never shown).
    players: Signal<usize>,
    video_only: Signal<bool>,
    settings_open: Signal<bool>,
    update_check: Signal<bool>,
    immersive: Signal<bool>,
    sidebar_hidden: Signal<bool>,
    /// Whether the app's window has the keyboard: what finishes while it
    /// has not is worth a notification.
    focused: Signal<bool>,
    /// In a narrow window the sidebar is a drawer over the page: whether it is out.
    drawer: Signal<bool>,
    /// Recordings added with several subtitle files beside them: which
    /// one is the transcript is the user's choice.
    subtitle_choices: Signal<Vec<(String, Vec<String>)>>,
    language_hints: Signal<String>,
    context_terms: Signal<String>,
    running: Stored<HashMap<String, Spawned<()>>>,
    /// Podcasts: the catalog and what is playing.
    pub(crate) podcast: PodcastState,
    /// Syncing with another device on the local network.
    pub(crate) sync: SyncState,
}

#[derive(Clone, Default)]
struct Handle(Option<Store>);

/// The store, from anywhere on the engine thread: a body, a listener or a
/// task. Reading it subscribes to nothing; its methods do.
pub(crate) fn store() -> Store {
    global::<Handle>().get_untracked().0.expect("the root component makes the store")
}

/// Brings a job read from disk to a state this run can continue from: work
/// that was running when the app quit did not survive it.
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

/// A job whose media is where the app's folder is now (see
/// [`persist::rehomed`]), no longer marked as missing it.
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
    /// Loads the store from disk and makes it the app's. Call once, in the
    /// root component's body: tasks the store starts belong to that owner.
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
        // For development: `LISTENOOK_START=reader` opens the newest
        // transcript, `podcasts` and `settings` those places, `import` takes in
        // what is in the app's folder, `sync` opens the Sync dialog.
        match std::env::var("LISTENOOK_START").as_deref() {
            Ok("reader") => {
                let newest = store
                    .jobs
                    .with_untracked(|jobs| jobs.iter().find(|job| job.has_transcript()).map(|job| job.id.clone()));
                store.open_job.set(newest);
            }
            Ok("podcasts") => store.place.set(Place::Podcasts),
            // Takes in the media put in the app's folder (the simulator
            // has no hand to pick it in the Files browser).
            Ok("import") => {
                spawn(async {
                    timer(std::time::Duration::from_millis(500)).await;
                    crate::util::import_shared();
                });
            }
            Ok("settings") => store.settings_open.set(true),
            // `sync` opens the Sync dialog; `sync:<address>` also starts a
            // sync with the device there.
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
        // What the player made playable is for one sitting: a run that
        // ended without closing it leaves its file behind.
        if let Some(temporary) = store.data_root().map(|root| root.join("temporary")) {
            for entry in std::fs::read_dir(temporary).into_iter().flatten().flatten() {
                if entry.file_name().to_string_lossy().starts_with("player-") {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
        global::<Handle>().set(Handle(Some(store)));
        store.configure_sync();
        // The port is given back when the app's surface goes.
        let root = store.data_root();
        cleanup(move || crate::services::sync::release(&root));
        store
    }

    /// Where the app's files are; none when nothing is written to disk.
    pub(crate) fn data_root(&self) -> Option<PathBuf> {
        self.root.with(|root| root.clone())
    }

    // --- Where the user is ---------------------------------------------------

    /// The place showing under any open recording.
    pub(crate) fn place(&self) -> Place {
        self.place.get()
    }

    /// Goes to a place, closing the open recording.
    pub(crate) fn go(&self, place: Place) {
        batch(|| {
            self.open_job.set(None);
            self.open_video.set(None);
            self.place.set(place);
        });
    }

    /// The Library's filter.
    pub(crate) fn filter(&self) -> Filter {
        self.filter.get()
    }

    /// Shows the Library under a filter.
    pub(crate) fn show(&self, filter: Filter) {
        batch(|| {
            self.open_job.set(None);
            self.open_video.set(None);
            self.place.set(Place::Library);
            self.filter.set(filter);
        });
    }

    /// The recording open in the reader.
    pub(crate) fn open_job_id(&self) -> Option<String> {
        self.open_job.get()
    }

    /// Opens a recording's transcript in the reader.
    pub(crate) fn open_transcript(&self, id: &str) {
        batch(|| {
            self.open_video.set(None);
            self.open_job.set(Some(id.to_owned()));
        });
    }

    /// Closes the reader: back to where it was opened from.
    /// The video open in the player, if any.
    pub(crate) fn open_video_path(&self) -> Option<String> {
        self.open_video.get()
    }

    /// Opens a video in the player, without adding it to the Library.
    pub(crate) fn open_video(&self, path: &str) {
        // On a computer the video plays in a window of its own; on a
        // phone, where there is one window, in place of the page.
        if crate::platform::is_phone() || !crate::pages::open_player(path) {
            self.open_video.set(Some(path.to_owned()));
        }
    }

    /// Whether a video is playing, in the page or in a window of its own.
    pub(crate) fn video_playing(&self) -> bool {
        self.open_video.with(Option::is_some) || self.players.get() > 0
    }

    /// A player window opened.
    pub(crate) fn player_opened(&self) {
        self.players.update(|count| *count += 1);
    }

    /// A player window closed. Returns whether the app should end with
    /// it: it was opened only to play a video, nothing else of it shows,
    /// and there is no tray icon to find it by.
    pub(crate) fn player_closed(&self) -> bool {
        self.players.update(|count| *count = count.saturating_sub(1));
        self.players.get_untracked() == 0 && self.video_only.get_untracked() && !untracked(|| self.tray_enabled())
    }

    /// Whether the app is showing only a video.
    pub(crate) fn video_only(&self) -> bool {
        self.video_only.get_untracked()
    }

    /// Whether only a video shows: the main window stays away.
    pub(crate) fn set_video_only(&self, only: bool) {
        self.video_only.set(only);
    }

    /// Closes the player.
    pub(crate) fn close_video(&self) {
        self.open_video.set(None);
    }

    pub(crate) fn close_reader(&self) {
        self.open_job.set(None);
    }

    /// Whether the open recording has the whole window (full-screen video).
    pub(crate) fn immersive(&self) -> bool {
        self.immersive.get()
    }

    /// Gives the open recording the whole window, or the sidebar back.
    /// The first recording waiting for its subtitle file to be chosen.
    pub(crate) fn subtitle_choice(&self) -> Option<(String, Vec<String>)> {
        self.subtitle_choices.with(|choices| choices.first().cloned())
    }

    /// That recording's choice is made (or declined).
    pub(crate) fn subtitle_chosen(&self) {
        self.subtitle_choices.update(|choices| {
            if !choices.is_empty() {
                choices.remove(0);
            }
        });
    }

    /// Whether the app's window has the keyboard.
    pub(crate) fn focused(&self) -> bool {
        self.focused.get_untracked()
    }

    /// The window gained or lost the keyboard.
    pub(crate) fn set_focused(&self, focused: bool) {
        self.focused.set(focused);
    }

    /// Whether the user has put the sidebar away.
    pub(crate) fn sidebar_hidden(&self) -> bool {
        self.sidebar_hidden.get()
    }

    /// Whether the sidebar's drawer is out (a narrow window).
    pub(crate) fn drawer(&self) -> bool {
        self.drawer.get()
    }

    /// Pulls the drawer out or pushes it back.
    pub(crate) fn set_drawer(&self, out: bool) {
        self.drawer.set(out);
    }

    /// Shows the sidebar, or puts it away. In a wide window that is
    /// remembered for the next launch; in a narrow one it is the drawer.
    /// Whether the sidebar is out over the page, read without following it.
    pub(crate) fn drawer_now(&self) -> bool {
        self.drawer.get_untracked()
    }

    pub(crate) fn toggle_sidebar(&self) {
        if untracked(crate::platform::compact) {
            self.drawer.set(!self.drawer.get_untracked());
            return;
        }
        let hidden = !self.sidebar_hidden.get_untracked();
        // Not over an open transcript: its lines wrap anew at the new
        // width, and rows animated to it keep wrong heights.
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

    /// Whether the Settings dialog is open, as the signal a dialog follows.
    pub(crate) fn settings_open(&self) -> Signal<bool> {
        self.settings_open
    }

    /// Whether a check for updates was asked for from a menu: Settings'
    /// About page takes it and checks.
    pub(crate) fn update_check(&self) -> Signal<bool> {
        self.update_check
    }

    /// Opens Settings at About and checks for updates there.
    pub(crate) fn check_for_updates(&self) {
        self.update_check.set(true);
        self.settings_open.set(true);
    }

    // --- Settings ------------------------------------------------------------

    /// The settings.
    pub(crate) fn settings(&self) -> Settings {
        self.settings.get()
    }

    /// One value of the settings, tracked without cloning them all.
    pub(crate) fn setting<T>(&self, read: impl FnOnce(&Settings) -> T) -> T {
        self.settings.with(read)
    }

    /// Changes the settings and saves them.
    pub(crate) fn update_settings(&self, change: impl FnOnce(&mut Settings)) {
        self.settings.update(change);
        if let Some(root) = self.data_root() {
            let settings = self.settings.get_untracked();
            if let Err(error) = persist::save_settings(&root, &settings) {
                log::error!("saving settings: {error}");
            }
        }
    }

    /// The interface language: the chosen one, else the system's.
    pub(crate) fn lang(&self) -> Lang {
        match self.settings.with(|s| s.locale_mode) {
            LocaleMode::English => Lang::En,
            LocaleMode::SimplifiedChinese => Lang::Zh,
            LocaleMode::System => Lang::of_locale(&locale().to_string()),
        }
    }

    /// The appearance the settings ask for.
    pub(crate) fn appearance(&self) -> Appearance {
        match self.settings.with(|s| s.theme_mode) {
            ThemeMode::System => Appearance::System,
            ThemeMode::Light => Appearance::Light,
            ThemeMode::Dark => Appearance::Dark,
        }
    }

    /// The language hints of the next batch, as the user typed them.
    pub(crate) fn language_hints(&self) -> Signal<String> {
        self.language_hints
    }

    /// The context terms of the next batch, as the user typed them.
    pub(crate) fn context_terms(&self) -> Signal<String> {
        self.context_terms
    }

    // --- Jobs ----------------------------------------------------------------

    /// Every job, newest first.
    pub(crate) fn jobs(&self) -> Vec<Rc<Job>> {
        self.jobs.get()
    }

    /// One job, or none once it is removed.
    pub(crate) fn job(&self, id: &str) -> Option<Rc<Job>> {
        self.jobs.with(|jobs| jobs.iter().find(|job| job.id == id).cloned())
    }

    /// One job as it is now, without subscribing: for listeners and tasks.
    pub(crate) fn job_now(&self, id: &str) -> Option<Rc<Job>> {
        self.jobs.with_untracked(|jobs| jobs.iter().find(|job| job.id == id).cloned())
    }

    /// The recordings the Library lists now, newest first.
    pub(crate) fn library(&self) -> Vec<Rc<Job>> {
        let filter = self.filter.get();
        self.jobs.with(|jobs| jobs.iter().filter(|job| filter.admits(job)).cloned().collect())
    }

    /// How many recordings a filter admits.
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

    /// Changes a job and saves it. Nothing happens once the job is removed.
    pub(crate) fn update_job(&self, id: &str, change: impl FnOnce(&mut Job)) {
        self.change_job(id, true, change);
    }

    /// Changes a job's progress without writing it to disk: progress is
    /// reported many times a second and does not outlive the run.
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

    /// Changes a job's transcript and marks it edited now.
    pub(crate) fn update_document(&self, id: &str, change: impl FnOnce(&mut Document)) {
        self.update_job(id, |job| {
            if let Some(document) = &mut job.document {
                change(document);
                document.touch();
            }
        });
    }

    /// A job for a file, not yet in the store.
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

    /// Gives a job the way recordings are transcribed now: the options
    /// may have changed since it was added, and it is transcribed as the
    /// user last set them.
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

    /// Adds a job to the store and saves it.
    pub(crate) fn add_job(&self, job: Job) {
        self.insert(job);
    }

    /// Adds media files to the Library. A subtitle file beside a media file,
    /// with its name, becomes that file's transcript at once; a file that
    /// already waits there is not added twice. Returns how many were added.
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

    /// Removes a job, its files in the app's folder, and stops its work.
    pub(crate) fn remove_job(&self, id: &str) {
        for key in [id.to_owned(), format!("{id}:translate"), format!("{id}:brief")] {
            self.cancel_work(&key);
        }
        // Media imported on a phone is the app's own copy: it goes too.
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

    /// The playback speed last chosen, kept apart for recordings
    /// (`"playback_rate"`) and podcasts (`"podcast_rate"`).
    pub(crate) fn saved_rate(&self, key: &str) -> f32 {
        self.settings
            .with_untracked(|s| s.extra.get(key).and_then(serde_json::Value::as_f64))
            .map_or(1.0, |rate| (rate as f32).clamp(0.5, 2.0))
    }

    /// Keeps a playback speed for next time.
    pub(crate) fn save_rate(&self, key: &'static str, rate: f32) {
        self.update_settings(|s| drop(s.extra.insert(key.into(), f64::from(rate).into())));
    }

    // --- Groups and tags -----------------------------------------------------

    /// The library's groups and tags.
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

    /// Adds a group; the id of the one with that name when it exists.
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

    /// Renames a group.
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

    /// Deletes a group; its recordings stay, unfiled.
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

    /// Files a recording in a group, or in none.
    pub(crate) fn set_group(&self, job_id: &str, group_id: Option<String>) {
        self.update_job(job_id, |job| job.group_id = group_id);
    }

    /// Adds a tag; the id of the one with that name when it exists.
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

    /// Renames a tag.
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

    /// Deletes a tag, taking it off the recordings that carry it.
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

    /// Puts a tag on a recording or takes it off, making the tag when new.
    /// A tag stays in the library until it is deleted.
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

    // --- The watched folder --------------------------------------------------

    /// The watched folder's configuration.
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

    /// Whether the app stays in the menu bar (the tray) when its window is
    /// closed, kept where the Flutter app kept it. On by default on a Mac,
    /// where closing a window does not quit an app; off elsewhere, where
    /// the close button is expected to quit it.
    pub(crate) fn tray_enabled(&self) -> bool {
        self.monitor.with(|file| {
            file.config.extra.get("show_tray_icon").and_then(|v| v.as_bool()).unwrap_or(cfg!(target_os = "macos"))
        })
    }

    /// Keeps the app in the menu bar, or not. Not while the Dock icon is
    /// hidden: with neither, a closed window could not be opened again.
    pub(crate) fn set_tray_enabled(&self, enabled: bool) {
        if !enabled && !untracked(|| self.dock_visible()) {
            return;
        }
        self.change_monitor(|file| {
            file.config.extra.insert("show_tray_icon".into(), enabled.into());
        });
    }

    /// Whether the app shows in the Dock (kept where the Flutter app kept
    /// it): always while there is no menu-bar icon to reach it by.
    pub(crate) fn dock_visible(&self) -> bool {
        !cfg!(target_os = "macos")
            || !self.tray_enabled()
            || self
                .monitor
                .with(|file| file.config.extra.get("show_dock_icon").and_then(|v| v.as_bool()).unwrap_or(true))
    }

    /// Shows the app in the Dock, or not; hiding needs the menu-bar icon.
    pub(crate) fn set_dock_visible(&self, visible: bool) {
        if !visible && !untracked(|| self.tray_enabled()) {
            return;
        }
        self.change_monitor(|file| {
            file.config.extra.insert("show_dock_icon".into(), visible.into());
        });
    }

    /// Whether the app is opened at login (kept where the Flutter app kept it).
    pub(crate) fn opens_at_login(&self) -> bool {
        self.monitor.with(|file| file.config.extra.get("launch_at_login").and_then(|v| v.as_bool()).unwrap_or(false))
    }

    /// Opens the app at login, or stops.
    pub(crate) fn set_opens_at_login(&self, enabled: bool) {
        if crate::services::login::set(enabled) {
            self.change_monitor(|file| {
                file.config.extra.insert("launch_at_login".into(), enabled.into());
            });
        }
    }

    /// Watches a folder, or none (an empty path).
    pub(crate) fn watch_folder(&self, folder: &str) {
        self.last_scan.replace(BTreeMap::new());
        self.change_monitor(|file| {
            file.config.folder_path = folder.to_owned();
            file.config.paused = false;
        });
    }

    /// Pauses or resumes watching.
    pub(crate) fn set_monitor_paused(&self, paused: bool) {
        self.change_monitor(|file| file.config.paused = paused);
    }

    /// Looks at the watched folder once and adds the media that has settled
    /// since the last look. Called on a timer by the shell.
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

    // --- Syncing with another device -----------------------------------------

    /// Whether other devices on the local network can find this one. Not
    /// before the user has opened Sync once: until then the app neither
    /// listens nor announces itself.
    pub(crate) fn sync_visible(&self) -> bool {
        self.settings.with(|s| s.extra.get("sync_visible").and_then(|v| v.as_bool()).unwrap_or(false))
    }

    /// Whether the user has ever decided about being visible.
    pub(crate) fn sync_decided(&self) -> bool {
        self.settings.with_untracked(|s| s.extra.contains_key("sync_visible"))
    }

    /// Lets other devices find this one, or not.
    pub(crate) fn set_sync_visible(&self, visible: bool) {
        self.update_settings(|s| drop(s.extra.insert("sync_visible".into(), visible.into())));
        self.configure_sync();
    }

    /// The name other devices see for this one.
    pub(crate) fn device_name(&self) -> String {
        self.settings
            .with(|s| s.extra.get("sync_device_name").and_then(|v| v.as_str()).map(str::to_owned))
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| DEFAULT_DEVICE_NAME.with(|name| name.clone()))
    }

    /// Names this device for the others.
    pub(crate) fn set_device_name(&self, name: &str) {
        let name: String = name.chars().take(64).collect();
        self.update_settings(|s| drop(s.extra.insert("sync_device_name".into(), name.into())));
        self.configure_sync();
    }

    /// Tells the sync service whose Library this is, as the settings have it.
    fn configure_sync(&self) {
        let visible = untracked(|| self.sync_visible());
        let known =
            self.settings.with_untracked(|s| s.extra.get("sync_device_id").and_then(|v| v.as_str()).map(str::to_owned));
        let id = match known {
            Some(id) => id,
            // Made the first time the device is to be seen.
            None if visible => {
                let id = uuid::Uuid::new_v4().to_string();
                self.update_settings(|s| drop(s.extra.insert("sync_device_id".into(), id.clone().into())));
                id
            }
            None => String::new(),
        };
        crate::services::sync::configure(self.data_root(), id, untracked(|| self.device_name()), visible);
    }

    /// The recordings being worked on now: a sync leaves them alone.
    pub(crate) fn busy_ids(&self) -> std::collections::HashSet<String> {
        self.jobs.with_untracked(|jobs| {
            jobs.iter()
                .filter(|job| job.is_busy() || job.status == JobStatus::Pending)
                .map(|job| job.id.clone())
                .collect()
        })
    }

    /// Takes in another device's groups and tags. Returns where its ids
    /// lead here, for the recordings that follow (`adopt_job`).
    pub(crate) fn adopt_catalog(&self, theirs: &LibraryCatalog) -> HashMap<String, String> {
        let mut merged = self.catalog.get_untracked();
        let map = listenook_core::sync::merge_catalog(&mut merged, theirs);
        if merged != self.catalog.get_untracked() {
            self.change_catalog(|catalog| *catalog = merged);
        }
        map
    }

    /// Takes in a recording as another device has it: new here, or newer
    /// than the one here. Its time of change stays the other device's, so
    /// the two are equal afterwards. The media stays this device's own
    /// file when it has one, else the file the sync brought.
    pub(crate) fn adopt_job(&self, job: Job, map: &HashMap<String, String>) {
        let Some(root) = self.data_root() else {
            return;
        };
        let existing = self.job_now(&job.id);
        // Work begun on it since the sync was planned wins.
        if existing.as_ref().is_some_and(|existing| existing.is_busy()) {
            return;
        }
        let mut job = recovered(job);
        listenook_core::sync::rehome(&mut job, map);
        let brought = root.join("media").join(listenook_core::sync::media_file_name(&job.id, &job.file_name()));
        let kept = existing.as_ref().map(|existing| existing.source_path.clone()).filter(|path| is_file(path));
        if let Some(path) = kept {
            job.source_path = path;
        } else if brought.is_file() {
            job.source_path = brought.to_string_lossy().into_owned();
        }
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

    /// Points a recording that was here without its media at the file a
    /// sync brought.
    pub(crate) fn adopt_media(&self, id: &str, path: &std::path::Path) {
        let mut changed = None;
        self.jobs.update(|jobs| {
            if let Some(job) = jobs.iter_mut().find(|job| job.id == id).filter(|job| !is_file(&job.source_path)) {
                let job = Rc::make_mut(job);
                job.source_path = path.to_string_lossy().into_owned();
                found_again(job);
                changed = Some(job.clone());
            }
        });
        if let Some(job) = changed {
            self.save(&job);
            crate::services::playable::forget(id);
        }
    }

    // --- Background work -----------------------------------------------------

    /// Runs `work` for a job until it ends, whatever page the user is on.
    /// Work already running for that job is stopped first.
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

    /// Runs work that belongs to no job (a search, a feed) for the app's life.
    pub(crate) fn run(&self, work: impl Future<Output = ()> + 'static) {
        drop(self.owner.run(|| spawn(work)));
    }

    /// Stops the work running for a job, if any. Returns whether there was some.
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
    /// What the machine calls itself, asked once.
    static DEFAULT_DEVICE_NAME: String = crate::services::sync::default_name();
}

fn is_file(path: &str) -> bool {
    !path.is_empty() && std::path::Path::new(path).is_file()
}

/// A job whose media is there is no longer marked as missing it.
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

/// The subtitle files beside `media` that carry its name.
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
