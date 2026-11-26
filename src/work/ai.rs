use std::time::{Duration, Instant};

use listenook_core::{
    LlmProviderSettings, TranslationStatus,
    ai::{
        Ask,
        ads::Scan,
        brief::{Brief, BriefRequest},
        translate::Translation,
    },
};
use nsh_core::prelude::*;
use serde_json::{Value, json};

use crate::services::remote::Failure;
use crate::services::{chatgpt, secrets, secrets::Secret};
use crate::state::{Store, store};

const SILENCE_LIMIT: Duration = Duration::from_secs(55);

fn reply_text(body: &[u8]) -> Result<String, Failure> {
    let raw = String::from_utf8_lossy(body);
    let events: Vec<Value> = raw
        .lines()
        .filter_map(|line| line.strip_prefix("data:"))
        .map(str::trim)
        .filter(|data| *data != "[DONE]")
        .filter_map(|data| serde_json::from_str(data).ok())
        .collect();
    if let Some(error) = events.iter().find_map(|event| event.get("error")) {
        return Err(Failure {
            code: "llm_server_failure".into(),
            message: error.to_string().chars().take(300).collect(),
            retryable: true,
        });
    }
    let text = if events.is_empty() {
        serde_json::from_str::<Value>(&raw)
            .ok()
            .and_then(|body| body["choices"][0]["message"]["content"].as_str().map(str::to_owned))
            .unwrap_or_default()
    } else {
        events.iter().filter_map(|event| event["choices"][0]["delta"]["content"].as_str()).collect()
    };
    Some(text.trim().to_owned())
        .filter(|text| !text.is_empty())
        .ok_or_else(|| Failure::new("llm_invalid_response", "The reply had no text."))
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
    if settings.signs_in() {
        return chatgpt::models().await;
    }
    let key = key.filter(|key| !key.trim().is_empty()).or_else(|| secrets::read(Secret::Llm));
    let (endpoint, key) = configured_with(settings, false, key)?;
    let response = fetch(with_key(HttpRequest::get(format!("{endpoint}/models")), key.as_deref()))
        .await
        .map_err(|message| Failure { code: "llm_network_error".into(), message, retryable: true })?;
    if !response.ok() {
        return Err(Failure::llm(response.status(), &response.text()));
    }
    let body: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
    let listed = body
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::new("llm_invalid_response", "The models list could not be read."))?;
    Ok(newest_first(listed))
}

/// The ids of `listed`, the newest first where the provider says when each was made, and in
/// its own order otherwise.
fn newest_first(listed: &[Value]) -> Vec<String> {
    let mut dated: Vec<(i64, String)> = Vec::new();
    for model in listed {
        let Some(id) = model.get("id").and_then(Value::as_str).map(str::trim).filter(|id| !id.is_empty()) else {
            continue;
        };
        if !dated.iter().any(|(_, known)| known == id) {
            dated.push((model.get("created").and_then(Value::as_i64).unwrap_or(0), id.to_owned()));
        }
    }
    dated.sort_by_key(|(created, _)| std::cmp::Reverse(*created));
    dated.into_iter().map(|(_, id)| id).collect()
}

async fn complete(settings: &LlmProviderSettings, ask: &Ask) -> Result<String, Failure> {
    if settings.signs_in() {
        return respond(settings, ask).await;
    }
    let (endpoint, key) = configured(settings, true)?;
    let (system, user) = (ask.system, ask.prompt.as_str());
    let mut json_mode = ask.json;
    let mut stream = true;
    let mut attempt = 0_u32;
    loop {
        let mut body = json!({
            "model": settings.model.trim(),
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        });
        if json_mode {
            body["response_format"] = json!({"type": "json_object"});
        }
        if stream {
            body["stream"] = json!(true);
        }
        let request = HttpRequest::post(format!("{endpoint}/chat/completions"), body.to_string())
            .header("Content-Type", "application/json");
        let started = Instant::now();
        let result = match fetch(with_key(request, key.as_deref())).await {
            Err(message) if started.elapsed() >= SILENCE_LIMIT => {
                Err(Failure { code: "llm_timeout".into(), message, retryable: true })
            }
            Err(message) => Err(Failure { code: "llm_network_error".into(), message, retryable: true }),
            Ok(response) if !response.ok() => Err(Failure::llm(response.status(), &response.text())),
            Ok(response) => reply_text(&response.body),
        };
        match result {
            Ok(text) => return Ok(text),
            Err(failure)
                if stream
                    && failure.code == "llm_request_failed"
                    && (!json_mode || failure.message.to_lowercase().contains("stream")) =>
            {
                stream = false
            }
            Err(failure) if json_mode && failure.code == "llm_request_failed" => json_mode = false,
            Err(failure) if failure.retryable && attempt < 3 => {
                timer(Duration::from_secs(1 << attempt)).await;
                attempt += 1;
            }
            Err(failure) => return Err(failure),
        }
    }
}

/// The answer of a ChatGPT plan, asked once more without JSON mode when the model refuses it,
/// and again after a pause when it failed for a while.
async fn respond(settings: &LlmProviderSettings, ask: &Ask) -> Result<String, Failure> {
    if let Some(code) = settings.validate() {
        return Err(Failure::new(code, "The AI provider is not configured."));
    }
    let mut json_mode = ask.json;
    let mut attempt = 0_u32;
    loop {
        match chatgpt::respond(settings.model.trim(), ask, json_mode).await {
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

/// Whether failure `code` is put right in Settings › AI (a missing or rejected key, a wrong
/// endpoint or model) rather than by trying again.
pub(crate) fn needs_setup(code: &str) -> bool {
    let code = ["llm_", "translation_", "ai_brief_", "ad_scan_"]
        .iter()
        .find_map(|prefix| code.strip_prefix(prefix))
        .unwrap_or(code);
    matches!(
        code,
        "missing_credentials"
            | "sign_in_required"
            | "signed_out"
            | "bad_credentials"
            | "invalid_url"
            | "https_required"
            | "model_required"
            | "endpoint_or_model_not_found"
    )
}

pub(crate) fn translation_key(id: &str) -> String {
    format!("{id}:translate")
}

pub(crate) fn start_translation(id: &str, target: &str, only: Option<Vec<String>>) {
    let store = store();
    let (id, target) = (id.to_owned(), target.to_owned());
    let settings = store.settings().llm_provider_settings;
    let Some(document) = store.job_now(&id).and_then(|job| job.document()) else {
        return;
    };
    let translation = Translation::new(&document.segments, only.as_deref(), &target);
    let total = translation.as_ref().map_or(1, Translation::total);
    if total == 0 {
        return;
    }
    store.update_job(&id, |job| job.apply(listenook_core::Change::BeginTranslation(&target, &settings.model, total)));
    store.run_for(&translation_key(&id), async move {
        let mut translation = match translation {
            Ok(translation) => translation,
            Err(code) => {
                store.update_job(&id, |job| {
                    job.apply(listenook_core::Change::EndTranslation(TranslationStatus::Failed, Some(code.to_owned())))
                });
                return;
            }
        };
        let mut error = None::<String>;
        while let Some(ask) = translation.ask() {
            let reply = match complete(&settings, &ask).await {
                Ok(reply) => reply,
                Err(failure) => {
                    error = Some(recoded(failure, "translation_"));
                    break;
                }
            };
            let lines = translation.answer(&reply);
            let done = translation.translated();
            store.update_job(&id, |job| job.apply(listenook_core::Change::AddTranslations(lines, done)));
        }
        store.update_job(&id, |job| {
            let (status, code) = translation.outcome(error.clone(), job.document().as_deref());
            job.apply(listenook_core::Change::EndTranslation(status, code));
        });
    });
}

/// One sentence translated on its own, for the editor to show before anything is saved.
pub(crate) async fn translate_line(text: &str, target: &str) -> Result<String, String> {
    let settings = store().settings().llm_provider_settings;
    let mut translation = Translation::line(text, target).map_err(str::to_owned)?;
    let ask = translation.ask().ok_or("translation_incomplete_response")?;
    let reply = complete(&settings, &ask).await.map_err(|failure| recoded(failure, "translation_"))?;
    translation.answer(&reply).pop().map(|(_, line)| line).ok_or_else(|| "translation_incomplete_response".into())
}

pub(crate) fn cancel_translation(id: &str) {
    let store = store();
    if store.cancel_work(&translation_key(id)) {
        store.update_job(id, |job| job.apply(listenook_core::Change::StopTranslation));
    }
}

pub(crate) fn brief_key(id: &str) -> String {
    format!("{id}:brief")
}

async fn generate(store: Store, id: &str, request: BriefRequest) -> Result<(), String> {
    let settings = store.settings().llm_provider_settings;
    let document = store.job_now(id).and_then(|job| job.document()).ok_or("ai_brief_empty_transcript")?;
    let title = store.job_now(id).map(|job| job.title()).unwrap_or_default();
    let mut brief = Brief::new(request, (*document).clone(), &title)?;
    while let Some(ask) = brief.ask() {
        let (stage, counts) = brief.stage();
        store.update_job(id, |job| job.apply(listenook_core::Change::BriefAt(stage, counts)));
        let reply = complete(&settings, &ask).await.map_err(|failure| recoded(failure, "ai_brief_"))?;
        brief.answer(&reply)?;
    }
    let made = brief.finish()?;
    store.update_job(id, |job| job.apply(listenook_core::Change::BriefMade(made)));
    Ok(())
}

pub(crate) fn start_brief(id: &str, request: BriefRequest) {
    let store = store();
    let id = id.to_owned();
    store.update_job(&id, |job| {
        let studying = !request.highlights.is_empty();
        job.apply(listenook_core::Change::BeginBrief(
            &request.output_language,
            &request.model,
            request.sections.clone(),
            request.learning_level,
            studying,
        ));
    });
    store.run_for(&brief_key(&id), async move {
        if let Err(code) = generate(store, &id, request).await {
            store.update_job(&id, |job| job.apply(listenook_core::Change::BriefFailed(code)));
        }
    });
}

pub(crate) fn cancel_brief(id: &str) {
    let store = store();
    if store.cancel_work(&brief_key(id)) {
        store.update_job(id, |job| job.apply(listenook_core::Change::BriefCancelled));
    }
}

pub(crate) fn ad_scan_key(id: &str) -> String {
    format!("{id}:ads")
}

async fn scan_for_ads(store: Store, id: &str) -> Result<(), String> {
    let settings = store.settings().llm_provider_settings;
    let document = store.job_now(id).and_then(|job| job.document()).ok_or("ad_scan_empty_transcript")?;
    let title = store.job_now(id).map(|job| job.title()).unwrap_or_default();
    let mut scan = Scan::new(&document, &title)?;
    while let Some(ask) = scan.ask() {
        let (done, total) = scan.progress();
        store.update_job(id, |job| job.apply(listenook_core::Change::AdScanAt(done, total)));
        let reply = complete(&settings, &ask).await.map_err(|failure| recoded(failure, "ad_scan_"))?;
        scan.answer(&reply)?;
    }
    // Read again: the transcript may have changed while the model thought.
    let document = store.job_now(id).and_then(|job| job.document()).unwrap_or(document);
    let found = scan.findings(&document);
    let (_, total) = scan.progress();
    store.update_job(id, |job| job.apply(listenook_core::Change::AdsFound(found, total)));
    Ok(())
}

/// Asks the AI where the ads are. What it finds waits in the job's
/// `ad_scan` until someone skips it or says no.
pub(crate) fn start_ad_scan(id: &str) {
    let store = store();
    let id = id.to_owned();
    if store.job_now(&id).is_some_and(|job| job.is_scanning_for_ads()) {
        return;
    }
    store.update_job(&id, |job| job.apply(listenook_core::Change::BeginAdScan));
    store.run_for(&ad_scan_key(&id), async move {
        if let Err(code) = scan_for_ads(store, &id).await {
            store.update_job(&id, |job| job.apply(listenook_core::Change::AdScanFailed(code)));
        }
    });
}

pub(crate) fn cancel_ad_scan(id: &str) {
    let store = store();
    if store.cancel_work(&ad_scan_key(id)) {
        store.update_job(id, |job| job.apply(listenook_core::Change::ForgetAds));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streamed_and_whole_replies_give_the_same_text() {
        let streamed = "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n: keep-alive\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"{\\\"a\\\":\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" 1}\"}}]}\n\ndata: [DONE]\n";
        assert_eq!(reply_text(streamed.as_bytes()).unwrap(), "{\"a\": 1}");
        let whole = r#"{"choices":[{"message":{"content":" {\"a\": 1} "}}]}"#;
        assert_eq!(reply_text(whole.as_bytes()).unwrap(), "{\"a\": 1}");
    }

    #[test]
    fn a_stream_that_reports_an_error_or_nothing_fails() {
        let broken = "data: {\"error\":{\"message\":\"overloaded\"}}\n\n";
        assert_eq!(reply_text(broken.as_bytes()).unwrap_err().code, "llm_server_failure");
        assert_eq!(reply_text(b"data: [DONE]\n").unwrap_err().code, "llm_invalid_response");
        assert_eq!(reply_text(b"").unwrap_err().code, "llm_invalid_response");
    }

    #[test]
    fn models_are_listed_newest_first() {
        let listed = json!([
            {"id": "babbage-002", "created": 1_692_634_615},
            {"id": "gpt-6", "created": 1_790_000_000},
            {"id": " "},
            {"id": "local-a"},
            {"id": "gpt-6", "created": 1_790_000_000},
            {"id": "local-b"},
        ]);
        assert_eq!(newest_first(listed.as_array().unwrap()), ["gpt-6", "babbage-002", "local-a", "local-b"]);
    }

    #[test]
    fn a_missing_key_or_endpoint_is_put_right_in_settings() {
        for code in ["translation_missing_credentials", "translation_bad_credentials", "translation_model_required"] {
            assert!(needs_setup(code), "{code}");
        }
        for code in ["translation_rate_limit", "translation_network_error", "translation_incomplete_response"] {
            assert!(!needs_setup(code), "{code}");
        }
    }
}
