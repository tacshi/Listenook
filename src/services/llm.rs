use std::time::Duration;

use listenook_core::{
    AiGenerationState, AiGenerationStatus, LlmProviderSettings, TranslationState, TranslationStatus,
    brief::{self, BriefRequest},
    translate,
};
use nsh_core::prelude::*;
use serde_json::{Value, json};

use super::remote::Failure;
use crate::state::{Store, secrets, secrets::Secret, store};

fn failure_of(status: u16, body: &str) -> Failure {
    let lower = body.to_lowercase();
    let names_missing = ["not found", "does not exist", "unknown"].iter().any(|w| lower.contains(w))
        && (lower.contains("model") || lower.contains("endpoint"));
    let code = match status {
        401 | 403 => "llm_bad_credentials",
        404 => "llm_endpoint_or_model_not_found",
        400 if names_missing => "llm_endpoint_or_model_not_found",
        408 => "llm_timeout",
        429 => "llm_rate_limit",
        500.. => "llm_server_failure",
        _ => "llm_request_failed",
    };
    Failure {
        code: code.into(),
        message: body.chars().take(300).collect(),
        retryable: matches!(status, 408 | 429 | 500..),
    }
}

fn configured(settings: &LlmProviderSettings, needs_model: bool) -> Result<(String, Option<String>), Failure> {
    configured_with(settings, needs_model, secrets::read(Secret::Llm))
}

fn configured_with(
    settings: &LlmProviderSettings,
    needs_model: bool,
    key: Option<String>,
) -> Result<(String, Option<String>), Failure> {
    let mut checked = settings.clone();
    if !needs_model && checked.model.is_empty() {
        checked.model = "-".into();
    }
    if let Some(code) = checked.validate() {
        return Err(Failure::new(code, "The AI provider is not configured."));
    }
    if key.is_none() && !settings.is_loopback() {
        return Err(Failure::new("llm_missing_credentials", "No API key."));
    }
    Ok((settings.endpoint(), key))
}

fn with_key(request: HttpRequest, key: Option<&str>) -> HttpRequest {
    match key {
        Some(key) => request.header("Authorization", format!("Bearer {key}")),
        None => request,
    }
}

pub(crate) async fn list_models(settings: &LlmProviderSettings, key: Option<String>) -> Result<Vec<String>, Failure> {
    let key = key.filter(|key| !key.trim().is_empty()).or_else(|| secrets::read(Secret::Llm));
    let (endpoint, key) = configured_with(settings, false, key)?;
    let response = fetch(with_key(HttpRequest::get(format!("{endpoint}/models")), key.as_deref()))
        .await
        .map_err(|message| Failure { code: "llm_network_error".into(), message, retryable: true })?;
    if !response.ok() {
        return Err(failure_of(response.status(), &response.text()));
    }
    let body: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
    let mut models: Vec<String> = body
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::new("llm_invalid_response", "The models list could not be read."))?
        .iter()
        .filter_map(|model| model.get("id").and_then(Value::as_str))
        .map(|id| id.trim().to_owned())
        .filter(|id| !id.is_empty())
        .collect();
    models.sort();
    models.dedup();
    Ok(models)
}

pub(crate) async fn complete(
    settings: &LlmProviderSettings,
    system: &str,
    user: &str,
    json_mode: bool,
) -> Result<String, Failure> {
    let (endpoint, key) = configured(settings, true)?;
    let mut json_mode = json_mode;
    let mut attempt = 0_u32;
    loop {
        let mut body = json!({
            "model": settings.model.trim(),
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        });
        if json_mode {
            body["response_format"] = json!({"type": "json_object"});
        }
        let request = HttpRequest::post(format!("{endpoint}/chat/completions"), body.to_string())
            .header("Content-Type", "application/json");
        let result = match fetch(with_key(request, key.as_deref())).await {
            Err(message) => Err(Failure { code: "llm_network_error".into(), message, retryable: true }),
            Ok(response) if !response.ok() => Err(failure_of(response.status(), &response.text())),
            Ok(response) => serde_json::from_slice::<Value>(&response.body)
                .ok()
                .and_then(|body| body["choices"][0]["message"]["content"].as_str().map(|text| text.trim().to_owned()))
                .filter(|text| !text.is_empty())
                .ok_or_else(|| Failure::new("llm_invalid_response", "The reply had no text.")),
        };
        match result {
            Ok(text) => return Ok(text),
            Err(failure) if json_mode && failure.code == "llm_request_failed" => json_mode = false,
            Err(failure) if failure.retryable && attempt < 3 => {
                timer(Duration::from_secs(1 << attempt)).await;
                attempt += 1;
            }
            Err(failure) => return Err(failure),
        }
    }
}

fn recoded(failure: Failure, prefix: &str) -> String {
    failure.code.strip_prefix("llm_").map_or(failure.code.clone(), |rest| format!("{prefix}{rest}"))
}

pub(crate) fn translation_key(id: &str) -> String {
    format!("{id}:translate")
}

pub(crate) fn start_translation(id: &str, target: &str, only: Option<Vec<String>>) {
    let store = store();
    let (id, target) = (id.to_owned(), target.to_owned());
    let settings = store.settings().llm_provider_settings;
    let Some(document) = store.job_now(&id).and_then(|job| job.document.clone()) else {
        return;
    };
    let batches = translate::batches(&document.segments, only.as_deref());
    let total: u32 = batches.iter().map(|b| b.ids.len() as u32).sum();
    if total == 0 {
        return;
    }
    let whole = only.is_none();
    store.update_job(&id, |job| {
        job.translation_state = TranslationState {
            status: TranslationStatus::Translating,
            target_language: target.clone(),
            model: settings.model.clone(),
            origin: Some("llm".into()),
            completed_segments: 0,
            total_segments: total,
            ..TranslationState::default()
        };
    });
    store.run_for(&translation_key(&id), async move {
        let (mut done, mut missing, mut error) = (0_u32, 0_u32, None::<String>);
        for batch in batches {
            let reply = match translate::user_prompt(&batch.texts, &target) {
                Ok(prompt) => complete(&settings, translate::SYSTEM_PROMPT, &prompt, false)
                    .await
                    .map_err(|failure| recoded(failure, "translation_")),
                Err(code) => Err(code.to_owned()),
            };
            let lines = match reply {
                Ok(reply) => translate::parse_reply(&reply, batch.texts.len()),
                Err(code) => {
                    error = Some(code);
                    break;
                }
            };
            missing += lines.iter().filter(|line| line.is_none()).count() as u32;
            done += lines.iter().filter(|line| line.is_some()).count() as u32;
            store.update_job(&id, |job| {
                if let Some(document) = &mut job.document {
                    for (segment_id, line) in batch.ids.iter().zip(lines) {
                        if let (Some(line), Some(segment)) =
                            (line, document.segments.iter_mut().find(|s| &s.id == segment_id))
                        {
                            segment.translated_text = Some(line);
                        }
                    }
                    document.touch();
                }
                job.translation_state.completed_segments = done;
            });
        }
        store.update_job(&id, |job| {
            let state = &mut job.translation_state;
            let untranslated = job.document.as_ref().is_some_and(|d| d.segments.iter().any(|s| !s.has_translation()));
            state.status = match (&error, done) {
                (Some(_), 0) => TranslationStatus::Failed,
                (Some(_), _) => TranslationStatus::Partial,
                (None, _) if missing > 0 || (whole && untranslated) => TranslationStatus::Partial,
                (None, _) => TranslationStatus::Completed,
            };
            state.error_code = error.clone().or_else(|| {
                (state.status == TranslationStatus::Partial).then(|| "translation_incomplete_response".into())
            });
        });
    });
}

pub(crate) fn cancel_translation(id: &str) {
    let store = store();
    if store.cancel_work(&translation_key(id)) {
        store.update_job(id, |job| {
            job.translation_state.status = if job.translation_state.completed_segments > 0 {
                TranslationStatus::Partial
            } else {
                TranslationStatus::Cancelled
            };
        });
    }
}

pub(crate) fn brief_key(id: &str) -> String {
    format!("{id}:brief")
}

async fn brief_json(settings: &LlmProviderSettings, system: &str, prompt: &str) -> Result<Value, Failure> {
    let reply = complete(settings, system, prompt, true).await?;
    if let Some(value) = brief::decode_reply(&reply) {
        return Ok(value);
    }
    let again = format!(
        "{prompt}\nYour previous response was not valid JSON. Return only one valid JSON object matching the requested shape."
    );
    let reply = complete(settings, system, &again, true).await?;
    brief::decode_reply(&reply).ok_or_else(|| Failure::new("ai_brief_invalid_response", "The reply was not JSON."))
}

async fn generate(store: Store, id: &str, request: &BriefRequest) -> Result<(), String> {
    let settings = store.settings().llm_provider_settings;
    let document = store.job_now(id).and_then(|job| job.document.clone()).ok_or("ai_brief_empty_transcript")?;
    let chunks = brief::chunks(&document);
    if chunks.is_empty() {
        return Err("ai_brief_empty_transcript".into());
    }
    if request.sections.is_empty() {
        return Err("ai_brief_no_sections".into());
    }
    let total = chunks.len();
    let recode = |failure: Failure| recoded(failure, "ai_brief_");
    let title = store.job_now(id).map(|job| job.title()).unwrap_or_default();
    let batches: Vec<_> = request.highlights.chunks(brief::STUDY_BATCH).collect();
    let mut replies = Vec::with_capacity(batches.len());
    for (index, batch) in batches.iter().enumerate() {
        store.update_job(id, |job| {
            job.ai_generation_state.stage = "studying".into();
            job.ai_generation_state.completed_chunks = index as u32;
            job.ai_generation_state.total_chunks = batches.len() as u32;
        });
        let prompt = brief::study_prompt(request, batch, &title);
        replies.push(brief_json(&settings, brief::STUDY_SYSTEM_PROMPT, &prompt).await.map_err(recode)?);
    }
    let study = brief::study_from_json(&replies, request, &document);
    let mut analyses = Vec::with_capacity(total);
    for (index, chunk) in chunks.iter().enumerate() {
        store.update_job(id, |job| {
            job.ai_generation_state.stage = "analyzing".into();
            job.ai_generation_state.completed_chunks = index as u32;
            job.ai_generation_state.total_chunks = total as u32;
        });
        let prompt = brief::chunk_prompt(request, &study, chunk, index, total);
        analyses.push(brief_json(&settings, brief::SYSTEM_PROMPT, &prompt).await.map_err(recode)?);
    }
    let combined = if total == 1 {
        analyses.remove(0)
    } else {
        store.update_job(id, |job| job.ai_generation_state.stage = "synthesizing".into());
        let prompt = brief::synthesis_prompt(request, &study, &analyses);
        brief_json(&settings, brief::SYSTEM_PROMPT, &prompt).await.map_err(recode)?
    };
    let made = brief::brief_from_json(&combined, request, &study, &document).map_err(str::to_owned)?;
    store.update_job(id, |job| {
        job.ai_brief = Some(made);
        job.ai_generation_state.status = AiGenerationStatus::Completed;
        job.ai_generation_state.error_code = None;
    });
    Ok(())
}

pub(crate) fn start_brief(id: &str, request: BriefRequest) {
    let store = store();
    let id = id.to_owned();
    store.update_job(&id, |job| {
        job.ai_generation_state = AiGenerationState {
            status: AiGenerationStatus::Generating,
            stage: if request.highlights.is_empty() { "analyzing" } else { "studying" }.into(),
            output_language: request.output_language.clone(),
            model: request.model.clone(),
            ..AiGenerationState::default()
        };
    });
    store.run_for(&brief_key(&id), async move {
        if let Err(code) = generate(store, &id, &request).await {
            store.update_job(&id, |job| {
                job.ai_generation_state.status = AiGenerationStatus::Failed;
                job.ai_generation_state.error_code = Some(code);
            });
        }
    });
}

pub(crate) fn cancel_brief(id: &str) {
    let store = store();
    if store.cancel_work(&brief_key(id)) {
        store.update_job(id, |job| job.ai_generation_state.status = AiGenerationStatus::Cancelled);
    }
}
