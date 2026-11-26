//! A ChatGPT Plus or Pro plan as the AI provider: the person signs in with ChatGPT in their
//! browser, and the models are asked through OpenAI's Responses API, which the plan pays for
//! instead of an API key.
//!
//! Signing in registers Listenook with OpenAI for the account picked (OpenAI binds each
//! registration to one account and its workspace), and keeps what signs it in again: the
//! registration, the account's email and the refresh token, in the system's keychain.

use std::{
    collections::HashMap,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use listenook_core::{
    ai::Ask,
    l10n::{self, Lang},
};
use nsh_core::prelude::*;
use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::services::{
    remote::Failure,
    secrets::{self, Secret},
};

const ISSUER: &str = "https://auth.openai.com";
const RESOURCE: &str = "https://api.openai.com/v1";
const SCOPES: &str = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
/// The scope a sign-in carries only for an account on a ChatGPT plan.
const PLAN_SCOPE: &str = "chatgpt.tokens.use.direct";
const PORT: u16 = 1455;
/// How long the browser has to come back before the sign-in gives up.
const SIGN_IN_LIMIT: Duration = Duration::from_secs(10 * 60);

/// The ChatGPT account signed in on this device.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct Account {
    client_id: String,
    email: String,
    refresh_token: String,
    #[serde(default)]
    id_token: String,
}

impl Account {
    /// The account signed in on this device, if any.
    pub(crate) fn saved() -> Option<Account> {
        secrets::read(Secret::ChatGpt).and_then(|saved| serde_json::from_str(&saved).ok())
    }

    pub(crate) fn email(&self) -> &str {
        &self.email
    }

    /// What the keychain keeps of it.
    pub(crate) fn secret(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

#[derive(Deserialize)]
struct Discovery {
    issuer: String,
    authorization_endpoint: String,
    token_endpoint: String,
    #[serde(default)]
    revocation_endpoint: String,
    jwks_uri: String,
}

impl Discovery {
    async fn fetch() -> Result<Discovery, Failure> {
        let found: Discovery = get_json(&format!("{ISSUER}/.well-known/openid-configuration")).await?;
        let own = |endpoint: &str| endpoint.starts_with(&format!("{ISSUER}/"));
        if found.issuer != ISSUER
            || ![&found.authorization_endpoint, &found.token_endpoint, &found.jwks_uri].iter().all(|e| own(e))
        {
            return Err(unverified("the sign-in endpoints are not on OpenAI's own site"));
        }
        Ok(found)
    }
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Tokens {
    access_token: String,
    refresh_token: String,
    id_token: String,
    expires_in: u64,
    scope: String,
    error: String,
    error_description: String,
}

fn random(bytes: usize) -> String {
    let mut buffer = vec![0_u8; bytes];
    SystemRandom::new().fill(&mut buffer).expect("the system gives random numbers");
    URL_SAFE_NO_PAD.encode(buffer)
}

fn unverified(why: &str) -> Failure {
    log::warn!("ChatGPT sign-in: {why}");
    Failure::new("chatgpt_unverified", why)
}

fn network(message: String) -> Failure {
    Failure { code: "llm_network_error".into(), message, retryable: true }
}

async fn get_json<T: serde::de::DeserializeOwned>(url: &str) -> Result<T, Failure> {
    let response = fetch(HttpRequest::get(url).header("Accept", "application/json")).await.map_err(network)?;
    if !response.ok() {
        return Err(Failure::new("chatgpt_unreachable", format!("{url} answered HTTP {}", response.status())));
    }
    serde_json::from_slice(&response.body).map_err(|e| Failure::new("chatgpt_unreachable", e.to_string()))
}

async fn post_token(endpoint: &str, form: &[(&str, &str)]) -> Result<Tokens, (Failure, String)> {
    let body = url::form_urlencoded::Serializer::new(String::new()).extend_pairs(form).finish();
    let mut request = HttpRequest::post(endpoint, body)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .header("Accept", "application/json");
    request.follow_redirects = false;
    let response = fetch(request).await.map_err(|message| (network(message), String::new()))?;
    let tokens: Tokens = serde_json::from_slice(&response.body).unwrap_or_default();
    if response.ok() && tokens.error.is_empty() && !tokens.access_token.is_empty() {
        return Ok(tokens);
    }
    log::warn!("ChatGPT sign-in: the token endpoint answered HTTP {}: {}", response.status(), response.text());
    let said = [&tokens.error_description, &tokens.error].into_iter().find(|s| !s.is_empty()).cloned();
    let failure = Failure::new("chatgpt_sign_in_failed", said.unwrap_or_else(|| format!("HTTP {}", response.status())));
    Err((failure, tokens.error))
}

/// Signs in with ChatGPT in the browser: `again` signs that account in again under its own
/// registration; without it, Listenook registers anew for whichever account the person picks.
/// `host` names this device to OpenAI, the same each time. The page the browser comes back to
/// speaks `lang`.
pub(crate) async fn sign_in(host: String, again: Option<Account>, lang: Lang) -> Result<Account, Failure> {
    let discovery = Discovery::fetch().await?;
    let listener = TcpListener::bind(("127.0.0.1", PORT))
        .or_else(|_| TcpListener::bind(("127.0.0.1", 0)))
        .map_err(|e| Failure::new("chatgpt_port_taken", e.to_string()))?;
    let port = listener.local_addr().map_err(|e| Failure::new("chatgpt_port_taken", e.to_string()))?.port();
    let redirect = format!("http://127.0.0.1:{port}/auth/callback");
    let (state, verifier, nonce) = (random(32), random(48), random(32));
    let challenge = URL_SAFE_NO_PAD.encode(ring::digest::digest(&ring::digest::SHA256, verifier.as_bytes()));
    let mut query = vec![
        ("response_type", "code".to_owned()),
        ("redirect_uri", redirect.clone()),
        ("scope", SCOPES.into()),
        ("resource", RESOURCE.into()),
        ("state", state.clone()),
        ("nonce", nonce.clone()),
        ("code_challenge_method", "S256".into()),
        ("code_challenge", challenge),
        ("ext_agent_host_id", host),
    ];
    match &again {
        Some(account) => {
            query.push(("client_id", account.client_id.clone()));
            query.push(("login_hint", account.email.clone()));
            if !account.id_token.is_empty() {
                query.push(("id_token_hint", account.id_token.clone()));
            }
        }
        None => {
            query.push(("client_id", "dynamic_agent_client".into()));
            query.push(("agent_name_hint", "Listenook".into()));
        }
    }
    let query = url::form_urlencoded::Serializer::new(String::new()).extend_pairs(&query).finish();
    // Stops the wait below when this sign-in is dropped: cancelled, or replaced by another.
    let stop = Stop::default();
    let waiting = {
        let stop = stop.flag();
        blocking(move || wait_for_browser(listener, port, &state, lang, &stop))
    };
    if !open_url(format!("{}?{query}", discovery.authorization_endpoint)).await {
        return Err(Failure::new("chatgpt_browser_unavailable", "No browser opened the sign-in page."));
    }
    let back = waiting.await.map_err(|e| Failure::new("chatgpt_sign_in_failed", e.to_string()))??;
    if back.get("iss").is_some_and(|iss| iss != ISSUER) {
        return Err(unverified("the browser came back from another issuer"));
    }
    let issued = back.get("client_id").cloned().or_else(|| again.as_ref().map(|a| a.client_id.clone()));
    let Some(client_id) = issued.filter(|id| valid_client_id(id)) else {
        return Err(Failure::new("chatgpt_not_registered", "OpenAI did not register Listenook."));
    };
    if again.as_ref().is_some_and(|account| account.client_id != client_id) {
        return Err(Failure::new("chatgpt_other_registration", "Signed in under another registration."));
    }
    let code = back.get("code").map(String::as_str).unwrap_or_default();
    let tokens = post_token(
        &discovery.token_endpoint,
        &[
            ("grant_type", "authorization_code"),
            ("client_id", &client_id),
            ("code", code),
            ("code_verifier", &verifier),
            ("redirect_uri", &redirect),
            ("resource", RESOURCE),
        ],
    )
    .await
    .map_err(|(failure, error)| {
        // OpenAI turns down the code its own page just gave, with no reason, for an account on
        // no ChatGPT plan Listenook may use.
        if error == "invalid_grant" { Failure::new("chatgpt_no_plan", failure.message) } else { failure }
    })?;
    let claims = verify_id_token(&discovery, &tokens.id_token, &client_id, &nonce).await?;
    if !tokens.scope.split_whitespace().any(|scope| scope == PLAN_SCOPE) {
        return Err(Failure::new("chatgpt_no_plan", "The account has no ChatGPT plan Listenook may use."));
    }
    let account = Account {
        client_id,
        email: claims.get("email").and_then(Value::as_str).unwrap_or_default().to_owned(),
        refresh_token: tokens.refresh_token,
        id_token: tokens.id_token,
    };
    Access::keep(&account, tokens.access_token, tokens.expires_in).await;
    Ok(account)
}

fn valid_client_id(id: &str) -> bool {
    id != "dynamic_agent_client"
        && (4..=200).contains(&id.len())
        && id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
}

/// Ends the sign-in on this device: OpenAI forgets its refresh token, where it lets the app
/// say so.
pub(crate) async fn sign_out(account: Account) {
    *ACCESS.lock().await = None;
    let Ok(discovery) = Discovery::fetch().await else {
        return;
    };
    if !discovery.revocation_endpoint.starts_with(&format!("{ISSUER}/")) {
        return;
    }
    let body = url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs([
            ("token", account.refresh_token.as_str()),
            ("token_type_hint", "refresh_token"),
            ("client_id", account.client_id.as_str()),
        ])
        .finish();
    let request = HttpRequest::post(discovery.revocation_endpoint, body)
        .header("Content-Type", "application/x-www-form-urlencoded");
    drop(fetch(request).await);
}

/// Set when the sign-in that waits for the browser is dropped.
#[derive(Default)]
struct Stop(Arc<AtomicBool>);

impl Stop {
    fn flag(&self) -> Arc<AtomicBool> {
        self.0.clone()
    }
}

impl Drop for Stop {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

/// Waits for the browser to come back to `/auth/callback` with this sign-in's `state`, and
/// answers it with a page saying whether to go back to the app.
fn wait_for_browser(
    listener: TcpListener,
    port: u16,
    state: &str,
    lang: Lang,
    stop: &AtomicBool,
) -> Result<HashMap<String, String>, Failure> {
    listener.set_nonblocking(true).map_err(|e| Failure::new("chatgpt_port_taken", e.to_string()))?;
    let deadline = Instant::now() + SIGN_IN_LIMIT;
    while !stop.load(Ordering::Relaxed) && Instant::now() < deadline {
        match listener.accept() {
            Ok((stream, _)) => {
                if let Some(answer) = answer_browser(stream, port, state, lang) {
                    return answer;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(error) => return Err(Failure::new("chatgpt_sign_in_failed", error.to_string())),
        }
    }
    Err(Failure::new("chatgpt_cancelled", "The sign-in was not finished."))
}

/// What one request to the loopback says: `None` for one that is not this sign-in's callback
/// (a favicon, another page), which is turned away and waited past.
fn answer_browser(
    mut stream: TcpStream,
    port: u16,
    state: &str,
    lang: Lang,
) -> Option<Result<HashMap<String, String>, Failure>> {
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let mut head = Vec::new();
    let mut chunk = [0_u8; 2048];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") && head.len() < 16 * 1024 {
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(read) => head.extend_from_slice(&chunk[..read]),
        }
    }
    let callback = Callback::read(&String::from_utf8_lossy(&head), port);
    let (status, page, answer) = match callback {
        None => ("404 Not Found", String::new(), None),
        Some(query) if !same(query.get("state").map_or("", String::as_str), state) => (
            "400 Bad Request",
            page(lang, "This sign-in is no longer current.", "Close this tab and sign in again from Listenook."),
            None,
        ),
        Some(query) => match query.get("error") {
            Some(error) => {
                let code = if error == "access_denied" { "chatgpt_cancelled" } else { "chatgpt_sign_in_failed" };
                let failure = Failure::new(code, error.clone());
                ("200 OK", page(lang, "Sign-in cancelled", "You can close this tab."), Some(Err(failure)))
            }
            None => {
                ("200 OK", page(lang, "Signed in", "You can close this tab and go back to Listenook."), Some(Ok(query)))
            }
        },
    };
    let reply = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}",
        page.len()
    );
    let _ = stream.write_all(reply.as_bytes());
    answer
}

/// The query of a request for this loopback's `/auth/callback`.
struct Callback;

impl Callback {
    fn read(head: &str, port: u16) -> Option<HashMap<String, String>> {
        let mut lines = head.lines();
        let target = lines.next()?.strip_prefix("GET ")?.split(' ').next()?;
        let host = lines.find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.trim().eq_ignore_ascii_case("host").then(|| value.trim().to_owned())
        })?;
        if host != format!("127.0.0.1:{port}") {
            return None;
        }
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        (path == "/auth/callback").then(|| url::form_urlencoded::parse(query.as_bytes()).into_owned().collect())
    }
}

/// Whether `a` and `b` are the same, taking as long whichever byte they differ at.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0, |differ, (x, y)| differ | (x ^ y)) == 0
}

fn page(lang: Lang, title: &'static str, body: &'static str) -> String {
    format!(
        "<!doctype html><meta charset=\"utf-8\"><title>Listenook</title><body style=\"font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;height:90vh\"><div style=\"text-align:center\"><h2>{}</h2><p>{}</p></div></body>",
        l10n::tr(lang, title),
        l10n::tr(lang, body)
    )
}

/// Checks the identity token's signature against OpenAI's published keys, and that it was
/// made for this registration and this sign-in; its claims when it was.
async fn verify_id_token(
    discovery: &Discovery,
    token: &str,
    client_id: &str,
    nonce: &str,
) -> Result<serde_json::Map<String, Value>, Failure> {
    let parts: Vec<&str> = token.split('.').collect();
    let [header, payload, signature] = parts[..] else {
        return Err(unverified("no identity token came back"));
    };
    let decode = |part: &str| URL_SAFE_NO_PAD.decode(part).ok();
    let header: Value = decode(header).and_then(|h| serde_json::from_slice(&h).ok()).unwrap_or_default();
    if header["alg"] != "RS256" {
        return Err(unverified("the identity token is not signed with RS256"));
    }
    let keys: Value = get_json(&discovery.jwks_uri).await?;
    let key = keys["keys"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|key| key["kid"] == header["kid"] && key["kty"] == "RSA")
        .and_then(|key| Some((decode(key["n"].as_str()?)?, decode(key["e"].as_str()?)?)))
        .ok_or_else(|| unverified("the identity token is signed with an unknown key"))?;
    let signed = format!("{}.{payload}", parts[0]);
    ring::signature::RsaPublicKeyComponents { n: key.0, e: key.1 }
        .verify(&ring::signature::RSA_PKCS1_2048_8192_SHA256, signed.as_bytes(), &decode(signature).unwrap_or_default())
        .map_err(|_| unverified("the identity token's signature did not verify"))?;
    let claims: serde_json::Map<String, Value> = decode(payload)
        .and_then(|p| serde_json::from_slice(&p).ok())
        .ok_or_else(|| unverified("the identity token holds no claims"))?;
    check_claims(&claims, client_id, nonce, now_seconds())?;
    Ok(claims)
}

fn now_seconds() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

fn check_claims(
    claims: &serde_json::Map<String, Value>,
    client_id: &str,
    nonce: &str,
    now: i64,
) -> Result<(), Failure> {
    let for_us = match &claims.get("aud") {
        Some(Value::String(audience)) => audience == client_id,
        Some(Value::Array(audiences)) => audiences.iter().any(|a| a == client_id),
        _ => false,
    };
    let expires = claims.get("exp").and_then(Value::as_i64).unwrap_or(0);
    if claims.get("iss").and_then(Value::as_str) != Some(ISSUER) {
        Err(unverified("the identity token is from another issuer"))
    } else if !for_us {
        Err(unverified("the identity token is for another app"))
    } else if expires < now - 60 {
        Err(unverified("the identity token has expired"))
    } else if claims.get("nonce").and_then(Value::as_str) != Some(nonce) {
        Err(unverified("the identity token is for another sign-in"))
    } else {
        Ok(())
    }
}

/// The access token in use, for the account it was made for. One task renews it at a time:
/// each renewal may replace the refresh token, which the next one needs.
static ACCESS: tokio::sync::Mutex<Option<Access>> = tokio::sync::Mutex::const_new(None);

struct Access {
    client_id: String,
    token: String,
    until: Instant,
}

impl Access {
    async fn keep(account: &Account, token: String, expires_in: u64) {
        let until = Instant::now() + Duration::from_secs(expires_in);
        *ACCESS.lock().await = Some(Access { client_id: account.client_id.clone(), token, until });
    }

    /// A token that is good for a minute more, renewed from the saved refresh token when the one
    /// in hand is not.
    async fn token() -> Result<String, Failure> {
        let account =
            Account::saved().ok_or_else(|| Failure::new("llm_sign_in_required", "Not signed in with ChatGPT."))?;
        let mut access = ACCESS.lock().await;
        if let Some(held) = access.as_ref()
            && held.client_id == account.client_id
            && Instant::now() + Duration::from_secs(60) < held.until
        {
            return Ok(held.token.clone());
        }
        let discovery = Discovery::fetch().await?;
        let tokens = post_token(
            &discovery.token_endpoint,
            &[
                ("grant_type", "refresh_token"),
                ("client_id", &account.client_id),
                ("refresh_token", &account.refresh_token),
                ("resource", RESOURCE),
            ],
        )
        .await
        .map_err(|(failure, error)| match error.as_str() {
            "invalid_grant" => Failure::new("llm_signed_out", failure.message),
            _ => failure,
        })?;
        if !tokens.refresh_token.is_empty() && tokens.refresh_token != account.refresh_token {
            let renewed = Account { refresh_token: tokens.refresh_token.clone(), ..account.clone() };
            if let Err(error) = secrets::write(Secret::ChatGpt, &renewed.secret()) {
                log::error!("keeping the renewed ChatGPT sign-in: {error}");
            }
        }
        let until = Instant::now() + Duration::from_secs(tokens.expires_in);
        *access = Some(Access { client_id: account.client_id, token: tokens.access_token.clone(), until });
        Ok(tokens.access_token)
    }

    async fn forget(token: &str) {
        let mut access = ACCESS.lock().await;
        if access.as_ref().is_some_and(|held| held.token == token) {
            *access = None;
        }
    }
}

/// Sends `request` with the account's token, once more with a renewed one when OpenAI no
/// longer takes it.
async fn send(request: impl Fn() -> HttpRequest) -> Result<HttpResponse, Failure> {
    for again in [true, false] {
        let token = Access::token().await?;
        let response = fetch(request().header("Authorization", format!("Bearer {token}"))).await.map_err(network)?;
        if response.status() != 401 {
            return Ok(response);
        }
        Access::forget(&token).await;
        if !again {
            break;
        }
    }
    Err(Failure::new("llm_signed_out", "OpenAI no longer takes this sign-in."))
}

fn refused(response: &HttpResponse) -> Failure {
    Failure::llm(response.status(), &response.text())
}

/// The models the plan offers, in OpenAI's order.
pub(crate) async fn models() -> Result<Vec<String>, Failure> {
    let response = send(|| HttpRequest::get(format!("{RESOURCE}/models")).header("Accept", "application/json")).await?;
    if !response.ok() {
        return Err(refused(&response));
    }
    let body: Value = serde_json::from_slice(&response.body).unwrap_or_default();
    let listed = body["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|model| model["visibility"] == "list")
        .filter_map(|model| model["slug"].as_str());
    let data = body["data"].as_array().into_iter().flatten().filter_map(|model| model["id"].as_str());
    // In OpenAI's own order, which puts the models it recommends first: the first is the one
    // chosen when none is.
    let mut models: Vec<String> = Vec::new();
    for id in listed.chain(data).map(str::trim).filter(|id| !id.is_empty()) {
        if !models.iter().any(|known| known == id) {
            models.push(id.to_owned());
        }
    }
    Ok(models)
}

/// The model's answer to `ask`, asked for as a JSON object when `json`.
pub(crate) async fn respond(model: &str, ask: &Ask, json: bool) -> Result<String, Failure> {
    let mut body = json!({
        "model": model,
        "instructions": ask.system,
        "input": [{"role": "user", "content": ask.prompt}],
        "store": false,
        "stream": true,
    });
    if json {
        body["text"] = json!({"format": {"type": "json_object"}});
    }
    let body = body.to_string();
    let response = send(|| {
        HttpRequest::post(format!("{RESOURCE}/responses"), body.clone())
            .header("Content-Type", "application/json")
            .header("Accept", "text/event-stream")
    })
    .await?;
    if !response.ok() {
        return Err(refused(&response));
    }
    response_text(&response.body)
}

/// The text of a Responses API reply: streamed events, or the whole response.
fn response_text(body: &[u8]) -> Result<String, Failure> {
    let raw = String::from_utf8_lossy(body);
    let events: Vec<Value> = raw
        .lines()
        .filter_map(|line| line.strip_prefix("data:"))
        .filter_map(|data| serde_json::from_str(data.trim()).ok())
        .collect();
    let mut deltas = String::new();
    let mut text = None;
    for event in &events {
        match event["type"].as_str().unwrap_or_default() {
            "response.output_text.delta" => deltas.push_str(event["delta"].as_str().unwrap_or_default()),
            "response.completed" => text = Some(output_text(&event["response"])),
            "response.failed" | "error" => {
                let said = event["response"]["error"]["message"].as_str().or_else(|| event["message"].as_str());
                return Err(Failure {
                    code: "llm_server_failure".into(),
                    message: said.unwrap_or("The model could not answer.").chars().take(300).collect(),
                    retryable: true,
                });
            }
            "response.incomplete" => {
                let reason = event["response"]["incomplete_details"]["reason"].as_str().unwrap_or_default();
                let code = if reason == "max_output_tokens" { "llm_invalid_response" } else { "llm_plan_limit" };
                return Err(Failure::new(code, format!("The answer stopped early ({reason}).")));
            }
            _ => {}
        }
    }
    if events.is_empty() {
        text = serde_json::from_str::<Value>(&raw).ok().map(|whole| output_text(&whole));
    }
    Some(text.filter(|text| !text.trim().is_empty()).unwrap_or(deltas).trim().to_owned())
        .filter(|text| !text.is_empty())
        .ok_or_else(|| Failure::new("llm_invalid_response", "The reply had no text."))
}

fn output_text(response: &Value) -> String {
    response["output"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|item| item["type"] == "message")
        .flat_map(|item| item["content"].as_array().into_iter().flatten())
        .filter(|part| part["type"] == "output_text")
        .filter_map(|part| part["text"].as_str())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streamed_and_whole_responses_give_the_same_text() {
        let streamed = concat!(
            "event: response.output_text.delta\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"{\\\"a\\\":\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\" 1}\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n",
        );
        assert_eq!(response_text(streamed.as_bytes()).unwrap(), "{\"a\": 1}");
        let whole = r#"{"output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":" {\"a\": 1} "}]}]}"#;
        assert_eq!(response_text(whole.as_bytes()).unwrap(), "{\"a\": 1}");
    }

    #[test]
    fn a_response_that_fails_or_stops_early_is_an_error() {
        let failed = "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"overloaded\"}}}\n";
        let failure = response_text(failed.as_bytes()).unwrap_err();
        assert_eq!((failure.code.as_str(), failure.message.as_str()), ("llm_server_failure", "overloaded"));
        let limited =
            "data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"usage\"}}}\n";
        assert_eq!(response_text(limited.as_bytes()).unwrap_err().code, "llm_plan_limit");
        assert_eq!(response_text(b"").unwrap_err().code, "llm_invalid_response");
    }

    #[test]
    fn only_this_loopbacks_callback_is_read() {
        let head = "GET /auth/callback?code=c%2B1&state=s HTTP/1.1\r\nHost: 127.0.0.1:1455\r\n\r\n";
        let query = Callback::read(head, 1455).unwrap();
        assert_eq!((query["code"].as_str(), query["state"].as_str()), ("c+1", "s"));
        assert!(Callback::read(head, 1456).is_none(), "another port");
        assert!(Callback::read("GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1:1455\r\n\r\n", 1455).is_none());
        assert!(Callback::read("POST /auth/callback HTTP/1.1\r\nHost: 127.0.0.1:1455\r\n\r\n", 1455).is_none());
        let rebound = "GET /auth/callback?state=s HTTP/1.1\r\nHost: evil.example:1455\r\n\r\n";
        assert!(Callback::read(rebound, 1455).is_none(), "a page on another site reaching the loopback");
    }

    #[test]
    fn an_identity_token_must_be_this_sign_ins() {
        let claims = |value: Value| value.as_object().unwrap().clone();
        let good = claims(json!({"iss": ISSUER, "aud": ["app_1"], "exp": 1000, "nonce": "n"}));
        assert!(check_claims(&good, "app_1", "n", 900).is_ok());
        assert!(check_claims(&good, "app_2", "n", 900).is_err(), "another app");
        assert!(check_claims(&good, "app_1", "m", 900).is_err(), "another sign-in");
        assert!(check_claims(&good, "app_1", "n", 2000).is_err(), "expired");
        let elsewhere = claims(json!({"iss": "https://example.com", "aud": "app_1", "exp": 1000, "nonce": "n"}));
        assert!(check_claims(&elsewhere, "app_1", "n", 900).is_err(), "another issuer");
    }

    #[test]
    fn a_registration_is_a_real_client_id() {
        assert!(valid_client_id("app_abc-1.2"));
        assert!(!valid_client_id("dynamic_agent_client"));
        assert!(!valid_client_id("a b"));
        assert!(!valid_client_id("abc"));
    }
}
