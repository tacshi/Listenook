use std::{path::PathBuf, time::Duration};

use listenook_core::{
    AdScan, CleanupState, Document, Job, JobProgress, JobStatus, MediaMetadata, TranscriptAcquisitionMode,
    TranscriptionProvider, TranslationState, TranslationStatus, parser, subtitles,
};
use nsh_core::prelude::*;

use super::{
    llm, local,
    remote::{Failure, Progress, Provider, SONIOX_MODEL, Sending},
};
use crate::{
    state::{Store, error_text, secrets, store, tr},
    ui::{Tone, toast},
};

pub(crate) fn start_ready() {
    let ready: Vec<String> =
        store().jobs().iter().filter(|job| job.status.is_transcribable()).map(|job| job.id.clone()).collect();
    for id in ready {
        start(&id);
    }
}

pub(crate) fn start(id: &str) {
    let store = store();
    let id = id.to_owned();
    store.update_job(&id, |job| {
        if job.remote_file_id.is_none() {
            store.apply_options(job);
        }
        job.status = JobStatus::Uploading;
        job.error_code = None;
        job.error_message = None;
        job.progress = JobProgress { stage: "uploading".into(), fraction: None, detail: None };
    });
    store.run_for(&id.clone(), async move {
        if let Err(failure) = run(store, &id).await {
            log::warn!("job {id}: {} ({})", failure.code, failure.message);
            let missing = failure.code == "missing_source";
            store.update_job(&id, |job| {
                job.status = if missing { JobStatus::MissingSource } else { JobStatus::Failed };
                job.progress.stage = "failed".into();
                job.error_code = Some(failure.code.clone());
                job.error_message = Some(failure.message.clone());
            });
            if store.job_now(&id).is_some_and(|job| job.has_transcript()) {
                // Transcribing it again failed: the transcript it had is still good, so it stays.
                // Set apart from the failure above, so a notification still says it failed.
                keep_transcript(store, &id);
                toast(Tone::Error, format!("{} {}", error_text(&failure.code), tr("The earlier transcript is kept.")));
            }
            clean_up(store, &id).await;
        }
    });
}

/// Transcribes a recording that already has a transcript once more, with the current settings.
/// The transcript it has stays readable until the new one replaces it, and stays for good if
/// transcribing fails or is cancelled.
pub(crate) fn again(id: &str) {
    store().update_job(id, |job| {
        job.remote_file_id = None;
        job.remote_transcription_id = None;
        job.cleanup_state = CleanupState::None;
    });
    start(id);
}

fn keep_transcript(store: Store, id: &str) {
    store.update_job(id, |job| {
        job.status = JobStatus::Completed;
        job.progress = JobProgress { stage: "complete".into(), fraction: Some(1.0), detail: None };
        job.error_code = None;
        job.error_message = None;
    });
}

/// Finding no speech when transcribing again leaves the transcript it had, rather than none.
fn keep_if_silent(store: Store, id: &str, empty: bool) -> Result<(), Failure> {
    match empty && store.job_now(id).is_some_and(|job| job.has_transcript()) {
        true => Err(Failure::new("no_speech", "No speech was found.")),
        false => Ok(()),
    }
}

/// Puts a new transcript in place, dropping what was made from the one it replaces.
fn put_transcript(store: Store, id: &str, document: Document) {
    llm::cancel_translation(id);
    llm::cancel_brief(id);
    llm::cancel_ad_scan(id);
    store.update_job(id, |job| {
        job.document = Some(document);
        job.ai_brief = None;
        job.ai_generation_state = Default::default();
        job.ad_scan = AdScan::default();
        job.translation_state = TranslationState::default();
        job.extra.remove("forced_alignment");
        job.transcript_acquisition_mode = TranscriptAcquisitionMode::parse(job.transcription_provider.as_str());
    });
}

pub(crate) fn cancel(id: &str) {
    let store = store();
    store.cancel_work(id);
    if let Some(root) = store.data_root() {
        let _ = std::fs::remove_file(root.join("temporary").join(format!("{id}-local.wav")));
    }
    for kind in ["wav", "m4a"] {
        let _ = std::fs::remove_file(std::env::temp_dir().join(format!("listenook-{id}.{kind}")));
    }
    let job = store.job_now(id);
    if job.as_ref().is_some_and(|job| job.status == JobStatus::Aligning) {
        store.update_job(id, |job| {
            job.status = JobStatus::Completed;
            job.progress = JobProgress { stage: "complete".into(), fraction: Some(1.0), detail: None };
            job.extra.insert(
                "forced_alignment".into(),
                serde_json::json!({"status": "failed", "warning_code": "alignment_cancelled"}),
            );
        });
        return;
    }
    if job.is_some_and(|job| job.has_transcript()) {
        keep_transcript(store, id);
    } else {
        store.update_job(id, |job| {
            job.status = JobStatus::Cancelled;
            job.progress.stage = "cancelled".into();
            job.error_code = Some("cancelled".into());
        });
    }
    let id = id.to_owned();
    store.run(async move { clean_up(store, &id).await });
}

pub(crate) fn retry(id: &str) {
    let store = store();
    if store
        .job_now(id)
        .is_some_and(|job| job.podcast_provenance.is_some() && !std::path::Path::new(&job.source_path).exists())
    {
        return super::podcasts::download(id);
    }
    store.update_job(id, |job| {
        let missing = !std::path::Path::new(&job.source_path).exists();
        job.status = if missing { JobStatus::MissingSource } else { JobStatus::Ready };
        job.progress = JobProgress { stage: "ready".into(), fraction: None, detail: None };
        job.error_code = missing.then(|| "missing_source".into());
        job.error_message = None;
        job.remote_file_id = None;
        job.remote_transcription_id = None;
        job.cleanup_state = CleanupState::None;
    });
}

fn provider_of(job: &Job) -> Result<Provider, Failure> {
    match job.transcription_provider {
        TranscriptionProvider::Soniox => Ok(Provider::Soniox),
        TranscriptionProvider::MossPro => Ok(Provider::Moss),
        _ => Err(Failure::new("provider_unavailable", "Local transcription is not available.")),
    }
}

async fn upload_source(job: &Job) -> PathBuf {
    let source = PathBuf::from(&job.source_path);
    let extension = subtitles::extension(&job.source_path);
    if !matches!(extension.as_str(), "mp4" | "mkv" | "avi") {
        return source;
    }
    if !cfg!(target_os = "macos") || extension != "mp4" {
        let output = std::env::temp_dir().join(format!("listenook-{}.wav", job.id));
        let (input, target) = (source.clone(), output.clone());
        let written = blocking(move || {
            let samples = super::audio::decode(&input, 16_000)?;
            let smaller = (samples.len() * 2) as u64 + 44 < std::fs::metadata(&input).ok()?.len();
            (smaller && std::fs::write(&target, listenook_core::audio::wav(&samples, 16_000)).is_ok()).then_some(())
        })
        .await
        .ok()
        .flatten()
        .is_some();
        return if written { output } else { source };
    }
    let output = std::env::temp_dir().join(format!("listenook-{}.m4a", job.id));
    let (input, target) = (source.clone(), output.clone());
    let converted = blocking(move || {
        std::process::Command::new("/usr/bin/afconvert")
            .args(["-f", "m4af", "-d", "aac", "-b", "64000"])
            .arg(&input)
            .arg(&target)
            .output()
            .is_ok_and(|out| out.status.success())
    })
    .await
    .unwrap_or(false);
    if converted { output } else { source }
}

async fn run(store: Store, id: &str) -> Result<(), Failure> {
    let job = store.job_now(id).ok_or_else(|| Failure::new("cancelled", "The job was removed."))?;
    if local::is_local(job.transcription_provider) {
        return run_local(store, id, &job).await;
    }
    let provider = provider_of(&job)?;
    let key = secrets::read(provider.secret()).ok_or_else(|| {
        Failure::new(
            format!("{}missing_credentials", if provider == Provider::Moss { "moss_" } else { "" }),
            "No API key.",
        )
    })?;
    let source = PathBuf::from(&job.source_path);
    let size = std::fs::metadata(&source).map_err(|e| Failure::new("missing_source", e.to_string()))?.len();
    if !subtitles::is_media(&job.source_path) {
        return Err(Failure::new("unsupported_format", "Unsupported file type."));
    }

    let file_id = match &job.remote_file_id {
        Some(id) => id.clone(),
        None => {
            store.update_job(id, |job| job.status = JobStatus::Converting);
            store.set_progress(id, "converting", None);
            let upload = upload_source(&job).await;
            store.update_job(id, |job| job.status = JobStatus::Uploading);
            store.set_progress(id, "uploading", None);
            let sending = Sending::default();
            let (watched, seen) = (id.to_owned(), sending.clone());
            let _watcher = super::Ends::with(spawn(async move {
                loop {
                    timer(Duration::from_millis(400)).await;
                    if let Some(fraction) = seen.fraction() {
                        store.set_progress(&watched, "uploading", Some(fraction));
                    }
                }
            }));
            let result = provider.upload(upload.clone(), &key, sending).await;
            if upload != source {
                let _ = std::fs::remove_file(&upload);
            }
            let file_id = result?;
            store.update_job(id, |job| {
                job.remote_file_id = Some(file_id.clone());
                job.cleanup_state = CleanupState::Pending;
            });
            file_id
        }
    };

    let transcription_id = match &job.remote_transcription_id {
        Some(id) => id.clone(),
        None => {
            let transcription_id = provider.create(&file_id, &job, &key).await?;
            store.update_job(id, |job| {
                job.remote_transcription_id = Some(transcription_id.clone());
                job.status = JobStatus::QueuedRemote;
                job.progress.stage = "queued_remote".into();
            });
            transcription_id
        }
    };

    let mut failures = 0_u32;
    let done = loop {
        match provider.progress(&transcription_id, &key).await {
            Ok(Progress::Done(body)) => break body,
            Ok(Progress::Failed(failure)) => return Err(failure),
            Ok(Progress::Queued(wait)) => {
                failures = 0;
                if store.job_now(id).is_some_and(|job| job.status != JobStatus::QueuedRemote) {
                    store.update_job(id, |job| job.status = JobStatus::QueuedRemote);
                }
                timer(wait).await;
            }
            Ok(Progress::Running(wait)) => {
                failures = 0;
                if store.job_now(id).is_some_and(|job| job.status != JobStatus::Processing) {
                    store.update_job(id, |job| {
                        job.status = JobStatus::Processing;
                        job.progress.stage = "processing".into();
                    });
                }
                timer(wait).await;
            }
            Err(failure) if failure.retryable && failures < 7 => {
                failures += 1;
                timer(Duration::from_secs(2_u64.pow(failures).min(30))).await;
            }
            Err(failure) => return Err(failure),
        }
    };

    store.update_job(id, |job| {
        job.status = JobStatus::Fetching;
        job.progress.stage = "fetching".into();
    });
    let payload = provider.transcript(&transcription_id, done, &key).await?;
    let soniox_target = (job.options.soniox_translation.enabled && provider == Provider::Soniox)
        .then_some(job.options.soniox_translation.target_language.as_str());
    let document = match provider {
        Provider::Soniox => parser::parse_soniox(&payload, soniox_target),
        Provider::Moss => parser::parse_moss(&payload),
    };
    let empty = document.segments.is_empty();
    let duration_ms = document.segments.last().map_or(0, |segment| segment.end_ms);
    let has_video = matches!(subtitles::extension(&job.source_path).as_str(), "mp4" | "mkv" | "avi");
    let translated = document.segments.iter().filter(|s| s.has_translation()).count() as u32;
    let total = document.segments.len() as u32;
    keep_if_silent(store, id, empty)?;
    put_transcript(store, id, document);
    store.update_job(id, |job| {
        if let Some(target) = soniox_target {
            job.translation_state = TranslationState {
                status: if translated == total { TranslationStatus::Completed } else { TranslationStatus::Partial },
                target_language: target.to_owned(),
                model: SONIOX_MODEL.into(),
                origin: Some("soniox".into()),
                completed_segments: translated,
                total_segments: total,
                ..TranslationState::default()
            };
        }
        if job.metadata.is_none() {
            job.metadata = Some(MediaMetadata {
                size_bytes: size as i64,
                duration_ms,
                has_audio: true,
                has_video,
                format_name: subtitles::extension(&job.source_path),
                ..MediaMetadata::default()
            });
        }
        job.status = if empty { JobStatus::Empty } else { JobStatus::Completed };
        job.progress = JobProgress { stage: "complete".into(), fraction: Some(1.0), detail: None };
    });
    clean_up(store, id).await;

    let translate = &job.translation_options;
    if !empty && translate.enabled && !translate.target_language.is_empty() && soniox_target.is_none() {
        llm::start_translation(id, &translate.target_language, None);
    }
    if !empty {
        add_word_timing(store, id, None).await;
    }
    Ok(())
}

async fn run_local(store: Store, id: &str, job: &Job) -> Result<(), Failure> {
    let size = std::fs::metadata(&job.source_path).map_err(|e| Failure::new("missing_source", e.to_string()))?.len();
    if !subtitles::is_media(&job.source_path) {
        return Err(Failure::new("unsupported_format", "Unsupported file type."));
    }
    let _turn = local::Lane::turn().await;
    store.update_job(id, |job| job.status = JobStatus::Converting);
    store.set_progress(id, "converting", None);
    let samples = local::prepare_audio(job).await?;
    let duration_ms = local::duration_ms(&samples);
    store.update_job(id, |job| job.status = JobStatus::Processing);
    let document = local::transcribe(store, job, samples.clone()).await?;
    let empty = document.segments.is_empty();
    let timed = !document.tokens.is_empty();
    let has_video = matches!(subtitles::extension(&job.source_path).as_str(), "mp4" | "mkv" | "avi");
    keep_if_silent(store, id, empty)?;
    put_transcript(store, id, document);
    store.update_job(id, |job| {
        if job.metadata.is_none() {
            job.metadata = Some(MediaMetadata {
                size_bytes: size as i64,
                duration_ms,
                has_audio: true,
                has_video,
                format_name: subtitles::extension(&job.source_path),
                ..MediaMetadata::default()
            });
        }
        job.status = if empty { JobStatus::Empty } else { JobStatus::Completed };
        job.progress = JobProgress { stage: "complete".into(), fraction: Some(1.0), detail: None };
    });
    let translate = &job.translation_options;
    if !empty && translate.enabled && !translate.target_language.is_empty() {
        llm::start_translation(id, &translate.target_language, None);
    }
    if !empty && !timed {
        add_word_timing(store, id, Some(samples)).await;
    }
    Ok(())
}

async fn add_word_timing(store: Store, id: &str, samples: Option<std::sync::Arc<Vec<i16>>>) {
    let Some(job) = store.job_now(id) else {
        return;
    };
    if !store.setting(|s| s.auto_align_transcripts) || !local::can_align(&job) {
        return;
    }
    time_words(store, id, &job, samples).await;
}

async fn time_words(store: Store, id: &str, job: &Job, samples: Option<std::sync::Arc<Vec<i16>>>) {
    store.update_job(id, |job| {
        job.status = JobStatus::Aligning;
        job.progress = JobProgress { stage: "aligning".into(), fraction: None, detail: None };
        job.extra.insert("forced_alignment".into(), serde_json::json!({"status": "queued"}));
    });
    let samples = match samples {
        Some(samples) => Some(samples),
        None => local::prepare_audio(job).await.ok(),
    };
    let record = match samples {
        Some(samples) => local::align(store, id, samples).await,
        None => serde_json::json!({"status": "failed", "warning_code": "alignment_source_missing"}),
    };
    store.update_job(id, |job| {
        job.extra.insert("forced_alignment".into(), record);
        job.status = JobStatus::Completed;
        job.progress = JobProgress { stage: "complete".into(), fraction: Some(1.0), detail: None };
    });
}

pub(crate) fn align(id: &str) {
    let store = store();
    let id = id.to_owned();
    store.run_for(&id.clone(), async move {
        if let Some(job) = store.job_now(&id).filter(|job| local::can_align(job)) {
            time_words(store, &id, &job, None).await;
        }
    });
}

async fn clean_up(store: Store, id: &str) {
    let Some(job) = store.job_now(id) else {
        return;
    };
    if job.cleanup_state != CleanupState::Pending {
        return;
    }
    let (Ok(provider), true) = (provider_of(&job), job.remote_file_id.is_some()) else {
        return;
    };
    let Some(key) = secrets::read(provider.secret()) else {
        return;
    };
    if provider.cleanup(job.remote_transcription_id.as_deref(), job.remote_file_id.as_deref(), &key).await {
        store.update_job(id, |job| job.cleanup_state = CleanupState::Complete);
    } else {
        // Left pending: the media is still with the provider, and the next start tries again.
        log::warn!("job {id}: the provider's copy could not be deleted yet");
    }
}

/// Deletes what finished jobs left with a provider when deleting it failed before, such as
/// when the network was down as a job ended.
pub(crate) fn clean_up_left(store: Store) {
    let left: Vec<String> = store
        .jobs()
        .iter()
        .filter(|job| job.cleanup_state == CleanupState::Pending && job.status.is_terminal())
        .map(|job| job.id.clone())
        .collect();
    for id in left {
        store.run(async move { clean_up(store, &id).await });
    }
}
