use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    rc::Rc,
};

use listenook_core::{
    Document, Job, JobSourceOrigin, JobStatus, Label, LibraryCatalog, LocaleMode, Named, Settings, ThemeMode,
    l10n::Lang, media::subtitles,
};
use nsh_core::prelude::*;

use crate::services::{
    persist,
    secrets::{self, Secret},
};

use super::monitor::MonitorState;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub(crate) enum Place {
    #[default]
    Home,
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
            Filter::Group(id) => job.in_group(id),
            Filter::Tag(id) => job.has_tag(id),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum SettingsTab {
    #[default]
    General,
    Transcription,
    Ai,
    Shortcuts,
    About,
}

/// What the AI provider lacks before it can take a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AiSetup {
    /// Its endpoint or model.
    Provider,
    /// Only an API key.
    Key,
    /// Only a ChatGPT sign-in.
    SignIn,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Shelf {
    Continue,
    Recent,
}

impl Shelf {
    fn hidden(self, settings: &Settings) -> &std::collections::BTreeSet<String> {
        match self {
            Shelf::Continue => &settings.continue_hidden,
            Shelf::Recent => &settings.recent_hidden,
        }
    }

    fn mark(self, id: &str) -> String {
        match self {
            Shelf::Continue => format!("continue:{id}"),
            Shelf::Recent => format!("recent:{id}"),
        }
    }

    fn of_mark(key: &str) -> Option<(Shelf, &str)> {
        key.strip_prefix("continue:")
            .map(|id| (Shelf::Continue, id))
            .or_else(|| key.strip_prefix("recent:").map(|id| (Shelf::Recent, id)))
    }

    fn hidden_mut(self, settings: &mut Settings) -> &mut std::collections::BTreeSet<String> {
        match self {
            Shelf::Continue => &mut settings.continue_hidden,
            Shelf::Recent => &mut settings.recent_hidden,
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) struct Store {
    owner: Owner,
    root: Stored<Option<PathBuf>>,
    jobs: Signal<Vec<Rc<Job>>>,
    settings: Signal<Settings>,
    positions: Stored<BTreeMap<String, i64>>,
    played: Signal<BTreeMap<String, String>>,
    catalog: Signal<LibraryCatalog>,
    place: Signal<Place>,
    filter: Signal<Filter>,
    open_job: Signal<Option<String>>,
    play_on_open: Stored<Option<String>>,
    left_paused: Stored<std::collections::HashSet<String>>,
    open_video: Signal<Option<String>>,
    players: Signal<usize>,
    video_only: Signal<bool>,
    settings_open: Signal<bool>,
    settings_tab: Signal<SettingsTab>,
    /// Bumped whenever a key is saved or removed, so what shows whether one is there follows.
    keys: Signal<u32>,
    home_search: Signal<bool>,
    immersive: Signal<bool>,
    sidebar_hidden: Signal<bool>,
    focused: Signal<bool>,
    drawer: Signal<bool>,
    subtitle_choices: Signal<Vec<(String, Vec<String>)>>,
    language_hints: Signal<String>,
    context_terms: Signal<String>,
    running: Stored<HashMap<String, Spawned<()>>>,
    /// Told when a recording's status changes, with the status it had.
    status_changed: Stored<Option<StatusTold>>,
}

/// What hears of a recording's status changing, with the status it had.
type StatusTold = Rc<dyn Fn(&Job, JobStatus)>;

#[derive(Clone, Default)]
struct Handle(Option<Store>);

pub(crate) fn store() -> Store {
    global::<Handle>().get_untracked().0.expect("the root component makes the store")
}

fn recovered(mut job: Job) -> Job {
    job.apply(listenook_core::Change::Recover);
    job
}

fn rehomed(mut job: Job, root: &std::path::Path) -> Job {
    if let Some(path) = persist::rehomed(&job.source_path, root, |path| path.exists()) {
        job.apply(listenook_core::Change::Relink(path));
    }
    job
}

/// What the app asks of the store: where to go, what to show, and changes to the library and the settings.
#[derive(Debug)]
pub(crate) enum Action<'a> {
    Go(Place),
    Show(Filter),
    OpenTranscript(&'a str),
    /// Opens a recording from Home's Continue cards: it plays on, unless it was left paused in this session.
    Resume(&'a str),
    /// The reader of `id` closed, playing or paused.
    LeftReader(&'a str, bool),
    /// Plays the video at `path` in the app's own window, as it does on a phone or where it
    /// cannot open a window of its own.
    ShowVideo(&'a str),
    PlayerOpened,
    SetVideoOnly(bool),
    CloseVideo,
    CloseReader,
    SubtitleChosen,
    SetFocused(bool),
    SetDrawer(bool),
    ToggleSidebar,
    SetImmersive(bool),
    OpenSettings(SettingsTab),
    RememberPosition(&'a str, Option<i64>),
    Shelve(Shelf, &'a str, bool),
    AdoptShelves(&'a listenook_core::sync::Shelves),
    SetProgress(&'a str, &'a str, Option<f64>),
    AddJob(Job),
    RemoveJob(&'a str),
    AdoptRemovals(&'a listenook_core::sync::Removed),
    SaveRate(&'static str, f32),
    RenameGroup(&'a str, &'a str),
    DeleteGroup(&'a str),
    SetGroup(&'a str, Option<String>),
    RenameTag(&'a str, &'a str),
    DeleteTag(&'a str),
    ToggleTag(&'a str, &'a str),
    SetSyncVisible(bool),
    SetDeviceName(&'a str),
    SetDailyGoalMinutes(u32),
    AdoptJob(Job, &'a HashMap<String, String>),
    AdoptMedia(&'a str, &'a std::path::Path),
    AdoptName(&'a str, &'a str),
}

impl Store {
    /// Does `action`.
    pub(crate) fn act(&self, action: Action<'_>) {
        match action {
            Action::Go(place) => self.go(place),
            Action::Show(filter) => self.show(filter),
            Action::OpenTranscript(id) => self.open_transcript(id),
            Action::Resume(id) => self.resume(id),
            Action::LeftReader(id, paused) => self.left_reader(id, paused),
            Action::ShowVideo(path) => self.show_video(path),
            Action::PlayerOpened => self.player_opened(),
            Action::SetVideoOnly(only) => self.set_video_only(only),
            Action::CloseVideo => self.close_video(),
            Action::CloseReader => self.close_reader(),
            Action::SubtitleChosen => self.subtitle_chosen(),
            Action::SetFocused(focused) => self.set_focused(focused),
            Action::SetDrawer(out) => self.set_drawer(out),
            Action::ToggleSidebar => self.toggle_sidebar(),
            Action::SetImmersive(on) => self.set_immersive(on),
            Action::OpenSettings(tab) => self.open_settings(tab),
            Action::RememberPosition(job_id, position) => self.remember_position(job_id, position),
            Action::Shelve(shelf, id, shown) => self.shelve(shelf, id, shown),
            Action::AdoptShelves(theirs) => self.adopt_shelves(theirs),
            Action::SetProgress(id, stage, fraction) => self.set_progress(id, stage, fraction),
            Action::AddJob(job) => self.add_job(job),
            Action::RemoveJob(id) => self.remove_job(id),
            Action::AdoptRemovals(theirs) => self.adopt_removals(theirs),
            Action::SaveRate(key, rate) => self.save_rate(key, rate),
            Action::RenameGroup(id, name) => self.rename_group(id, name),
            Action::DeleteGroup(id) => self.delete_group(id),
            Action::SetGroup(job_id, group_id) => self.set_group(job_id, group_id),
            Action::RenameTag(id, name) => self.rename_tag(id, name),
            Action::DeleteTag(id) => self.delete_tag(id),
            Action::ToggleTag(job_id, name) => self.toggle_tag(job_id, name),
            Action::SetSyncVisible(visible) => self.set_sync_visible(visible),
            Action::SetDeviceName(name) => self.set_device_name(name),
            Action::SetDailyGoalMinutes(minutes) => self.set_daily_goal_minutes(minutes),
            Action::AdoptJob(job, map) => self.adopt_job(job, map),
            Action::AdoptMedia(id, path) => self.adopt_media(id, path),
            Action::AdoptName(id, name) => self.adopt_name(id, name),
        }
    }

    pub(crate) fn install() -> Store {
        persist::learn_data_root();
        let root = persist::data_root();
        let library_catalog = root.as_deref().map(persist::load_library_catalog).unwrap_or_default();
        let (jobs, mut settings) = match &root {
            Some(root) => (
                persist::load_jobs(root)
                    .into_iter()
                    .map(recovered)
                    .map(|job| rehomed(job, root))
                    .map(Rc::new)
                    .collect(),
                persist::load_settings(root),
            ),
            None => (Vec::new(), Settings::default()),
        };
        let positions = std::mem::take(&mut settings.playback_positions_ms);
        let played = std::mem::take(&mut settings.playback_played_at);
        let store = Store {
            owner: Owner::current(),
            root: stored(root),
            jobs: signal(jobs),
            settings: signal(settings),
            positions: stored(positions),
            played: signal(played),
            catalog: signal(library_catalog),
            place: signal(Place::default()),
            filter: signal(Filter::default()),
            settings_open: signal(false),
            settings_tab: signal(SettingsTab::default()),
            keys: signal(0),
            home_search: signal(false),
            immersive: signal(false),
            sidebar_hidden: signal(false),
            focused: signal(true),
            drawer: signal(false),
            subtitle_choices: signal(Vec::new()),
            open_job: signal(None),
            play_on_open: stored(None),
            left_paused: stored(std::collections::HashSet::new()),
            open_video: signal(None),
            players: signal(0),
            video_only: signal(false),
            language_hints: signal(String::new()),
            context_terms: signal(String::new()),
            running: stored(HashMap::new()),
            status_changed: stored(None),
        };
        effect(move || crate::ui::set_lang(store.lang()));
        match std::env::var("LISTENOOK_START").as_deref() {
            Ok("reader") => {
                let newest = store
                    .jobs
                    .with_untracked(|jobs| jobs.iter().find(|job| job.has_transcript()).map(|job| job.id.clone()));
                store.open_job.set(newest);
            }
            Ok("podcasts") => store.place.set(Place::Podcasts),
            Ok("settings") => store.settings_open.set(true),
            _ => {}
        }
        store.sidebar_hidden.set(
            store.settings.with_untracked(|s| s.extra.get("sidebar_hidden").and_then(|v| v.as_bool()).unwrap_or(false)),
        );
        if let Some(temporary) = store.data_root().map(|root| root.join("temporary")) {
            // What work in progress writes, left by a run that ended mid-way; the made
            // playable copies and loudness maps are kept.
            for entry in std::fs::read_dir(temporary).into_iter().flatten().flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                let left = ["player-", "speech-"].iter().any(|start| name.starts_with(start))
                    || [".part", "-local.wav"].iter().any(|end| name.ends_with(end));
                if left {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
        global::<Handle>().set(Handle(Some(store)));
        store
    }

    /// Has `told` hear of each recording whose status changes, with the status it had.
    pub(crate) fn when_status_changes(&self, told: impl Fn(&Job, JobStatus) + 'static) {
        self.status_changed.replace(Some(Rc::new(told)));
    }

    pub(crate) fn data_root(&self) -> Option<PathBuf> {
        self.root.with(|root| root.clone())
    }

    pub(crate) fn place(&self) -> Place {
        self.place.get()
    }

    fn go(&self, place: Place) {
        batch(|| {
            self.open_job.set(None);
            self.open_video.set(None);
            self.home_search.set(false);
            self.place.set(place);
        });
    }

    pub(crate) fn filter(&self) -> Filter {
        self.filter.get()
    }

    fn show(&self, filter: Filter) {
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

    fn open_transcript(&self, id: &str) {
        self.shelve(Shelf::Continue, id, true);
        batch(|| {
            self.open_video.set(None);
            self.open_job.set(Some(id.to_owned()));
        });
    }

    /// Opens a recording from Home's Continue cards: it plays on, unless it was left paused in this session.
    fn resume(&self, id: &str) {
        if !self.left_paused.with(|paused| paused.contains(id)) {
            self.play_on_open.with(|wanted| *wanted = Some(id.to_owned()));
        }
        self.open_transcript(id);
    }

    /// The reader of `id` closed, playing or paused.
    fn left_reader(&self, id: &str, paused: bool) {
        self.left_paused.with(|left| {
            if paused {
                left.insert(id.to_owned());
            } else {
                left.remove(id);
            }
        });
    }

    pub(crate) fn take_play_on_open(&self, id: &str) -> bool {
        self.play_on_open.with(|wanted| wanted.take_if(|wanted| wanted == id).is_some())
    }

    pub(crate) fn open_video_path(&self) -> Option<String> {
        self.open_video.get()
    }

    /// Plays the video at `path` in the app's own window, as it does on a phone or where it
    /// cannot open a window of its own.
    fn show_video(&self, path: &str) {
        self.open_video.set(Some(path.to_owned()));
    }

    pub(crate) fn video_playing(&self) -> bool {
        self.open_video.with(Option::is_some) || self.players.get() > 0
    }

    fn player_opened(&self) {
        self.players.update(|count| *count += 1);
    }

    pub(crate) fn player_closed(&self) -> bool {
        self.players.update(|count| *count = count.saturating_sub(1));
        self.players.get_untracked() == 0
            && self.video_only.get_untracked()
            && !untracked(|| MonitorState::get().tray_enabled())
    }

    pub(crate) fn video_only(&self) -> bool {
        self.video_only.get_untracked()
    }

    fn set_video_only(&self, only: bool) {
        self.video_only.set(only);
    }

    fn close_video(&self) {
        self.open_video.set(None);
    }

    fn close_reader(&self) {
        self.open_job.set(None);
    }

    pub(crate) fn immersive(&self) -> bool {
        self.immersive.get()
    }

    pub(crate) fn subtitle_choice(&self) -> Option<(String, Vec<String>)> {
        self.subtitle_choices.with(|choices| choices.first().cloned())
    }

    fn subtitle_chosen(&self) {
        self.subtitle_choices.update(|choices| {
            if !choices.is_empty() {
                choices.remove(0);
            }
        });
    }

    pub(crate) fn focused(&self) -> bool {
        self.focused.get_untracked()
    }

    fn set_focused(&self, focused: bool) {
        self.focused.set(focused);
    }

    pub(crate) fn sidebar_hidden(&self) -> bool {
        self.sidebar_hidden.get()
    }

    pub(crate) fn drawer(&self) -> bool {
        self.drawer.get()
    }

    fn set_drawer(&self, out: bool) {
        self.drawer.set(out);
    }

    pub(crate) fn drawer_now(&self) -> bool {
        self.drawer.get_untracked()
    }

    fn toggle_sidebar(&self) {
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

    fn set_immersive(&self, on: bool) {
        self.immersive.set(on);
    }

    pub(crate) fn home_search(&self) -> Signal<bool> {
        self.home_search
    }

    pub(crate) fn settings_open(&self) -> Signal<bool> {
        self.settings_open
    }

    pub(crate) fn settings_tab(&self) -> Signal<SettingsTab> {
        self.settings_tab
    }

    fn open_settings(&self, tab: SettingsTab) {
        batch(|| {
            self.settings_tab.set(tab);
            self.settings_open.set(true);
        });
    }

    pub(crate) fn settings(&self) -> Settings {
        self.settings.get()
    }

    pub(crate) fn setting<T>(&self, read: impl FnOnce(&Settings) -> T) -> T {
        self.settings.with(read)
    }

    /// Whether `secret` has a key, followed reactively as keys are saved and removed.
    pub(crate) fn has_key(&self, secret: Secret) -> bool {
        self.keys.with(|_| ());
        secrets::read(secret).is_some()
    }

    /// Saves `secret` (or removes it when `value` is empty), telling what follows `has_key`.
    pub(crate) fn write_key(&self, secret: Secret, value: &str) -> Result<(), String> {
        secrets::write(secret, value)?;
        self.keys.update(|keys| *keys += 1);
        Ok(())
    }

    /// What the AI provider still needs before it can translate or write a brief, if anything.
    pub(crate) fn ai_setup(&self) -> Option<AiSetup> {
        let (invalid, local, signs_in) = self.setting(|s| {
            let provider = &s.llm_provider_settings;
            (provider.validate().is_some(), provider.is_loopback(), provider.signs_in())
        });
        if invalid {
            Some(AiSetup::Provider)
        } else if signs_in {
            (!self.has_key(Secret::ChatGpt)).then_some(AiSetup::SignIn)
        } else if !local && !self.has_key(Secret::Llm) {
            Some(AiSetup::Key)
        } else {
            None
        }
    }

    /// Whether the AI provider can take a request: an endpoint, a model, and an API key unless
    /// it runs on this computer.
    pub(crate) fn ai_ready(&self) -> bool {
        self.ai_setup().is_none()
    }

    pub(crate) fn update_settings(&self, change: impl FnOnce(&mut Settings)) {
        self.settings.update(change);
        self.save_settings();
    }

    pub(crate) fn playback_position(&self, job_id: &str) -> Option<i64> {
        self.positions.with(|positions| positions.get(job_id).copied())
    }

    fn remember_position(&self, job_id: &str, position: Option<i64>) {
        let changed = self.positions.with(|positions| match position {
            Some(position) => positions.insert(job_id.to_owned(), position) != Some(position),
            None => positions.remove(job_id).is_some(),
        });
        if changed {
            self.played.update(|played| drop(played.insert(job_id.to_owned(), listenook_core::now_iso())));
            self.save_settings();
        }
    }

    pub(crate) fn played(&self) -> Vec<(String, String, i64)> {
        self.played.with(|played| {
            self.positions.with(|positions| {
                positions
                    .iter()
                    .map(|(id, position)| (id.clone(), played.get(id).cloned().unwrap_or_default(), *position))
                    .collect()
            })
        })
    }

    /// When each recording last played, as ISO times: finished ones too, which have no place left.
    pub(crate) fn last_played(&self) -> BTreeMap<String, String> {
        self.played.get()
    }

    pub(crate) fn shelved(&self, shelf: Shelf, id: &str) -> bool {
        self.settings.with(|settings| !shelf.hidden(settings).contains(id))
    }

    fn shelve(&self, shelf: Shelf, id: &str, shown: bool) {
        if self.settings.with_untracked(|settings| shelf.hidden(settings).contains(id) != shown) {
            return;
        }
        self.update_settings(|settings| {
            let hidden = shelf.hidden_mut(settings);
            if shown {
                hidden.remove(id);
            } else {
                hidden.insert(id.to_owned());
            }
            let mark = listenook_core::Mark { hidden: !shown, at: listenook_core::now_iso() };
            settings.shelf_marks.insert(shelf.mark(id), mark);
        });
        persist::changed();
    }

    fn adopt_shelves(&self, theirs: &listenook_core::sync::Shelves) {
        let (marks, goal) = self.settings.with_untracked(|settings| {
            (settings.shelf_marks.clone(), listenook_core::sync::Goal::of_settings(settings))
        });
        let mut mine = listenook_core::sync::Shelves {
            goal,
            ..listenook_core::sync::Shelves::of(&self.positions.get(), &self.played.get_untracked(), &marks)
        };
        if !listenook_core::sync::merge_shelves(&mut mine, theirs) {
            return;
        }
        let (positions, played) = mine.positions();
        self.positions.replace(positions);
        batch(|| {
            self.played.set(played);
            self.update_settings(|settings| {
                for (key, mark) in &mine.marks {
                    let Some((shelf, id)) = Shelf::of_mark(key) else {
                        continue;
                    };
                    let hidden = shelf.hidden_mut(settings);
                    if mark.hidden {
                        hidden.insert(id.to_owned());
                    } else {
                        hidden.remove(id);
                    }
                }
                settings.shelf_marks = mine.marks;
                if let Some(goal) = mine.goal {
                    settings.daily_goal_minutes = goal.minutes;
                    settings.daily_goal_set_at = goal.at;
                }
            });
        });
    }

    fn save_settings(&self) {
        if let Some(root) = self.data_root() {
            let mut settings = self.settings.get_untracked();
            settings.playback_positions_ms = self.positions.get();
            settings.playback_played_at = self.played.get_untracked();
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

    fn set_progress(&self, id: &str, stage: &str, fraction: Option<f64>) {
        self.change_job(id, false, |job| job.apply(listenook_core::Change::SetProgress(stage, fraction)));
    }

    fn change_job(&self, id: &str, persist: bool, change: impl FnOnce(&mut Job)) {
        let mut changed = None;
        let mut finished = None;
        self.jobs.update(|jobs| {
            if let Some(job) = jobs.iter_mut().find(|job| job.id == id) {
                let job = Rc::make_mut(job);
                let was = job.status;
                change(job);
                job.apply(listenook_core::Change::Touch);
                if job.status != was {
                    finished = Some(was);
                }
                changed = Some(job.clone());
            }
        });
        if let (Some(job), Some(was)) = (&changed, finished)
            && let Some(told) = self.status_changed.with(|told| told.clone())
        {
            told(job, was);
        }
        if persist && let Some(job) = changed {
            self.save(&job);
        }
    }

    pub(crate) fn update_document(&self, id: &str, change: impl FnOnce(&mut Document)) {
        self.update_job(id, |job| job.edit_document(change));
    }

    pub(crate) fn new_job(&self, path: &str, origin: JobSourceOrigin) -> Job {
        let mut job = Job::new(uuid::Uuid::new_v4().to_string(), path, origin);
        self.apply_options(&mut job);
        job
    }

    pub(crate) fn apply_options(&self, job: &mut Job) {
        let settings = self.settings.get_untracked();
        let split = |text: String| -> Vec<String> {
            text.split([',', '\n']).map(|part| part.trim().to_owned()).filter(|part| !part.is_empty()).collect()
        };
        job.apply(listenook_core::Change::ApplyOptions(
            &settings,
            split(self.language_hints.get_untracked()),
            split(self.context_terms.get_untracked()),
        ));
    }

    fn add_job(&self, job: Job) {
        self.insert(job);
    }

    pub(crate) fn add_files(&self, paths: &[String]) -> usize {
        let media: Vec<&String> = paths.iter().filter(|path| subtitles::is(path, subtitles::Kind::Media)).collect();
        let mut added = 0;
        for path in media {
            let known = self
                .jobs
                .with_untracked(|jobs| jobs.iter().any(|job| &job.source_path == path && !job.status().is_terminal()));
            if known {
                continue;
            }
            let job = self.new_job(path, JobSourceOrigin::Manual);
            let id = job.id.clone();
            self.insert(job);
            added += 1;
            // A matching subtitle file is only offered, never taken on its own: subtitles from
            // YouTube are often auto-generated and read badly, so the person chooses.
            let mut matching: Vec<String> = paths
                .iter()
                .filter(|other| subtitles::is(other, subtitles::Kind::Subtitles) && subtitles::pairs_with(other, path))
                .cloned()
                .chain(sibling_subtitles(path))
                .collect();
            matching.sort();
            matching.dedup();
            if !matching.is_empty() {
                self.subtitle_choices.update(|choices| choices.push((id, matching)));
            }
        }
        added
    }

    fn remove_job(&self, id: &str) {
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

    fn adopt_removals(&self, theirs: &listenook_core::sync::Removed) {
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
        self.shelve(Shelf::Continue, id, true);
        self.shelve(Shelf::Recent, id, true);
        for key in [id.to_owned(), format!("{id}:translate"), format!("{id}:brief")] {
            self.cancel_work(&key);
        }
        if let (Some(root), Some(job)) = (self.data_root(), self.job_now(id))
            && std::path::Path::new(&job.source_path).starts_with(root.join("media"))
            && !persist::climbs(std::path::Path::new(&job.source_path))
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
        crate::services::audio::forget_loudness(id);
    }

    /// Whether to transcribe on this device with the larger Qwen3 model.
    pub(crate) fn large_local_model(&self) -> bool {
        self.settings.with(|s| s.extra.get("qwen3_local_model").and_then(serde_json::Value::as_str) == Some("1.7b"))
    }

    pub(crate) fn saved_rate(&self, key: &str) -> f32 {
        self.settings
            .with_untracked(|s| s.extra.get(key).and_then(serde_json::Value::as_f64))
            .map_or(1.0, |rate| (rate as f32).clamp(0.5, 2.0))
    }

    fn save_rate(&self, key: &'static str, rate: f32) {
        self.update_settings(|s| drop(s.extra.insert(key.into(), f64::from(rate).into())));
    }

    pub(crate) fn groups(&self) -> Vec<Named> {
        self.catalog.with(|catalog| catalog.named(Label::Group))
    }

    pub(crate) fn tags(&self) -> Vec<Named> {
        self.catalog.with(|catalog| catalog.named(Label::Tag))
    }

    /// The id of the group or tag called `name`, made when there is none yet.
    fn label(&self, label: Label, name: &str) -> Option<String> {
        let name = name.trim();
        if name.is_empty() {
            return None;
        }
        if let Some(existing) = self.catalog.with_untracked(|catalog| catalog.find(label, name)) {
            return Some(existing);
        }
        let id = uuid::Uuid::new_v4().to_string();
        self.change_catalog(|catalog| catalog.add(label, id.clone(), name));
        Some(id)
    }

    fn rename_label(&self, id: &str, name: &str) {
        let name = name.trim();
        if !name.is_empty() {
            self.change_catalog(|catalog| catalog.rename(id, name));
        }
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
        self.label(Label::Group, name)
    }

    fn rename_group(&self, id: &str, name: &str) {
        self.rename_label(id, name);
    }

    fn delete_group(&self, id: &str) {
        let members: Vec<String> = self
            .jobs
            .with_untracked(|jobs| jobs.iter().filter(|job| job.in_group(id)).map(|job| job.id.clone()).collect());
        for job in members {
            self.update_job(&job, |job| job.apply(listenook_core::Change::LeaveGroup(id)));
        }
        self.change_catalog(|catalog| catalog.remove(id));
        if self.filter.get_untracked() == Filter::Group(id.to_owned()) {
            self.filter.set(Filter::All);
        }
    }

    fn set_group(&self, job_id: &str, group_id: Option<String>) {
        self.update_job(job_id, |job| job.apply(listenook_core::Change::FileIn(group_id.as_deref())));
    }

    pub(crate) fn add_tag(&self, name: &str) -> Option<String> {
        self.label(Label::Tag, name)
    }

    fn rename_tag(&self, id: &str, name: &str) {
        self.rename_label(id, name);
    }

    fn delete_tag(&self, id: &str) {
        let tagged: Vec<String> = self
            .jobs
            .with_untracked(|jobs| jobs.iter().filter(|job| job.has_tag(id)).map(|job| job.id.clone()).collect());
        for job in tagged {
            self.update_job(&job, |job| job.apply(listenook_core::Change::DropTag(id)));
        }
        self.change_catalog(|catalog| catalog.remove(id));
        if self.filter.get_untracked() == Filter::Tag(id.to_owned()) {
            self.filter.set(Filter::All);
        }
    }

    fn toggle_tag(&self, job_id: &str, name: &str) {
        let Some(tag) = self.add_tag(name) else {
            return;
        };
        self.update_job(job_id, |job| job.apply(listenook_core::Change::ToggleTag(&tag)));
    }

    pub(crate) fn sync_visible(&self) -> bool {
        self.settings.with(|s| s.extra.get("sync_visible").and_then(|v| v.as_bool()).unwrap_or(false))
    }

    pub(crate) fn sync_decided(&self) -> bool {
        self.settings.with_untracked(|s| s.extra.contains_key("sync_visible"))
    }

    fn set_sync_visible(&self, visible: bool) {
        self.update_settings(|s| drop(s.extra.insert("sync_visible".into(), visible.into())));
    }

    pub(crate) fn device_name(&self) -> String {
        self.settings
            .with(|s| s.extra.get("sync_device_name").and_then(|v| v.as_str()).map(str::to_owned))
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| DEFAULT_DEVICE_NAME.with(|name| name.clone()))
    }

    fn set_device_name(&self, name: &str) {
        let name: String = name.chars().take(64).collect();
        self.update_settings(|s| drop(s.extra.insert("sync_device_name".into(), name.into())));
    }

    /// This device's id, made on first need: Sync announces it, and the
    /// learning time this device counts is filed under it.
    pub(crate) fn device_id(&self) -> String {
        self.made_id("sync_device_id")
    }

    /// The name this device signs in to ChatGPT under, the same at each sign-in, and apart from
    /// the id Sync announces.
    pub(crate) fn chatgpt_host(&self) -> String {
        format!("urn:uuid:{}", self.made_id("chatgpt_host_id"))
    }

    /// The id the settings keep under `name`, made and kept on first need.
    fn made_id(&self, name: &str) -> String {
        let known = self.settings.with_untracked(|s| s.extra.get(name).and_then(|v| v.as_str()).map(str::to_owned));
        known.unwrap_or_else(|| {
            let id = uuid::Uuid::new_v4().to_string();
            self.update_settings(|s| drop(s.extra.insert(name.into(), id.clone().into())));
            id
        })
    }

    pub(crate) fn daily_goal_minutes(&self) -> u32 {
        self.settings.with(|s| s.daily_goal_minutes)
    }

    fn set_daily_goal_minutes(&self, minutes: u32) {
        self.update_settings(|s| {
            s.daily_goal_minutes = minutes;
            s.daily_goal_set_at = listenook_core::now_iso();
        });
        persist::changed();
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
        let map = merged.merge(theirs);
        if merged != self.catalog.get_untracked() {
            let shown = match self.filter.get_untracked() {
                Filter::Group(id) | Filter::Tag(id) => Some(id),
                _ => None,
            };
            if shown.is_some_and(|id| merged.is_removed(&id)) {
                self.filter.set(Filter::All);
            }
            self.change_catalog(|catalog| *catalog = merged);
        }
        map
    }

    fn adopt_job(&self, job: Job, map: &HashMap<String, String>) {
        let Some(root) = self.data_root() else {
            return;
        };
        let existing = self.job_now(&job.id);
        if existing.as_ref().is_some_and(|existing| existing.is_busy()) {
            return;
        }
        let mut job = recovered(job);
        self.catalog.with_untracked(|catalog| job.refile(map, catalog));
        let name = job.file_name();
        let brought = root.join("media").join(listenook_core::sync::media_file_name(&job.id, &job.file_name()));
        // The plan was made when the sync started; an edit made here since then is newer than
        // what arrived, so it stays and goes to the other device next time. Media that came
        // with it is still taken in.
        if let Some(existing) = &existing
            && listenook_core::sync::edited_after(&existing.updated_at, &job.updated_at)
        {
            if brought.is_file() {
                self.adopt_media(&job.id, &brought);
            }
            return;
        }
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
        // The path the other device sent names a file on that device. It is never kept: this
        // device reads and deletes what a recording's path names, so a path chosen by a peer
        // could reach any file here. The media is the copy this device has, or the one sync
        // brings into `media`.
        let here = existing.as_ref().map(|existing| existing.source_path.clone()).filter(|path| !path.is_empty());
        let path = match here {
            Some(path) if is_file(&path) || !brought.is_file() => path,
            _ => brought.to_string_lossy().into_owned(),
        };
        job.apply(listenook_core::Change::TakeMedia(path, &name));
        found_again(&mut job);
        self.save(&job);
        let id = job.id.clone();
        self.jobs.update(|jobs| match jobs.iter_mut().find(|other| other.id == id) {
            Some(place) => *place = Rc::new(job),
            None => {
                jobs.push(Rc::new(job));
                jobs.sort_by(|a, b| b.cmp_added(a));
            }
        });
    }

    fn adopt_media(&self, id: &str, path: &std::path::Path) {
        let mut changed = None;
        self.jobs.update(|jobs| {
            if let Some(job) = jobs
                .iter_mut()
                .find(|job| job.id == id)
                .filter(|job| !is_file(&job.source_path) || std::path::Path::new(&job.source_path) == path)
            {
                let job = Rc::make_mut(job);
                let name = job.file_name();
                job.apply(listenook_core::Change::TakeMedia(path.to_string_lossy().into_owned(), &name));
                found_again(job);
                changed = Some(job.clone());
            }
        });
        if let Some(job) = changed {
            self.save(&job);
        }
    }

    fn adopt_name(&self, id: &str, name: &str) {
        let mut changed = None;
        self.jobs.update(|jobs| {
            if let Some(job) = jobs.iter_mut().find(|job| job.id == id) {
                let mut named = (**job).clone();
                if named.keep_title(name) {
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
    if is_file(&job.source_path) {
        job.apply(listenook_core::Change::Relink(job.source_path.clone()));
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
        .filter(|path| subtitles::is(path, subtitles::Kind::Subtitles) && subtitles::pairs_with(path, media))
        .collect();
    found.sort();
    found
}
