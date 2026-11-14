use listenook_core::{
    JobProgress, JobSourceOrigin, JobStatus, MediaMetadata, PodcastProvenance, TranscriptAcquisitionMode,
    podcast::{self, Episode, Feed, ShowSummary},
};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};

use nsh_core::prelude::*;

use crate::{
    state::{persist, store, tr},
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
    store().podcast.cache_feed(feed.clone());
    Ok(feed)
}

pub(crate) fn job_of(episode_id: &str) -> Option<String> {
    store()
        .jobs()
        .iter()
        .find(|job| job.podcast_provenance.as_ref().is_some_and(|p| p.episode_id == episode_id))
        .map(|job| job.id.clone())
}

pub(crate) fn deep_listen(episode: &Episode, feed: &Feed) {
    let store = store();
    if let Some(existing) = job_of(&episode.id) {
        if store.job_now(&existing).is_some_and(|job| job.has_transcript()) {
            store.open_transcript(&existing);
        } else {
            toast(Tone::Info, tr("This episode is already in your Library."));
        }
        return;
    }
    let mut job = store.new_job("", JobSourceOrigin::Podcast);
    let path = match store.data_root() {
        Some(root) => persist::podcast_path(&root, &job.id, &podcast::download_file_name(episode)),
        None => std::env::temp_dir().join(format!("listenook-{}.{}", job.id, episode.media_extension)),
    };
    job.source_path = path.to_string_lossy().into_owned();
    job.status = JobStatus::Downloading;
    job.progress = JobProgress { stage: "downloading".into(), fraction: None, detail: None };
    job.display_title = Some(episode.title.clone());
    if let Some(language) = feed.language.as_deref().and_then(|l| l.split(['-', '_']).next()) {
        job.options.language_hints = vec![language.to_lowercase()];
    }
    if !episode.transcripts.is_empty() {
        job.transcript_acquisition_mode = TranscriptAcquisitionMode::PublisherCaptions;
    }
    job.podcast_provenance = Some(PodcastProvenance {
        feed_url: feed.feed_url.clone(),
        episode_id: episode.id.clone(),
        enclosure_url: episode.enclosure_url.clone(),
        show_title: feed.title.clone(),
        episode_title: episode.title.clone(),
        author: feed.author.clone(),
        artwork_url: episode.artwork_url.clone(),
        published_at: episode.published_at.clone(),
        language: feed.language.clone(),
        transcripts: episode.transcripts.clone(),
        ..PodcastProvenance::default()
    });
    let id = job.id.clone();
    store.add_job(job);
    toast(Tone::Success, tr("Added to your Library."));
    download(&id);
}

pub(crate) fn download(id: &str) {
    let store = store();
    let id = id.to_owned();
    let Some(job) = store.job_now(&id) else {
        return;
    };
    let Some(provenance) = job.podcast_provenance.clone() else {
        return;
    };
    store.update_job(&id, |job| {
        job.status = JobStatus::Downloading;
        job.error_code = None;
        job.progress = JobProgress { stage: "downloading".into(), fraction: None, detail: None };
    });
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
        let _watcher = super::Ends::with(spawn(async move {
            loop {
                timer(std::time::Duration::from_millis(400)).await;
                let (got, all) = (seen.load(Ordering::Relaxed), whole.load(Ordering::Relaxed));
                if all > 0 {
                    store.set_progress(&watched, "downloading", Some(got as f64 / all as f64));
                }
            }
        }));
        let saved = transfer.await.ok().and_then(Result::ok).ok_or("podcast_download_failed");
        let size = match saved {
            Ok(size) => size,
            Err(code) => {
                store.update_job(&id, |job| {
                    job.status = JobStatus::Failed;
                    job.error_code = Some(code.into());
                });
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
            job.metadata = Some(MediaMetadata {
                size_bytes: size,
                duration_ms: document.as_ref().and_then(|d| d.segments.last()).map_or(0, |s| s.end_ms),
                has_audio: true,
                format_name: listenook_core::subtitles::extension(&job.source_path),
                ..MediaMetadata::default()
            });
            match document {
                Some(document) => {
                    job.document = Some(document);
                    job.status = JobStatus::Completed;
                    job.progress = JobProgress { stage: "complete".into(), fraction: Some(1.0), detail: None };
                }
                None => {
                    job.transcript_acquisition_mode =
                        TranscriptAcquisitionMode::parse(job.transcription_provider.as_str());
                    job.status = JobStatus::Ready;
                    job.progress = JobProgress { stage: "ready".into(), fraction: None, detail: None };
                }
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
        let request = super::http().get(url).set("User-Agent", USER_AGENT);
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
