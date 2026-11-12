//! A job from a file to a transcript: upload, transcribe, fetch, parse,
//! clean up, and translate when the job asks for it.

use std::{path::PathBuf, time::Duration};

use listenook_core::{
    CleanupState, Job, JobProgress, JobStatus, MediaMetadata, TranscriptionProvider, TranslationState,
    TranslationStatus, parser, subtitles,
};
use nsh_core::prelude::*;

use super::{
    llm, local,
    remote::{Failure, Progress, Provider, SONIOX_MODEL},
};
use crate::state::{Store, secrets, store};

/// Starts every recording that waits to be transcribed.
pub(crate) fn start_ready() {
    let ready: Vec<String> =
        store().jobs().iter().filter(|job| job.status.is_transcribable()).map(|job| job.id.clone()).collect();
    for id in ready {
        start(&id);
    }
}

/// Starts transcribing a job, whatever page the user goes to.
pub(crate) fn start(id: &str) {
    let store = store();
    let id = id.to_owned();
    store.update_job(&id, |job| {
        // Nothing was sent yet: it goes as the options are now.
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
            clean_up(store, &id).await;
        }
    });
}

/// Stops a job's work; what was uploaded is deleted from the provider.
pub(crate) fn cancel(id: &str) {
    let store = store();
    store.cancel_work(id);
    if let Some(root) = store.data_root() {
        let _ = std::fs::remove_file(root.join("temporary").join(format!("{id}-local.wav")));
    }
    for kind in ["wav", "m4a"] {
        let _ = std::fs::remove_file(std::env::temp_dir().join(format!("listenook-{id}.{kind}")));
    }
    // Stopping word timing leaves the transcript it was for.
    if store.job_now(id).is_some_and(|job| job.status == JobStatus::Aligning) {
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
    store.update_job(id, |job| {
        job.status = JobStatus::Cancelled;
        job.progress.stage = "cancelled".into();
        job.error_code = Some("cancelled".into());
    });
    let id = id.to_owned();
    store.run(async move { clean_up(store, &id).await });
}

/// Puts a failed or cancelled job back in line.
pub(crate) fn retry(id: &str) {
    let store = store();
    // An episode that never arrived is fetched again.
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

/// The file to upload: of a video only its sound, which is a fraction of
/// its size. macOS's converter makes a small AAC file of an MP4; anywhere
/// else, and of the other containers, the sound is decoded here and sent
/// as a 16 kHz WAV file, when that is smaller than the video.
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
            let result = provider.upload(upload.clone(), &key).await;
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
    store.update_job(id, |job| {
        if let Some(target) = soniox_target {
            let translated = document.segments.iter().filter(|s| s.has_translation()).count() as u32;
            let total = document.segments.len() as u32;
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
        job.document = Some(document);
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

/// Transcribes a job on this machine.
async fn run_local(store: Store, id: &str, job: &Job) -> Result<(), Failure> {
    let size = std::fs::metadata(&job.source_path).map_err(|e| Failure::new("missing_source", e.to_string()))?.len();
    if !subtitles::is_media(&job.source_path) {
        return Err(Failure::new("unsupported_format", "Unsupported file type."));
    }
    // One recording at a time, from here on.
    let _turn = local::Lane::turn().await;
    store.update_job(id, |job| job.status = JobStatus::Converting);
    store.set_progress(id, "converting", None);
    let samples = local::prepare_audio(job).await?;
    let duration_ms = local::duration_ms(&samples);
    store.update_job(id, |job| job.status = JobStatus::Processing);
    let document = local::transcribe(store, job, samples.clone()).await?;
    let empty = document.segments.is_empty();
    // Qwen3 times its words as it goes.
    let timed = !document.tokens.is_empty();
    let has_video = matches!(subtitles::extension(&job.source_path).as_str(), "mp4" | "mkv" | "avi");
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
        job.document = Some(document);
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

/// Times the words of a finished transcript, where the settings ask for it
/// and the aligner is here. `samples` is the audio already prepared, if
/// any. The job is complete either way.
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

/// Times the words of a transcript the user asks about.
pub(crate) fn align(id: &str) {
    let store = store();
    let id = id.to_owned();
    store.run_for(&id.clone(), async move {
        // Asked for by hand: whatever the setting for doing it unasked.
        if let Some(job) = store.job_now(&id).filter(|job| local::can_align(job)) {
            time_words(store, &id, &job, None).await;
        }
    });
}

/// Deletes what a job left at its provider.
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
    provider.cleanup(job.remote_transcription_id.as_deref(), job.remote_file_id.as_deref(), &key).await;
    store.update_job(id, |job| job.cleanup_state = CleanupState::Complete);
}
