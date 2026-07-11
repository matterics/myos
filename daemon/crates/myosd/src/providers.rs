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
        _ => &[],
    }
}

pub fn default_model(provider: &str) -> Option<&'static str> {
    models(provider).first().map(|m| m.id)
}

/// Cheap key validation: list models. Free on both APIs, no tokens spent.
pub async fn validate_key(provider: &str, api_key: &str) -> Result<()> {
    let client = reqwest::Client::new();
    let resp = match provider {
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
            "openai" => openai_chat(&tx, &api_key, &model, &system, &history).await,
            other => Err(anyhow!("unknown provider '{other}'")),
        };
        if let Err(e) = result {
            let _ = tx.send(Err(e)).await;
        }
    });
    rx
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
    let resp = reqwest::Client::new()
        .post("https://api.openai.com/v1/chat/completions")
        .bearer_auth(api_key)
        .json(&body)
        .send()
        .await
        .context("reach api.openai.com")?;
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
