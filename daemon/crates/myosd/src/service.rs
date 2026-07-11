use crate::pb;
use crate::pb::agent_server::Agent;
use crate::providers;
use crate::state::{ProviderConfig, Store};
use std::collections::HashMap;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status, Streaming};

type Conversations = Arc<Mutex<HashMap<String, Vec<providers::Turn>>>>;

pub struct AgentService {
    store: Arc<Store>,
    conversations: Conversations,
}

impl AgentService {
    pub fn new(store: Arc<Store>) -> Self {
        Self {
            store,
            conversations: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

fn device_profile() -> pb::DeviceProfile {
    let agent_toml = std::fs::read_to_string("/etc/myos/agent.toml")
        .ok()
        .and_then(|t| t.parse::<toml::Table>().ok());
    let lookup = |section: &str, key: &str| -> Option<String> {
        agent_toml
            .as_ref()?
            .get(section)?
            .get(key)?
            .as_str()
            .map(String::from)
    };
    let hostname = std::fs::read_to_string("/etc/hostname")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "myos".into());
    let os_version = std::fs::read_to_string("/usr/lib/myos/os-release")
        .ok()
        .and_then(|t| {
            t.lines()
                .find_map(|l| l.strip_prefix("IMAGE_VERSION=").map(String::from))
        })
        .unwrap_or_else(|| "dev".into());
    pb::DeviceProfile {
        agent_name: lookup("agent", "name").unwrap_or_else(|| "MyOS".into()),
        device_name: lookup("device", "name").unwrap_or(hostname),
        form_factor: pb::FormFactor::Desktop as i32,
        os_version,
        locale: std::env::var("LANG").unwrap_or_else(|_| "en_US.UTF-8".into()),
        timezone: std::fs::read_link("/etc/localtime")
            .ok()
            .and_then(|p| {
                let p = p.to_string_lossy().into_owned();
                p.split_once("zoneinfo/").map(|(_, tz)| tz.to_string())
            })
            .unwrap_or_else(|| "UTC".into()),
    }
}

fn system_prompt() -> String {
    let p = device_profile();
    format!(
        "You are {agent}, the built-in assistant of MyOS, an AI-native operating system. \
         You are running on the device \"{device}\" (MyOS {ver}). \
         You currently have no OS tools connected (they arrive in a future update), so answer \
         conversationally and be upfront when an action requires tools you do not yet have. \
         Be concise and friendly.",
        agent = p.agent_name,
        device = p.device_name,
        ver = p.os_version,
    )
}

fn delta_event(text: String) -> pb::ServerEvent {
    pb::ServerEvent {
        event: Some(pb::server_event::Event::TextDelta(pb::TextDelta { text })),
    }
}

fn error_event(code: &str, message: String) -> pb::ServerEvent {
    pb::ServerEvent {
        event: Some(pb::server_event::Event::Error(pb::Error {
            code: code.into(),
            message,
            retryable: true,
        })),
    }
}

fn turn_done(conversation_id: String) -> pb::ServerEvent {
    pb::ServerEvent {
        event: Some(pb::server_event::Event::TurnDone(pb::TurnDone {
            conversation_id,
            turn_id: String::new(),
        })),
    }
}

type EventStream =
    Pin<Box<dyn tokio_stream::Stream<Item = Result<pb::ServerEvent, Status>> + Send>>;

#[tonic::async_trait]
impl Agent for AgentService {
    type ChatStream = EventStream;

    async fn chat(
        &self,
        request: Request<Streaming<pb::ClientEvent>>,
    ) -> Result<Response<Self::ChatStream>, Status> {
        let mut inbound = request.into_inner();
        let (tx, rx) = mpsc::channel::<Result<pb::ServerEvent, Status>>(64);
        let store = self.store.clone();
        let conversations = self.conversations.clone();

        tokio::spawn(async move {
            // M1: turns are processed sequentially; a CancelTurn queued behind a
            // running turn takes effect when the client drops the stream instead.
            while let Ok(Some(ev)) = inbound.message().await {
                let Some(pb::client_event::Event::Message(msg)) = ev.event else {
                    continue;
                };
                let conv_id = if msg.conversation_id.is_empty() {
                    "default".to_string()
                } else {
                    msg.conversation_id.clone()
                };

                let history = {
                    let mut all = conversations.lock().unwrap();
                    let conv = all.entry(conv_id.clone()).or_default();
                    conv.push(("user".into(), msg.text.clone()));
                    conv.clone()
                };

                let cfg = store.get();
                let provider = cfg
                    .selected_provider
                    .as_ref()
                    .and_then(|id| cfg.providers.get(id).map(|p| (id.clone(), p.clone())));

                match provider {
                    None => {
                        let reply = format!(
                            "No AI provider is connected yet. Tap the ⚡ provider button and \
                             paste an API key to bring me to life.\n\nEcho: {}",
                            msg.text
                        );
                        conversations
                            .lock()
                            .unwrap()
                            .get_mut(&conv_id)
                            .unwrap()
                            .push(("assistant".into(), reply.clone()));
                        if tx.send(Ok(delta_event(reply))).await.is_err() {
                            return;
                        }
                        if tx.send(Ok(turn_done(conv_id))).await.is_err() {
                            return;
                        }
                    }
                    Some((id, pc)) => {
                        let model = pc
                            .model
                            .clone()
                            .or_else(|| providers::default_model(&id).map(String::from))
                            .unwrap_or_default();
                        let mut deltas = providers::stream_chat(
                            &id,
                            &pc.api_key,
                            &model,
                            &system_prompt(),
                            history,
                        );
                        let mut full = String::new();
                        while let Some(item) = deltas.recv().await {
                            match item {
                                Ok(text) => {
                                    full.push_str(&text);
                                    if tx.send(Ok(delta_event(text))).await.is_err() {
                                        return;
                                    }
                                }
                                Err(e) => {
                                    let _ = tx
                                        .send(Ok(error_event("provider_error", e.to_string())))
                                        .await;
                                    break;
                                }
                            }
                        }
                        if !full.is_empty() {
                            conversations
                                .lock()
                                .unwrap()
                                .get_mut(&conv_id)
                                .unwrap()
                                .push(("assistant".into(), full));
                        }
                        if tx.send(Ok(turn_done(conv_id))).await.is_err() {
                            return;
                        }
                    }
                }
            }
        });

        Ok(Response::new(Box::pin(ReceiverStream::new(rx))))
    }

    async fn get_device_profile(
        &self,
        _request: Request<()>,
    ) -> Result<Response<pb::DeviceProfile>, Status> {
        Ok(Response::new(device_profile()))
    }

    async fn list_providers(
        &self,
        _request: Request<()>,
    ) -> Result<Response<pb::ProviderList>, Status> {
        let cfg = self.store.get();
        let providers = providers::PROVIDERS
            .iter()
            .map(|p| pb::Provider {
                id: p.id.into(),
                display_name: p.name.into(),
                connected: cfg.providers.contains_key(p.id),
                auth_kind: pb::AuthKind::ApiKey as i32,
            })
            .collect();
        Ok(Response::new(pb::ProviderList {
            providers,
            selected_provider_id: cfg.selected_provider.unwrap_or_default(),
        }))
    }

    type ConnectProviderStream = EventStream2;

    async fn connect_provider(
        &self,
        request: Request<pb::ConnectRequest>,
    ) -> Result<Response<Self::ConnectProviderStream>, Status> {
        let req = request.into_inner();
        let provider_id = req.provider_id.clone();
        let Some(pb::connect_request::Credential::ApiKey(api_key)) = req.credential else {
            return Err(Status::invalid_argument(
                "only API-key connection is supported in M1",
            ));
        };
        if !providers::PROVIDERS.iter().any(|p| p.id == provider_id) {
            return Err(Status::not_found(format!(
                "unknown provider '{provider_id}'"
            )));
        }

        let store = self.store.clone();
        let (tx, rx) = mpsc::channel::<Result<pb::ConnectProgress, Status>>(8);
        tokio::spawn(async move {
            let _ = tx
                .send(Ok(pb::ConnectProgress {
                    state: pb::ConnectState::Validating as i32,
                    message: "Checking the key with the provider…".into(),
                    ..Default::default()
                }))
                .await;
            match providers::validate_key(&provider_id, &api_key).await {
                Ok(()) => {
                    let saved = store.update(|c| {
                        c.providers.insert(
                            provider_id.clone(),
                            ProviderConfig {
                                api_key: api_key.clone(),
                                model: providers::default_model(&provider_id).map(String::from),
                            },
                        );
                        if c.selected_provider.is_none() {
                            c.selected_provider = Some(provider_id.clone());
                        }
                    });
                    let progress = match saved {
                        Ok(()) => pb::ConnectProgress {
                            state: pb::ConnectState::Connected as i32,
                            message: "Connected.".into(),
                            ..Default::default()
                        },
                        Err(e) => pb::ConnectProgress {
                            state: pb::ConnectState::Failed as i32,
                            message: format!("Key was valid but saving failed: {e}"),
                            ..Default::default()
                        },
                    };
                    let _ = tx.send(Ok(progress)).await;
                }
                Err(e) => {
                    let _ = tx
                        .send(Ok(pb::ConnectProgress {
                            state: pb::ConnectState::Failed as i32,
                            message: e.to_string(),
                            ..Default::default()
                        }))
                        .await;
                }
            }
        });
        Ok(Response::new(Box::pin(ReceiverStream::new(rx))))
    }

    async fn select_provider(
        &self,
        request: Request<pb::ProviderId>,
    ) -> Result<Response<()>, Status> {
        let id = request.into_inner().id;
        let cfg = self.store.get();
        if !cfg.providers.contains_key(&id) {
            return Err(Status::failed_precondition(format!(
                "provider '{id}' is not connected"
            )));
        }
        self.store
            .update(|c| c.selected_provider = Some(id))
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(()))
    }

    async fn list_models(
        &self,
        request: Request<pb::ProviderId>,
    ) -> Result<Response<pb::ModelList>, Status> {
        let id = request.into_inner().id;
        let cfg = self.store.get();
        let selected = cfg
            .providers
            .get(&id)
            .and_then(|p| p.model.clone())
            .or_else(|| providers::default_model(&id).map(String::from))
            .unwrap_or_default();
        let models = providers::models(&id)
            .iter()
            .map(|m| pb::Model {
                id: m.id.into(),
                display_name: m.name.into(),
            })
            .collect();
        Ok(Response::new(pb::ModelList {
            models,
            selected_model_id: selected,
        }))
    }

    async fn select_model(
        &self,
        request: Request<pb::SelectModelRequest>,
    ) -> Result<Response<()>, Status> {
        let req = request.into_inner();
        if !providers::models(&req.provider_id)
            .iter()
            .any(|m| m.id == req.model_id)
        {
            return Err(Status::not_found(format!(
                "model '{}' is not offered by '{}'",
                req.model_id, req.provider_id
            )));
        }
        self.store
            .update(|c| {
                if let Some(p) = c.providers.get_mut(&req.provider_id) {
                    p.model = Some(req.model_id.clone());
                }
            })
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(()))
    }

    type GetAuditLogStream = AuditStream;

    async fn get_audit_log(
        &self,
        _request: Request<pb::AuditQuery>,
    ) -> Result<Response<Self::GetAuditLogStream>, Status> {
        Ok(Response::new(Box::pin(tokio_stream::empty())))
    }

    async fn onboard(&self, _request: Request<pb::OnboardConfig>) -> Result<Response<()>, Status> {
        Err(Status::unimplemented("onboarding lands in M3"))
    }
}

type EventStream2 =
    Pin<Box<dyn tokio_stream::Stream<Item = Result<pb::ConnectProgress, Status>> + Send>>;
type AuditStream = Pin<Box<dyn tokio_stream::Stream<Item = Result<pb::AuditEntry, Status>> + Send>>;
