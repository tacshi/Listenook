//! Podcast state: the shows followed, the feeds seen, and the player.

use listenook_core::{
    now_iso,
    podcast::{Catalog, Episode, Feed, Followed, ListenProgress},
};
use nsh_core::prelude::*;

use super::persist;

/// What the player is playing.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Playing {
    pub(crate) episode: Episode,
    pub(crate) show_title: SharedString,
    /// The URL the player loads: the stream, or the downloaded file.
    pub(crate) source: String,
}

/// The podcast part of the store.
#[derive(Clone, Copy)]
pub(crate) struct PodcastState {
    catalog: Signal<Catalog>,
    playing: Signal<Option<Playing>>,
    paused: Signal<bool>,
    position_ms: Signal<i64>,
    duration_ms: Signal<i64>,
    rate: Signal<f32>,
    /// Where the Podcasts page was left: the show open in it, and what
    /// was being searched for. Coming back finds them as they were.
    pub(crate) open_show: Signal<Option<String>>,
    pub(crate) query: Signal<String>,
    /// Whether the dialog that takes a feed's address is up.
    pub(crate) adding: Signal<bool>,
    seek: Signal<(u32, i64)>,
    listened: Signal<Vec<ListenProgress>>,
    reports: Stored<u32>,
}

/// The speeds the players offer.
pub(crate) const RATES: &[f32] = &[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

/// A speed as its label: `1.25×`.
pub(crate) fn rate_label(rate: f32) -> SharedString {
    format!("{rate}×").into()
}

impl PodcastState {
    pub(super) fn new(catalog: Catalog, listened: Vec<ListenProgress>) -> Self {
        Self {
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
        }
    }

    fn save(&self) {
        if let Some(root) = persist::data_root()
            && let Err(error) = persist::save_catalog(&root, &self.catalog.get_untracked())
        {
            log::error!("saving the podcast catalog: {error}");
        }
    }

    /// The shows followed, most recently followed first.
    pub(crate) fn followed(&self) -> Vec<Followed> {
        self.catalog.with(|catalog| catalog.followed.clone())
    }

    /// Whether a feed is followed.
    pub(crate) fn is_followed(&self, feed_url: &str) -> bool {
        self.catalog.with(|catalog| catalog.followed.iter().any(|f| f.feed_url == feed_url))
    }

    /// A feed seen before, as it was last fetched.
    pub(crate) fn feed(&self, feed_url: &str) -> Option<Feed> {
        self.catalog.with(|catalog| catalog.feeds.iter().find(|f| f.feed_url == feed_url).cloned())
    }

    /// Keeps a fetched feed. Feeds not followed are kept up to ten.
    pub(crate) fn cache_feed(&self, feed: Feed) {
        self.catalog.update(|catalog| {
            catalog.feeds.retain(|f| f.feed_url != feed.feed_url);
            catalog.feeds.insert(0, feed);
            let followed: Vec<String> = catalog.followed.iter().map(|f| f.feed_url.clone()).collect();
            let mut unfollowed = 0;
            catalog.feeds.retain(|f| {
                followed.contains(&f.feed_url) || {
                    unfollowed += 1;
                    unfollowed <= 10
                }
            });
        });
        self.save();
    }

    /// Follows a feed, or stops following it.
    pub(crate) fn set_followed(&self, feed: &Feed, followed: bool) {
        self.catalog.update(|catalog| {
            catalog.followed.retain(|f| f.feed_url != feed.feed_url);
            if followed {
                catalog.followed.insert(
                    0,
                    Followed {
                        extra: Default::default(),
                        feed_url: feed.feed_url.clone(),
                        title: feed.title.clone(),
                        followed_at: now_iso(),
                        author: feed.author.clone(),
                        artwork_url: feed.artwork_url.clone(),
                        last_seen_episode_ids: feed.episodes.iter().map(|e| e.id.clone()).collect(),
                        unseen_episode_count: 0,
                    },
                );
            }
        });
        self.save();
    }

    // --- The player ----------------------------------------------------------

    /// What is playing, if anything.
    pub(crate) fn playing(&self) -> Option<Playing> {
        self.playing.get()
    }

    /// Whether `episode_id` is the episode in the player.
    pub(crate) fn is_current(&self, episode_id: &str) -> bool {
        self.playing.with(|playing| playing.as_ref().is_some_and(|p| p.episode.id == episode_id))
    }

    /// Whether the player is paused (also when it has nothing).
    pub(crate) fn paused(&self) -> bool {
        self.paused.get()
    }

    /// Where an episode was left, when it was started and not finished.
    pub(crate) fn left_at(&self, episode_id: &str) -> Option<i64> {
        self.listened.with(|entries| {
            entries.iter().find(|e| e.episode_id == episode_id).filter(|e| e.is_continuable()).map(|e| e.position_ms)
        })
    }

    /// Records where the episode in the player is, for the next launch.
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
        self.listened.update(|entries| {
            entries.retain(|other| other.episode_id != entry.episode_id);
            entries.insert(0, entry);
            entries.truncate(200);
        });
        if let Some(root) = persist::data_root()
            && let Err(error) = persist::save_listening(&root, &self.listened.get_untracked())
        {
            log::error!("saving listening progress: {error}");
        }
    }

    /// Starts an episode where it was left, or resumes it when it is the
    /// one in the player.
    pub(crate) fn play(&self, episode: Episode, show_title: SharedString, source: String) {
        batch(|| {
            if !self.playing.with_untracked(|p| p.as_ref().is_some_and(|p| p.episode.id == episode.id)) {
                self.remember();
                self.position_ms.set(self.left_at(&episode.id).unwrap_or(0));
                self.duration_ms.set(episode.duration_ms.unwrap_or(0));
                self.playing.set(Some(Playing { episode, show_title, source }));
            }
            self.paused.set(false);
        });
    }

    /// Pauses or resumes.
    pub(crate) fn set_paused(&self, paused: bool) {
        self.paused.set(paused);
        if paused {
            self.remember();
        }
    }

    /// Stops and empties the player.
    pub(crate) fn stop(&self) {
        self.remember();
        batch(|| {
            self.paused.set(true);
            self.playing.set(None);
        });
    }

    /// The position in milliseconds.
    pub(crate) fn position_ms(&self) -> i64 {
        self.position_ms.get()
    }

    /// The length in milliseconds, 0 while unknown.
    pub(crate) fn duration_ms(&self) -> i64 {
        self.duration_ms.get()
    }

    /// The player reports where it is.
    pub(crate) fn report(&self, position_ms: i64, duration_ms: i64) {
        batch(|| {
            self.position_ms.set(position_ms);
            if duration_ms > 0 {
                self.duration_ms.set(duration_ms);
            }
        });
        // Every few seconds of playback, so a quit loses little.
        if self.reports.with(|count| {
            *count += 1;
            *count % 10 == 0
        }) {
            self.remember();
        }
    }

    /// The playback speed.
    pub(crate) fn rate(&self) -> f32 {
        self.rate.get()
    }

    /// Sets the playback speed.
    pub(crate) fn set_rate(&self, rate: f32) {
        self.rate.set(rate);
    }

    /// Asks the player to move to a position.
    pub(crate) fn seek_to(&self, position_ms: i64) {
        let position_ms = position_ms.max(0);
        batch(|| {
            self.position_ms.set(position_ms);
            self.seek.update(|(count, at)| {
                *count += 1;
                *at = position_ms;
            });
        });
    }

    /// The latest seek request: a counter and the position.
    pub(crate) fn seek_request(&self) -> (u32, i64) {
        self.seek.get()
    }
}
