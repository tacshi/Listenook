use listenook_core::{
    now_iso,
    podcast::{Catalog, Episode, Feed, Followed, ListenProgress},
};
use nsh_core::prelude::*;

use crate::services::persist;

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Playing {
    pub(crate) episode: Episode,
    pub(crate) show_title: SharedString,
    pub(crate) source: String,
    pub(crate) artwork: String,
}

#[derive(Clone, Copy)]
pub(crate) struct PodcastState {
    catalog: Signal<Catalog>,
    playing: Signal<Option<Playing>>,
    paused: Signal<bool>,
    position_ms: Signal<i64>,
    duration_ms: Signal<i64>,
    rate: Signal<f32>,
    open_show: Signal<Option<String>>,
    pub(crate) query: Signal<String>,
    adding: Signal<bool>,
    seek: Signal<(u32, i64)>,
    listened: Signal<Vec<ListenProgress>>,
    reports: Stored<u32>,
}

pub(crate) const RATES: &[f32] = &[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

pub(crate) fn rate_label(rate: f32) -> SharedString {
    format!("{rate}×").into()
}

/// What the app asks of the podcast player and the shows followed.
#[derive(Debug)]
pub(crate) enum PodcastAction<'a> {
    Show(&'a str),
    CloseShow,
    AddShow,
    CacheFeed(Feed),
    SetFollowed(&'a Feed, bool),
    Play(Episode, SharedString, String),
    SetPaused(bool),
    Stop,
    Report(i64, i64),
    SetRate(f32),
    SeekTo(i64),
}

impl PodcastState {
    /// Does `action`.
    pub(crate) fn act(&self, action: PodcastAction<'_>) {
        match action {
            PodcastAction::Show(feed_url) => self.show(feed_url),
            PodcastAction::CloseShow => self.close_show(),
            PodcastAction::AddShow => self.add_show(),
            PodcastAction::CacheFeed(feed) => self.cache_feed(feed),
            PodcastAction::SetFollowed(feed, followed) => self.set_followed(feed, followed),
            PodcastAction::Play(episode, show_title, source) => self.play(episode, show_title, source),
            PodcastAction::SetPaused(paused) => self.set_paused(paused),
            PodcastAction::Stop => self.stop(),
            PodcastAction::Report(position_ms, duration_ms) => self.report(position_ms, duration_ms),
            PodcastAction::SetRate(rate) => self.set_rate(rate),
            PodcastAction::SeekTo(position_ms) => self.seek_to(position_ms),
        }
    }

    /// Makes the podcast state from what the library keeps, playing at the rate chosen last.
    pub(crate) fn install(store: super::Store) {
        let root = persist::data_root();
        let catalog = root.as_deref().map(persist::load_catalog).unwrap_or_default();
        let listened = root.as_deref().map(persist::load_listening).unwrap_or_default();
        let state = Self::new(catalog, listened);
        state.set_rate(store.saved_rate("podcast_rate"));
        super::install(state);
    }

    pub(crate) fn get() -> Self {
        super::installed()
    }

    fn new(mut catalog: Catalog, listened: Vec<ListenProgress>) -> Self {
        let repaired = catalog.drop_duplicate_follows(&now_iso());
        let state = Self {
            catalog: signal(catalog),
            playing: signal(None),
            paused: signal(true),
            position_ms: signal(0),
            duration_ms: signal(0),
            rate: signal(1.0),
            open_show: signal(None),
            query: signal(String::new()),
            adding: signal(false),
            seek: signal((0, 0)),
            listened: signal(listened),
            reports: stored(0),
        };
        if repaired {
            state.save();
        }
        state
    }

    fn save(&self) {
        if let Some(root) = persist::data_root()
            && let Err(error) =
                persist::save_catalog(&root, &self.catalog.get_untracked(), &self.listened.get_untracked())
        {
            log::error!("saving the podcast catalog: {error}");
        }
    }

    /// The feed of the show open on its own page, for the page to follow and close.
    pub(crate) fn open_show(&self) -> Signal<Option<String>> {
        self.open_show
    }

    fn show(&self, feed_url: &str) {
        self.open_show.set(Some(feed_url.to_owned()));
    }

    fn close_show(&self) {
        self.open_show.set(None);
    }

    /// Whether the dialog for adding a show by its feed's address shows.
    pub(crate) fn adding(&self) -> Signal<bool> {
        self.adding
    }

    fn add_show(&self) {
        self.adding.set(true);
    }

    pub(crate) fn followed(&self) -> Vec<Followed> {
        self.catalog.with(|catalog| catalog.followed.clone())
    }

    pub(crate) fn is_followed(&self, feed_url: &str) -> bool {
        self.catalog.with(|catalog| catalog.is_followed(feed_url))
    }

    pub(crate) fn feed(&self, feed_url: &str) -> Option<Feed> {
        self.catalog.with(|catalog| catalog.feed(feed_url))
    }

    pub(crate) fn feed_url_of(&self, episode_id: &str) -> Option<String> {
        self.catalog.with(|catalog| catalog.feed_of(episode_id).map(|feed| feed.feed_url.clone()))
    }

    fn cache_feed(&self, feed: Feed) {
        let heard = self.listened.get_untracked();
        self.catalog.update(|catalog| catalog.cache(feed, &heard));
        self.save();
    }

    fn set_followed(&self, feed: &Feed, followed: bool) {
        self.catalog.update(|catalog| catalog.set_followed(feed, followed, &now_iso()));
        self.save();
    }

    /// Takes in what another device follows and has heard. The feeds it follows that this
    /// device has never loaded, to load now.
    pub(crate) fn adopt(&self, remote: &listenook_core::sync::Podcasts) -> Vec<String> {
        let (mut catalog, mut listened) = (self.catalog.get_untracked(), self.listened.get_untracked());
        if !listenook_core::sync::merge_podcasts(&mut catalog, &mut listened, remote) {
            return Vec::new();
        }
        let missing = catalog.never_loaded();
        let moved = self
            .playing
            .with_untracked(|playing| playing.as_ref().map(|playing| playing.episode.id.clone()))
            .filter(|_| self.paused.get_untracked())
            .and_then(|id| listenook_core::podcast::moved_to(&self.listened.get_untracked(), &listened, &id));
        batch(|| {
            self.catalog.set(catalog);
            self.listened.set(listened);
            if let Some(position_ms) = moved {
                self.seek_to(position_ms);
            }
        });
        self.save();
        if let Some(root) = persist::data_root()
            && let Err(error) = persist::save_listening(&root, &self.listened.get_untracked())
        {
            log::error!("saving listening progress: {error}");
        }
        missing
    }

    pub(crate) fn feeds(&self) -> Vec<Feed> {
        self.catalog.with(|catalog| catalog.feeds.clone())
    }

    pub(crate) fn listening(&self) -> Vec<ListenProgress> {
        self.listened.get()
    }

    pub(crate) fn playing(&self) -> Option<Playing> {
        self.playing.get()
    }

    pub(crate) fn is_current(&self, episode_id: &str) -> bool {
        self.playing.with(|playing| playing.as_ref().is_some_and(|p| p.episode.id == episode_id))
    }

    pub(crate) fn paused(&self) -> bool {
        self.paused.get()
    }

    pub(crate) fn left_at(&self, episode_id: &str) -> Option<i64> {
        self.listened.with(|entries| {
            entries.iter().find(|e| e.episode_id == episode_id).filter(|e| e.is_continuable()).map(|e| e.position_ms)
        })
    }

    fn remember(&self) {
        let Some(playing) = self.playing.get_untracked() else {
            return;
        };
        let entry = ListenProgress {
            extra: Default::default(),
            episode_id: playing.episode.id,
            position_ms: self.position_ms.get_untracked(),
            duration_ms: self.duration_ms.get_untracked(),
            updated_at: Some(now_iso()),
        };
        let mut first_time = false;
        self.listened.update(|entries| {
            first_time = !entries.iter().any(|other| other.episode_id == entry.episode_id);
            entries.retain(|other| other.episode_id != entry.episode_id);
            entries.insert(0, entry);
            entries.truncate(200);
        });
        if let Some(root) = persist::data_root()
            && let Err(error) = persist::save_listening(&root, &self.listened.get_untracked())
        {
            log::error!("saving listening progress: {error}");
        }
        if first_time {
            self.save();
        }
    }

    fn play(&self, episode: Episode, show_title: SharedString, source: String) {
        batch(|| {
            if !self.playing.with_untracked(|p| p.as_ref().is_some_and(|p| p.episode.id == episode.id)) {
                self.remember();
                super::store().act(crate::state::Action::Shelve(super::Shelf::Continue, &episode.id, true));
                self.position_ms.set(self.left_at(&episode.id).unwrap_or(0));
                self.duration_ms.set(episode.duration_ms.unwrap_or(0));
                let artwork = self.artwork_of(&episode);
                self.playing.set(Some(Playing { episode, show_title, source, artwork }));
            }
            self.paused.set(false);
        });
    }

    fn artwork_of(&self, episode: &Episode) -> String {
        episode.artwork_url.clone().filter(|url| !url.is_empty()).unwrap_or_else(|| {
            self.catalog.with_untracked(|catalog| {
                catalog.feed_of(&episode.id).and_then(|feed| feed.artwork_url.clone()).unwrap_or_default()
            })
        })
    }

    fn set_paused(&self, paused: bool) {
        self.paused.set(paused);
        if paused {
            self.remember();
        }
    }

    fn stop(&self) {
        self.remember();
        batch(|| {
            self.paused.set(true);
            self.playing.set(None);
        });
    }

    pub(crate) fn position_ms(&self) -> i64 {
        self.position_ms.get()
    }

    pub(crate) fn duration_ms(&self) -> i64 {
        self.duration_ms.get()
    }

    fn report(&self, position_ms: i64, duration_ms: i64) {
        batch(|| {
            self.position_ms.set(position_ms);
            if duration_ms > 0 {
                self.duration_ms.set(duration_ms);
            }
        });
        if self.reports.with(|count| {
            *count += 1;
            *count % 10 == 0
        }) {
            self.remember();
        }
    }

    pub(crate) fn rate(&self) -> f32 {
        self.rate.get()
    }

    fn set_rate(&self, rate: f32) {
        self.rate.set(rate);
    }

    fn seek_to(&self, position_ms: i64) {
        let position_ms = position_ms.max(0);
        batch(|| {
            self.position_ms.set(position_ms);
            self.seek.update(|(count, at)| {
                *count += 1;
                *at = position_ms;
            });
        });
    }

    pub(crate) fn seek_request(&self) -> (u32, i64) {
        self.seek.get()
    }
}
