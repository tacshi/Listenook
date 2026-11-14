use std::{path::PathBuf, time::Duration};

use listenook_core::Job;
use nsh_core::prelude::*;
use serde_json::{Value, json};

use crate::state::secrets::Secret;

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Failure {
    pub(crate) code: String,
    pub(crate) message: String,
    pub(crate) retryable: bool,
}

impl Failure {
    pub(crate) fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), retryable: false }
    }

    pub(crate) fn network(message: String) -> Self {
        Self { code: "network_error".into(), message, retryable: true }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Provider {
    Soniox,
    Moss,
}

pub(crate) const SONIOX_MODEL: &str = "stt-async-v6";
const MOSS_MODEL: &str = "moss-transcribe-diarize";
const MOSS_VERSION: &str = "v20260410-streamparam-20260703";
const MOSS_MAX_BYTES: usize = 512 * 1024 * 1024;

impl Provider {
    fn base(self) -> &'static str {
        match self {
            Provider::Soniox => "https://api.soniox.com/v1",
            Provider::Moss => "https://api.mosi.cn/v1",
        }
    }

    fn prefix(self) -> &'static str {
        match self {
            Provider::Soniox => "",
            Provider::Moss => "moss_",
        }
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Provider::Soniox => "Soniox",
            Provider::Moss => "MOSS",
        }
    }

    pub(crate) fn secret(self) -> Secret {
        match self {
            Provider::Soniox => Secret::Soniox,
            Provider::Moss => Secret::Moss,
        }
    }

    fn code(self, code: &str) -> String {
        format!("{}{code}", self.prefix())
    }

    fn failure(self, status: u16, body: &Value) -> Failure {
        let text = |keys: &[&str]| -> Option<String> {
            keys.iter().find_map(|key| {
                body.get(key)
                    .or_else(|| body.get("error").and_then(|e| e.get(key)))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
        };
        let kind = text(&["error_type", "type", "code"]).unwrap_or_default().to_lowercase();
        let message = text(&["error_message", "message"])
            .unwrap_or_else(|| format!("{} request failed (HTTP {status}).", self.name()));
        let has = |words: &[&str]| words.iter().any(|word| kind.contains(word));
        let code = match status {
            401 | 403 => "bad_credentials",
            429 => "rate_limit",
            500.. => "server_failure",
            402 => "exhausted_balance",
            413 if self == Provider::Moss => "file_too_large",
            413 => "invalid_media",
            _ if has(&["balance", "credit", "billing", "insufficient_funds"]) => "exhausted_balance",
            _ if has(&["budget"]) && self == Provider::Soniox => "budget_exhausted",
            _ if has(&["quota", "rate", "concurrency"]) => "rate_limit",
            _ if has(&["audio", "media", "file"]) => "invalid_media",
            _ => "request_failed",
        };
        Failure { code: self.code(code), message, retryable: matches!(status, 408 | 429 | 500..) }
    }

    async fn send(self, request: HttpRequest, key: &str) -> Result<Value, Failure> {
        let response =
            fetch(request.header("Authorization", format!("Bearer {key}"))).await.map_err(Failure::network)?;
        let body: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
        if response.ok() {
            Ok(body)
        } else if response.status() == 404 && body.is_null() {
            Err(Failure::new(self.code("request_failed"), "Not found."))
        } else {
            Err(self.failure(response.status(), &body))
        }
    }

    async fn get(self, path: &str, key: &str) -> Result<Value, Failure> {
        self.send(HttpRequest::get(format!("{}{path}", self.base())), key).await
    }

    async fn post(self, path: &str, body: &Value, key: &str) -> Result<Value, Failure> {
        let request = HttpRequest::post(format!("{}{path}", self.base()), body.to_string())
            .header("Content-Type", "application/json");
        self.send(request, key).await
    }

    async fn delete(self, path: &str, key: &str) {
        let _ = self.send(HttpRequest::new("DELETE", format!("{}{path}", self.base())), key).await;
    }

    fn id_of(self, body: &Value, keys: &[&str]) -> Result<String, Failure> {
        keys.iter()
            .find_map(|key| body.get(key).and_then(Value::as_str).filter(|id| !id.is_empty()))
            .map(str::to_owned)
            .ok_or_else(|| Failure::new(self.code("invalid_response"), "The response did not contain an id."))
    }

    pub(crate) async fn validate_key(self, key: &str) -> Result<(), Failure> {
        match self {
            Provider::Soniox => self.get("/files?limit=1", key).await.map(|_| ()),
            Provider::Moss => {
                let models = self.get("/models", key).await?;
                let found = models
                    .get("data")
                    .and_then(Value::as_array)
                    .is_some_and(|data| data.iter().any(|m| m.get("id").and_then(Value::as_str) == Some(MOSS_MODEL)));
                if found {
                    Ok(())
                } else {
                    Err(Failure::new("moss_model_unavailable", "This key cannot access MOSS Pro."))
                }
            }
        }
    }

    pub(crate) async fn upload(self, path: PathBuf, key: &str) -> Result<String, Failure> {
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("audio").replace('"', "");
        let boundary = format!("listenook-{}", uuid::Uuid::new_v4().simple());
        let mut head = Vec::new();
        if self == Provider::Moss {
            head.extend(
                format!("--{boundary}\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\naudio\r\n").bytes(),
            );
        }
        head.extend(
            format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: application/octet-stream\r\n\r\n")
                .bytes(),
        );
        let tail = format!("\r\n--{boundary}--\r\n");
        let moss = self == Provider::Moss;
        let body = blocking(move || -> Result<Vec<u8>, Failure> {
            use std::io::Read;
            let missing = |e: std::io::Error| Failure::new("missing_source", e.to_string());
            let mut file = std::fs::File::open(path).map_err(missing)?;
            let size = file.metadata().map_err(missing)?.len() as usize;
            if moss && size > MOSS_MAX_BYTES {
                return Err(Failure::new("moss_file_too_large", "MOSS accepts files up to 512 MB."));
            }
            let mut body = Vec::with_capacity(head.len() + size + tail.len());
            body.extend(head);
            file.read_to_end(&mut body).map_err(missing)?;
            body.extend(tail.bytes());
            Ok(body)
        })
        .await
        .map_err(|e| Failure::new("missing_source", e.to_string()))??;
        let request = HttpRequest::post(format!("{}/files", self.base()), body)
            .header("Content-Type", format!("multipart/form-data; boundary={boundary}"));
        let answer = self.send(request, key).await?;
        self.id_of(&answer, &["id"])
    }

    pub(crate) async fn create(self, file_id: &str, job: &Job, key: &str) -> Result<String, Failure> {
        match self {
            Provider::Soniox => {
                let mut body = json!({
                    "model": SONIOX_MODEL,
                    "file_id": file_id,
                    "enable_language_identification": true,
                    "enable_speaker_diarization": true,
                });
                if !job.options.language_hints.is_empty() {
                    body["language_hints"] = json!(job.options.language_hints);
                }
                let translation = &job.options.soniox_translation;
                if translation.enabled && !translation.target_language.is_empty() {
                    body["translation"] = json!({"type": "one_way", "target_language": translation.target_language});
                }
                if !job.options.context_terms.is_empty() {
                    body["context"] = json!({"terms": job.options.context_terms});
                }
                let answer = self.post("/transcriptions", &body, key).await?;
                self.id_of(&answer, &["id"])
            }
            Provider::Moss => {
                let body = json!({
                    "model": MOSS_MODEL, "version": MOSS_VERSION, "file_id": file_id,
                    "diarize": true, "response_format": "json", "async": true,
                });
                let answer = self.post("/audio/transcriptions", &body, key).await?;
                self.id_of(&answer, &["task_id", "id"])
            }
        }
    }

    pub(crate) async fn progress(self, id: &str, key: &str) -> Result<Progress, Failure> {
        let path = match self {
            Provider::Soniox => format!("/transcriptions/{id}"),
            Provider::Moss => format!("/audio/tasks/{id}"),
        };
        let body = self.get(&path, key).await?;
        let status = body.get("status").and_then(Value::as_str).unwrap_or("");
        let wait = body
            .get("retry_after")
            .and_then(Value::as_f64)
            .map_or(Duration::from_secs(2), |seconds| Duration::from_secs_f64(seconds.clamp(1.0, 30.0)));
        Ok(match status {
            "completed" | "SUCCESS" => Progress::Done(body),
            "error" | "failed" | "FAILED" => {
                let mut failure = self.failure(400, &body);
                if failure.code.ends_with("request_failed") {
                    failure.code = self.code("transcription_failed");
                }
                failure.retryable = false;
                Progress::Failed(failure)
            }
            "queued" => Progress::Queued(wait),
            _ => Progress::Running(wait),
        })
    }

    pub(crate) async fn transcript(self, id: &str, done: Value, key: &str) -> Result<Value, Failure> {
        match self {
            Provider::Soniox => self.get(&format!("/transcriptions/{id}/transcript"), key).await,
            Provider::Moss => Ok(done),
        }
    }

    pub(crate) async fn cleanup(self, transcription_id: Option<&str>, file_id: Option<&str>, key: &str) {
        if let (Provider::Soniox, Some(id)) = (self, transcription_id) {
            self.delete(&format!("/transcriptions/{id}"), key).await;
        }
        if let Some(id) = file_id {
            self.delete(&format!("/files/{id}"), key).await;
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Progress {
    Queued(Duration),
    Running(Duration),
    Done(Value),
    Failed(Failure),
}
