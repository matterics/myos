//! Provider adapters: raw HTTP against the Anthropic Messages API and
//! OpenAI-compatible chat completions. No SDKs — parse SSE by hand.

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use tokio::sync::mpsc;

pub struct ProviderInfo {
    pub id: &'static str,
    pub name: &'static str,
}

pub const PROVIDERS: &[ProviderInfo] = &[
    ProviderInfo {
        id: "anthropic",
        name: "Anthropic (Claude)",
    },
    ProviderInfo {
        id: "openai",
        name: "OpenAI",
    },
    ProviderInfo {
        id: "opencode",
        name: "OpenCode CLI",
    },
    ProviderInfo {
        id: "local",
        name: "Local (Ollama / OpenAI-Compatible)",
    },
];

pub struct ModelInfo {
    pub id: &'static str,
    pub name: &'static str,
}

pub fn models(provider: &str) -> &'static [ModelInfo] {
    match provider {
        "anthropic" => &[
            ModelInfo {
                id: "claude-opus-4-8",
                name: "Claude Opus 4.8",
            },
            ModelInfo {
                id: "claude-fable-5",
                name: "Claude Fable 5",
            },
            ModelInfo {
                id: "claude-sonnet-5",
                name: "Claude Sonnet 5",
            },
            ModelInfo {
                id: "claude-haiku-4-5",
                name: "Claude Haiku 4.5",
            },
        ],
        "openai" => &[
            ModelInfo {
                id: "gpt-4o",
                name: "GPT-4o",
            },
            ModelInfo {
                id: "gpt-4o-mini",
                name: "GPT-4o mini",
            },
        ],
        // Local models come from the running Ollama instance (fetch_models);
        // a static list here would offer models that are not installed.
        "local" => &[],
        _ => &[],
    }
}

pub fn default_model(provider: &str) -> Option<&'static str> {
    models(provider).first().map(|m| m.id)
}

pub async fn fetch_models(provider: &str, api_key: &str) -> Option<Vec<(String, String)>> {
    if provider == "opencode" {
        // Try fetching from the OpenCode CLI
        if let Ok(output) = std::process::Command::new("opencode").arg("models").output() {
            let out_str = String::from_utf8_lossy(&output.stdout);
            let mut res = Vec::new();
            for line in out_str.lines() {
                let trimmed = line.trim();
                if !trimmed.is_empty() && !trimmed.starts_with("Error") {
                    res.push((trimmed.to_string(), trimmed.to_string()));
                }
            }
            if !res.is_empty() {
                return Some(res);
            }
        }
        // Fallback: let OpenCode use its own configured default model.
        return Some(vec![(String::new(), "OpenCode default".into())]);
    }
    
    if provider == "local" {
        let base_url = local_base_url(api_key);
        let resp = reqwest::Client::new().get(format!("{base_url}/models")).send().await.ok()?;
        let json: serde_json::Value = resp.json().await.ok()?;
        if let Some(data) = json["data"].as_array() {
            // An empty list is a real answer (Ollama up, nothing installed).
            return Some(
                data.iter()
                    .filter_map(|item| item["id"].as_str())
                    .map(|id| (id.to_string(), id.to_string()))
                    .collect(),
            );
        }
    }
    None
}

/// The model a chat/loop run should use for `provider`, resolving local
/// models against what Ollama actually has installed.
pub async fn effective_model(
    provider: &str,
    api_key: &str,
    configured: Option<&str>,
) -> Result<String> {
    if provider == "local" {
        return resolve_local_model(api_key, configured).await;
    }
    // OpenCode picks its own default model when none is passed.
    if provider == "opencode" {
        return Ok(configured.unwrap_or_default().to_string());
    }
    configured
        .map(String::from)
        .or_else(|| default_model(provider).map(String::from))
        .ok_or_else(|| anyhow!("no model selected for provider '{provider}'"))
}

pub fn local_base_url(api_key: &str) -> String {
    if api_key.is_empty() {
        "http://127.0.0.1:11434/v1".into()
    } else {
        api_key.trim_end_matches('/').to_string()
    }
}

/// Resolve which local model to use: the configured one if installed,
/// otherwise the first installed model. Errors when none are installed.
pub async fn resolve_local_model(api_key: &str, want: Option<&str>) -> Result<String> {
    let installed = fetch_models("local", api_key)
        .await
        .ok_or_else(|| anyhow!("The local AI runtime (Ollama) is not reachable."))?;
    if let Some(want) = want {
        if installed.iter().any(|(id, _)| id == want) {
            return Ok(want.to_string());
        }
    }
    installed
        .first()
        .map(|(id, _)| id.clone())
        .ok_or_else(|| {
            anyhow!(
                "No local models are installed. Open the terminal (Ctrl+Shift+T) and run \
                 `ollama pull gemma:2b`, then try again."
            )
        })
}

/// Cheap key validation: list models. Free on both APIs, no tokens spent.
pub async fn validate_key(provider: &str, api_key: &str) -> Result<()> {
    let client = reqwest::Client::new();
    let resp = match provider {
        "opencode" => {
            // No key to validate (OpenCode manages its own auth) — just make
            // sure the CLI is actually present.
            return match std::process::Command::new("opencode").arg("--version").output() {
                Ok(out) if out.status.success() => Ok(()),
                _ => bail!(
                    "The OpenCode CLI is not installed. Open the terminal (Ctrl+Shift+T) and run \
                     `npm install -g opencode-ai`, then run `opencode auth login`."
                ),
            };
        }
        "anthropic" => {
            client
                .get("https://api.anthropic.com/v1/models")
                .header("x-api-key", api_key)
                .header("anthropic-version", "2023-06-01")
                .send()
                .await?
        }
        "openai" => {
            client
                .get("https://api.openai.com/v1/models")
                .bearer_auth(api_key)
                .send()
                .await?
        }
        "local" => {
            let base_url = if api_key.is_empty() {
                "http://127.0.0.1:11434/v1"
            } else {
                api_key.trim_end_matches('/')
            };
            client
                .get(format!("{base_url}/models"))
                .send()
                .await?
        }
        other => bail!("unknown provider '{other}'"),
    };
    if resp.status().is_success() {
        Ok(())
    } else {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        bail!(
            "{provider} rejected the key ({status}): {}",
            truncate(&body, 200)
        );
    }
}

/// One conversation turn: (role, text) where role is "user" or "assistant".
pub type Turn = (String, String);

/// Streams assistant text deltas. Channel closing = turn complete.
pub fn stream_chat(
    provider: &str,
    api_key: &str,
    model: &str,
    system: &str,
    history: Vec<Turn>,
) -> mpsc::Receiver<Result<String>> {
    let (tx, rx) = mpsc::channel(64);
    let provider = provider.to_string();
    let api_key = api_key.to_string();
    let model = model.to_string();
    let system = system.to_string();
    tokio::spawn(async move {
        let result = match provider.as_str() {
            "anthropic" => anthropic_chat(&tx, &api_key, &model, &system, &history).await,
            "opencode" => {
                opencode_chat(&tx, &model, &system, &history).await
            }
            "openai" => openai_chat(&tx, "https://api.openai.com/v1", &api_key, &model, &system, &history).await,
            "local" => {
                openai_chat(&tx, &local_base_url(&api_key), "", &model, &system, &history).await
            }
            other => Err(anyhow!("unknown provider '{other}'")),
        };
        if let Err(e) = result {
            let _ = tx.send(Err(e)).await;
        }
    });
    rx
}

async fn opencode_chat(
    tx: &mpsc::Sender<Result<String>>,
    model: &str,
    _system: &str,
    history: &[Turn],
) -> Result<()> {
    use tokio::process::Command;
    use std::process::Stdio;
    use tokio::io::AsyncReadExt;

    let last_user_msg = history
        .iter()
        .rev()
        .find(|(role, _)| role == "user")
        .map(|(_, t)| t)
        .unwrap_or(&String::new())
        .clone();

    // Non-interactive run: `opencode run [message] -m provider/model`
    let mut cmd = Command::new("opencode");
    cmd.arg("run");
    if !model.is_empty() {
        cmd.arg("--model").arg(model);
    }
    let mut child = cmd
        .arg(&last_user_msg)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("Failed to start the OpenCode CLI. It ships with MyOS; if missing, run `npm install -g opencode-ai`.")?;

    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let mut buf = vec![0; 1024];
    let mut got_output = false;

    while let Ok(n) = stdout.read(&mut buf).await {
        if n == 0 {
            break;
        }
        got_output = true;
        let text = String::from_utf8_lossy(&buf[..n]).to_string();
        if tx.send(Ok(text)).await.is_err() {
            break;
        }
    }

    let status = child.wait().await;
    if !got_output {
        let mut err_text = String::new();
        let _ = stderr.read_to_string(&mut err_text).await;
        let failed = !matches!(&status, Ok(s) if s.success());
        if failed || !err_text.trim().is_empty() {
            bail!(
                "OpenCode produced no reply{}",
                if err_text.trim().is_empty() {
                    String::new()
                } else {
                    format!(": {}", err_text.trim())
                }
            );
        }
    }
    Ok(())
}

async fn anthropic_chat(
    tx: &mpsc::Sender<Result<String>>,
    api_key: &str,
    model: &str,
    system: &str,
    history: &[Turn],
) -> Result<()> {
    let messages: Vec<Value> = history
        .iter()
        .map(|(role, text)| json!({"role": role, "content": text}))
        .collect();
    let body = json!({
        "model": model,
        "max_tokens": 8192,
        "stream": true,
        "system": system,
        "messages": messages,
    });
    let resp = reqwest::Client::new()
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .json(&body)
        .send()
        .await
        .context("reach api.anthropic.com")?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        bail!("Anthropic API error ({status}): {}", truncate(&body, 300));
    }

    let mut refused = false;
    sse_lines(
        resp,
        |data| {
            let v: Value = match serde_json::from_str(data) {
                Ok(v) => v,
                Err(_) => return SseFlow::Continue,
            };
            match v["type"].as_str() {
                Some("content_block_delta") => {
                    if v["delta"]["type"] == "text_delta" {
                        if let Some(text) = v["delta"]["text"].as_str() {
                            return SseFlow::Emit(text.to_string());
                        }
                    }
                    SseFlow::Continue
                }
                Some("message_delta") => {
                    if v["delta"]["stop_reason"] == "refusal" {
                        refused = true;
                    }
                    SseFlow::Continue
                }
                Some("error") => SseFlow::Fail(anyhow!(
                    "Anthropic stream error: {}",
                    v["error"]["message"].as_str().unwrap_or("unknown")
                )),
                Some("message_stop") => SseFlow::Stop,
                _ => SseFlow::Continue,
            }
        },
        tx,
    )
    .await?;

    if refused {
        let _ = tx
            .send(Ok(
                "\n\n_(The provider declined this request for safety reasons.)_".into(),
            ))
            .await;
    }
    Ok(())
}

async fn openai_chat(
    tx: &mpsc::Sender<Result<String>>,
    base_url: &str,
    api_key: &str,
    model: &str,
    system: &str,
    history: &[Turn],
) -> Result<()> {
    let mut messages: Vec<Value> = vec![json!({"role": "system", "content": system})];
    messages.extend(
        history
            .iter()
            .map(|(role, text)| json!({"role": role, "content": text})),
    );
    let body = json!({
        "model": model,
        "stream": true,
        "messages": messages,
    });
    let mut req = reqwest::Client::new()
        .post(format!("{base_url}/chat/completions"));
    
    if !api_key.is_empty() {
        req = req.bearer_auth(api_key);
    }
    
    let resp = req
        .json(&body)
        .send()
        .await
        .context(format!("reach {base_url}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        bail!("OpenAI API error ({status}): {}", truncate(&body, 300));
    }

    sse_lines(
        resp,
        |data| {
            if data == "[DONE]" {
                return SseFlow::Stop;
            }
            let v: Value = match serde_json::from_str(data) {
                Ok(v) => v,
                Err(_) => return SseFlow::Continue,
            };
            if let Some(text) = v["choices"][0]["delta"]["content"].as_str() {
                return SseFlow::Emit(text.to_string());
            }
            SseFlow::Continue
        },
        tx,
    )
    .await
}

enum SseFlow {
    Continue,
    Emit(String),
    Stop,
    Fail(anyhow::Error),
}

/// Reads an SSE response body, invoking `handle` for each `data:` line.
async fn sse_lines(
    resp: reqwest::Response,
    mut handle: impl FnMut(&str) -> SseFlow,
    tx: &mpsc::Sender<Result<String>>,
) -> Result<()> {
    use futures_util::StreamExt;
    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    'outer: while let Some(chunk) = stream.next().await {
        let chunk = chunk.context("read SSE chunk")?;
        buf.extend_from_slice(&chunk);
        while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buf.drain(..=pos).collect();
            let line = String::from_utf8_lossy(&line);
            let line = line.trim_end();
            let Some(data) = line
                .strip_prefix("data: ")
                .or_else(|| line.strip_prefix("data:"))
            else {
                continue;
            };
            match handle(data.trim()) {
                SseFlow::Continue => {}
                SseFlow::Emit(text) => {
                    if tx.send(Ok(text)).await.is_err() {
                        break 'outer; // client went away
                    }
                }
                SseFlow::Stop => break 'outer,
                SseFlow::Fail(e) => return Err(e),
            }
        }
    }
    Ok(())
}

fn truncate(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) {
        Some((idx, _)) => &s[..idx],
        None => s,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anthropic_catalog_has_a_default() {
        assert_eq!(default_model("anthropic"), Some("claude-opus-4-8"));
        assert!(models("anthropic").iter().any(|m| m.id == "claude-fable-5"));
    }

    #[test]
    fn unknown_provider_has_no_models() {
        assert!(models("acme").is_empty());
        assert_eq!(default_model("acme"), None);
    }
}
