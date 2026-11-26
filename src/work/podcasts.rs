use listenook_core::{
    Job, JobSourceOrigin, JobStatus, MediaMetadata, PodcastProvenance, TranscriptAcquisitionMode,
    podcast::{self, Episode, Feed, ShowSummary},
};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};

use nsh_core::prelude::*;

use crate::services::persist;
use crate::ui::tr;
use crate::{
    state::store,
    ui::{Tone, toast},
};

const USER_AGENT: &str = "Listenook/1.2 (podcast)";

async fn get(url: &str, failure: &'static str) -> Result<Vec<u8>, &'static str> {
    let response = fetch(HttpRequest::get(url).header("User-Agent", USER_AGENT)).await.map_err(|_| failure)?;
    if response.ok() { Ok(response.body) } else { Err(failure) }
}

pub(crate) async fn search(term: &str) -> Result<Vec<ShowSummary>, &'static str> {
    let body = get(&podcast::search_url(term), "podcast_search_failed").await?;
    Ok(podcast::parse_itunes(&String::from_utf8_lossy(&body)))
}

pub(crate) async fn featured() -> Result<Vec<ShowSummary>, &'static str> {
    let body = get(&podcast::lookup_url(podcast::FEATURED_IDS), "podcast_lookup_failed").await?;
    Ok(podcast::parse_itunes(&String::from_utf8_lossy(&body)))
}

pub(crate) async fn top_shows(genre: Option<u32>, limit: u32) -> Result<Vec<ShowSummary>, &'static str> {
    let chart = get(&podcast::chart_url(genre, limit), "podcast_lookup_failed").await?;
    let ids = podcast::parse_chart_ids(&String::from_utf8_lossy(&chart));
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
    let body = get(&podcast::lookup_url(&ids), "podcast_lookup_failed").await?;
    Ok(podcast::parse_itunes(&String::from_utf8_lossy(&body)))
}

pub(crate) async fn load_feed(url: &str) -> Result<Feed, &'static str> {
    let canonical = podcast::canonical_url(url);
    if canonical.is_empty() {
        return Err("podcast_invalid_feed");
    }
    let body = get(&canonical, "podcast_feed_failed").await?;
    let feed = podcast::parse_feed(&String::from_utf8_lossy(&body), &canonical)?;
    crate::state::podcast::PodcastState::get().act(crate::state::podcast::PodcastAction::CacheFeed(feed.clone()));
    Ok(feed)
}

/// Refreshes the followed show at `url`. One saved at an address that is no
/// feed (early versions saved a show's website) moves to its feed, found by
/// its name and author, once a run.
pub(crate) async fn refresh(url: String) {
    if load_feed(&url).await != Err("podcast_invalid_feed") {
        return;
    }
    thread_local! {
        static TRIED: std::cell::RefCell<std::collections::HashSet<String>> = Default::default();
    }
    if !TRIED.with(|tried| tried.borrow_mut().insert(url.clone())) {
        return;
    }
    let podcasts = crate::state::podcast::PodcastState::get();
    let Some(followed) = podcasts.followed().into_iter().find(|followed| followed.feed_url == url) else {
        return;
    };
    let Ok(found) = search(&followed.title).await else {
        return;
    };
    let Some(show) = podcast::same_show_in(&followed, &found) else {
        log::warn!("no feed found for the followed show {:?} at {url}", followed.title);
        return;
    };
    let Ok(feed) = load_feed(&show.feed_url).await else {
        return;
    };
    podcasts.act(crate::state::podcast::PodcastAction::SetFollowed(&feed, true));
    if podcasts.is_followed(&url) {
        podcasts
            .act(crate::state::podcast::PodcastAction::SetFollowed(&Feed { feed_url: url, ..Feed::default() }, false));
    }
}

pub(crate) fn job_of(episode_id: &str) -> Option<String> {
    store().jobs().iter().find(|job| job.is_episode(episode_id)).map(|job| job.id.clone())
}

pub(crate) fn show_of(job: &Job) -> Option<String> {
    job.podcast().map(|p| p.show_title.trim().to_owned()).filter(|show| !show.is_empty())
}

pub(crate) fn artwork_of(job: &Job) -> String {
    let Some(provenance) = job.podcast() else {
        return String::new();
    };
    provenance
        .artwork_url
        .clone()
        .filter(|url| !url.is_empty())
        .or_else(|| {
            crate::state::podcast::PodcastState::get().feed(&provenance.feed_url).and_then(|feed| feed.artwork_url)
        })
        .unwrap_or_default()
}

pub(crate) fn deep_listen(episode: &Episode, feed: &Feed) {
    let store = store();
    if let Some(existing) = job_of(&episode.id) {
        if store.job_now(&existing).is_some_and(|job| job.has_transcript()) {
            store.act(crate::state::Action::OpenTranscript(&existing));
        } else {
            store.act(crate::state::Action::Show(crate::state::Filter::All));
        }
        return;
    }
    let mut job = store.new_job("", JobSourceOrigin::Podcast);
    let path = match store.data_root() {
        Some(root) => persist::podcast_path(&root, &job.id, &podcast::download_file_name(episode)),
        None => std::env::temp_dir().join(format!("listenook-{}.{}", job.id, episode.media_extension)),
    };
    job.apply(listenook_core::Change::DownloadEpisode(
        path.to_string_lossy().into_owned(),
        PodcastProvenance {
            feed_url: feed.feed_url.clone(),
            episode_id: episode.id.clone(),
            enclosure_url: episode.enclosure_url.clone(),
            show_title: feed.title.clone(),
            episode_title: episode.title.clone(),
            author: feed.author.clone(),
            artwork_url: episode.artwork_url.clone().filter(|url| !url.is_empty()).or_else(|| feed.artwork_url.clone()),
            published_at: episode.published_at.clone(),
            language: feed.language.clone(),
            transcripts: episode.transcripts.clone(),
            ..PodcastProvenance::default()
        },
    ));
    let id = job.id.clone();
    store.act(crate::state::Action::AddJob(job));
    toast(Tone::Success, tr("Added to your Library."));
    download(&id);
}

pub(crate) fn download(id: &str) {
    let store = store();
    let id = id.to_owned();
    let Some(job) = store.job_now(&id) else {
        return;
    };
    let Some(provenance) = job.podcast() else {
        return;
    };
    store.update_job(&id, |job| job.apply(listenook_core::Change::Start(JobStatus::Downloading, "downloading")));
    store.run_for(&id.clone(), async move {
        let path = std::path::PathBuf::from(&job.source_path);
        let (received, total) = (Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0)));
        let stop = Arc::new(AtomicBool::new(false));
        let _halt = Halt(stop.clone());
        let transfer = blocking({
            let (url, received, total) = (provenance.enclosure_url.clone(), received.clone(), total.clone());
            let stop = stop.clone();
            move || fetch_to_file(&url, &path, &received, &total, &stop)
        });
        let watched = id.clone();
        let (seen, whole) = (received.clone(), total.clone());
        let _watcher = crate::services::Ends::with(spawn(async move {
            loop {
                timer(std::time::Duration::from_millis(400)).await;
                let (got, all) = (seen.load(Ordering::Relaxed), whole.load(Ordering::Relaxed));
                if all > 0 {
                    store.act(crate::state::Action::SetProgress(
                        &watched,
                        "downloading",
                        Some(got as f64 / all as f64),
                    ));
                }
            }
        }));
        let saved = transfer.await.ok().and_then(Result::ok).ok_or("podcast_download_failed");
        let size = match saved {
            Ok(size) => size,
            Err(code) => {
                store.update_job(&id, |job| job.apply(listenook_core::Change::Fail(code, None)));
                return;
            }
        };
        let mut document = None;
        for reference in &provenance.transcripts {
            if let Ok(body) = get(&reference.url, "podcast_transcript_failed").await
                && let Ok(found) = podcast::publisher_transcript(&String::from_utf8_lossy(&body), reference)
                && !found.segments.is_empty()
            {
                document = Some(found);
                break;
            }
        }
        store.update_job(&id, |job| {
            job.apply(listenook_core::Change::NoteMedia(MediaMetadata {
                size_bytes: size,
                duration_ms: document.as_ref().and_then(|d| d.segments.last()).map_or(0, |s| s.end_ms),
                has_audio: true,
                format_name: listenook_core::media::subtitles::extension(&job.source_path),
                ..MediaMetadata::default()
            }));
            match document {
                Some(document) => {
                    job.apply(listenook_core::Change::ReplaceTranscript(
                        document,
                        Some(TranscriptAcquisitionMode::PublisherCaptions),
                    ));
                    job.apply(listenook_core::Change::Finish(false));
                }
                None => job.apply(listenook_core::Change::AwaitsTranscription),
            }
        });
    });
}

struct Halt(Arc<AtomicBool>);

impl Drop for Halt {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

fn fetch_to_file(
    url: &str,
    path: &std::path::Path,
    received: &AtomicU64,
    total: &AtomicU64,
    stop: &AtomicBool,
) -> std::io::Result<i64> {
    use std::io::{Read, Write};
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let part = path.with_extension(format!("{}.part", path.extension().and_then(|e| e.to_str()).unwrap_or("bin")));
    let mut have = std::fs::metadata(&part).map_or(0, |metadata| metadata.len());
    let ask = |from: u64| {
        let request = crate::services::http().get(url).set("User-Agent", USER_AGENT);
        let request = if from > 0 { request.set("Range", &format!("bytes={from}-")) } else { request };
        request.call().map_err(std::io::Error::other)
    };
    let response = match ask(have) {
        Err(_) if have > 0 => {
            have = 0;
            ask(0)
        }
        other => other,
    }?;
    let resumed = have > 0 && response.status() == 206;
    let length: u64 = response.header("Content-Length").and_then(|value| value.parse().ok()).unwrap_or(0);
    let start = if resumed { have } else { 0 };
    total.store(start + length, Ordering::Relaxed);
    received.store(start, Ordering::Relaxed);
    let mut file =
        std::fs::OpenOptions::new().create(true).write(true).append(resumed).truncate(!resumed).open(&part)?;
    let mut reader = response.into_reader();
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        if stop.load(Ordering::Relaxed) {
            return Err(std::io::Error::other("stopped"));
        }
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        file.write_all(&buffer[..read])?;
        received.fetch_add(read as u64, Ordering::Relaxed);
    }
    file.flush()?;
    drop(file);
    std::fs::rename(&part, path)?;
    Ok(std::fs::metadata(path)?.len() as i64)
}
