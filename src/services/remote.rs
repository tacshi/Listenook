use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};

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
        self.answer(response.status(), body)
    }

    fn answer(self, status: u16, body: Value) -> Result<Value, Failure> {
        if (200..300).contains(&status) {
            Ok(body)
        } else if status == 404 && body.is_null() {
            Err(Failure::new(self.code("request_failed"), "Not found."))
        } else {
            Err(self.failure(status, &body))
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

    /// Whether the file or job is gone from the provider: deleted now, or already gone.
    async fn delete(self, path: &str, key: &str) -> bool {
        let request = HttpRequest::new("DELETE", format!("{}{path}", self.base()))
            .header("Authorization", format!("Bearer {key}"));
        fetch(request).await.is_ok_and(|response| response.ok() || response.status() == 404)
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

    /// Uploads the file at `path`, counting what is sent in `sending`. Dropping the upload before
    /// it ends stops the sending.
    pub(crate) async fn upload(self, path: PathBuf, key: &str, sending: Sending) -> Result<String, Failure> {
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
        let content_type = format!("multipart/form-data; boundary={boundary}");
        let missing = |e: std::io::Error| Failure::new("missing_source", e.to_string());
        let size = std::fs::metadata(&path).map_err(missing)?.len();
        if self == Provider::Moss && size > MOSS_MAX_BYTES as u64 {
            return Err(Failure::new("moss_file_too_large", "MOSS accepts files up to 512 MB."));
        }
        // Sent from the file as it is read, not gathered in memory first: an hour of
        // uncompressed audio is hundreds of megabytes, enough for a phone to end the app.
        let (url, auth) = (format!("{}/files", self.base()), format!("Bearer {key}"));
        let parts = Multipart { head, path, size, tail: tail.into_bytes(), content_type };
        let _halt = Halt(sending.clone());
        let (status, body) = blocking(move || parts.post(&url, &auth, &sending))
            .await
            .map_err(|e| Failure::network(e.to_string()))??;
        self.id_of(&self.answer(status, body)?, &["id"])
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

    /// Deletes what the job left with the provider; whether all of it is gone.
    pub(crate) async fn cleanup(self, transcription_id: Option<&str>, file_id: Option<&str>, key: &str) -> bool {
        let mut gone = true;
        if let (Provider::Soniox, Some(id)) = (self, transcription_id) {
            gone &= self.delete(&format!("/transcriptions/{id}"), key).await;
        }
        if let Some(id) = file_id {
            gone &= self.delete(&format!("/files/{id}"), key).await;
        }
        gone
    }
}

/// A multipart upload of a file, sent from the disk as it is read.
struct Multipart {
    head: Vec<u8>,
    path: PathBuf,
    size: u64,
    tail: Vec<u8>,
    content_type: String,
}

impl Multipart {
    /// Posts it to `url`: the status and the JSON that came back.
    fn post(self, url: &str, auth: &str, sending: &Sending) -> Result<(u16, Value), Failure> {
        use std::io::{Cursor, Read};
        let file = std::fs::File::open(&self.path).map_err(|e| Failure::new("missing_source", e.to_string()))?;
        let length = self.head.len() as u64 + self.size + self.tail.len() as u64;
        sending.total.store(length, Ordering::Relaxed);
        let body = Counted {
            body: Cursor::new(self.head).chain(file.take(self.size)).chain(Cursor::new(self.tail)),
            sending: sending.clone(),
        };
        let sent = super::http()
            .post(url)
            .set("Authorization", auth)
            .set("Content-Type", &self.content_type)
            .set("Content-Length", &length.to_string())
            .send(body);
        let response = match sent {
            Ok(response) | Err(ureq::Error::Status(_, response)) => response,
            Err(error) => return Err(Failure::network(error.to_string())),
        };
        let status = response.status();
        let body = serde_json::from_reader(response.into_reader().take(16 * 1024 * 1024)).unwrap_or(Value::Null);
        Ok((status, body))
    }
}

/// How much of an upload has been sent, shared with the thread sending it.
#[derive(Clone, Default)]
pub(crate) struct Sending {
    sent: Arc<AtomicU64>,
    total: Arc<AtomicU64>,
    stop: Arc<AtomicBool>,
}

impl Sending {
    /// How much has been sent, once it is known how much there is to send.
    pub(crate) fn fraction(&self) -> Option<f64> {
        let total = self.total.load(Ordering::Relaxed);
        (total > 0).then(|| (self.sent.load(Ordering::Relaxed) as f64 / total as f64).min(1.0))
    }
}

/// Stops the sending when dropped: when the upload ends, or is dropped before it ends.
struct Halt(Sending);

impl Drop for Halt {
    fn drop(&mut self) {
        self.0.stop.store(true, Ordering::Relaxed);
    }
}

/// A body that counts what is read from it to be sent, and ends the sending once stopped.
struct Counted<R> {
    body: R,
    sending: Sending,
}

impl<R: std::io::Read> std::io::Read for Counted<R> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if self.sending.stop.load(Ordering::Relaxed) {
            return Err(std::io::Error::other("the upload was stopped"));
        }
        let read = self.body.read(buffer)?;
        self.sending.sent.fetch_add(read as u64, Ordering::Relaxed);
        Ok(read)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Progress {
    Queued(Duration),
    Running(Duration),
    Done(Value),
    Failed(Failure),
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, Read, Write};

    use super::*;

    #[test]
    fn a_file_is_sent_from_the_disk_with_its_length_and_counted() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/v1/files", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut headers = Vec::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line.trim().is_empty() {
                    break;
                }
                headers.push(line.trim().to_ascii_lowercase());
            }
            let length: usize = headers
                .iter()
                .find_map(|header| header.strip_prefix("content-length: ")?.parse().ok())
                .expect("a fixed length, not chunks");
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let reply = r#"{"id":"file-1"}"#;
            write!(&stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{reply}", reply.len()).unwrap();
            (headers, body)
        });
        let path = std::env::temp_dir().join(format!("listenook-upload-{}.wav", std::process::id()));
        std::fs::write(&path, b"RIFF0123456789").unwrap();
        let parts = Multipart {
            head: b"--b\r\n\r\n".to_vec(),
            path: path.clone(),
            size: 14,
            tail: b"\r\n--b--\r\n".to_vec(),
            content_type: "multipart/form-data; boundary=b".into(),
        };
        let sending = Sending::default();
        assert_eq!(sending.fraction(), None, "nothing known before it starts");
        let (status, body) = parts.post(&url, "Bearer key", &sending).unwrap();
        assert_eq!((status, body), (200, json!({"id": "file-1"})));
        assert_eq!(sending.fraction(), Some(1.0));
        let (headers, sent) = server.join().unwrap();
        assert_eq!(sent, b"--b\r\n\r\nRIFF0123456789\r\n--b--\r\n");
        assert!(headers.contains(&"authorization: bearer key".to_owned()));
        assert!(!headers.iter().any(|header| header.starts_with("transfer-encoding")));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_stopped_upload_sends_nothing_more() {
        let sending = Sending::default();
        let mut body = Counted { body: &b"0123456789"[..], sending: sending.clone() };
        let mut buffer = [0; 4];
        assert_eq!(body.read(&mut buffer).unwrap(), 4);
        assert_eq!(sending.sent.load(Ordering::Relaxed), 4);
        drop(Halt(sending.clone()));
        assert!(body.read(&mut buffer).is_err());
        assert_eq!(sending.sent.load(Ordering::Relaxed), 4);
    }
}
