use crate::loops;
use crate::pb;
use crate::pb::agent_server::Agent;
use crate::providers;
use crate::state::{LoopDef, LoopRunRecord, ProjectDef, ProviderConfig, Store};
use std::pin::Pin;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status, Streaming};

pub struct AgentService {
    store: Arc<Store>,
}

impl AgentService {
    pub fn new(store: Arc<Store>) -> Self {
        Self { store }
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

    // Centralize context window for all LLMs in the system
    let mut system_context = String::new();
    system_context.push_str(&format!("- Active OS: MyOS {}\n", p.os_version));
    system_context.push_str(&format!(
        "- Current Time: {}\n",
        chrono::Local::now().to_rfc2822()
    ));

    format!(
        "You are {agent}, the built-in assistant and operator of MyOS, an AI-native operating \
         system. You are running on the device \"{device}\" (MyOS {ver}) with full authority \
         to operate it.\n\
         To act on the system, emit a fenced code block tagged `myos-run` containing one bash \
         command; MyOS executes it immediately and feeds the output back to you so you can \
         continue. Example:\n\
         ```myos-run\ntimedatectl set-timezone Asia/Kolkata\n```\n\
         Act autonomously: when the user asks for something the system can do, run the commands \
         yourself instead of giving the user manual steps, check the output, and reply with a \
         short summary of what you did. Never claim you lack access to the system. \
         MyOS is loop-first: for ongoing or recurring work, suggest a loop from the shell's \
         Loops panel. Be concise and friendly.\n\n\
         [System Context]\n\
         {system_context}",
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

/// Commands the model asked MyOS to run, from ```myos-run fenced blocks.
fn extract_commands(text: &str) -> Vec<String> {
    let mut cmds = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find("```myos-run") {
        let after = &rest[start + "```myos-run".len()..];
        let after = after.strip_prefix('\n').unwrap_or(after);
        let Some(end) = after.find("```") else { break };
        let cmd = after[..end].trim();
        if !cmd.is_empty() {
            cmds.push(cmd.to_string());
        }
        rest = &after[end + 3..];
    }
    cmds
}

/// Execute one agent command on the host and return its combined output.
async fn run_host_command(cmd: &str) -> String {
    let fut = tokio::process::Command::new("bash")
        .arg("-lc")
        .arg(cmd)
        .output();
    let out = match tokio::time::timeout(std::time::Duration::from_secs(120), fut).await {
        Err(_) => return "(command timed out after 120s)".into(),
        Ok(Err(e)) => return format!("(failed to run: {e})"),
        Ok(Ok(out)) => out,
    };
    let mut s = String::from_utf8_lossy(&out.stdout).into_owned();
    let err = String::from_utf8_lossy(&out.stderr);
    if !err.trim().is_empty() {
        s.push_str("\n[stderr]\n");
        s.push_str(&err);
    }
    if !out.status.success() {
        s.push_str(&format!(
            "\n[exit code: {}]",
            out.status.code().unwrap_or(-1)
        ));
    }
    let s = s.trim().to_string();
    if s.is_empty() {
        "(no output — success)".into()
    } else if s.chars().count() > 8000 {
        let mut t: String = s.chars().take(8000).collect();
        t.push_str("…(truncated)");
        t
    } else {
        s
    }
}

/// Cap on model→command→model round trips per user message.
const MAX_AGENT_ITERATIONS: usize = 5;

fn ts(secs: i64) -> Option<prost_types::Timestamp> {
    Some(prost_types::Timestamp {
        seconds: secs,
        nanos: 0,
    })
}

fn loop_to_pb(l: &LoopDef) -> pb::Loop {
    pb::Loop {
        id: l.id.clone(),
        spec: Some(pb::LoopSpec {
            name: l.name.clone(),
            goal: l.goal.clone(),
            interval_minutes: l.interval_minutes,
            project_name: l.project_name.clone().unwrap_or_default(),
            level: l.level as i32,
        }),
        enabled: l.enabled,
        created_at: ts(l.created_at),
        last_run_at: l.last_run_at.and_then(ts),
        run_count: l.run_count,
        project_id: l.project_id.clone().unwrap_or_default(),
    }
}

fn run_to_pb(r: &LoopRunRecord) -> pb::LoopRun {
    let status = match r.finished_at {
        None => pb::LoopRunStatus::Running,
        Some(_) if r.succeeded => pb::LoopRunStatus::Succeeded,
        Some(_) => pb::LoopRunStatus::Failed,
    };
    pb::LoopRun {
        id: r.id.clone(),
        loop_id: r.loop_id.clone(),
        started_at: ts(r.started_at),
        finished_at: r.finished_at.and_then(ts),
        status: status as i32,
        report: r.report.clone(),
    }
}

fn project_to_pb(p: &ProjectDef) -> pb::Project {
    pb::Project {
        id: p.id.clone(),
        name: p.name.clone(),
        path: p.path.clone(),
        created_by_loop_id: p.created_by_loop_id.clone(),
        created_at: ts(p.created_at),
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

        tokio::spawn(async move {
            // Send history on connect if requested? Wait, there's no GetHistory API in proto.
            // Let's just persist turns so the system prompt/history is maintained across reboots.

            while let Ok(Some(ev)) = inbound.message().await {
                let Some(pb::client_event::Event::Message(msg)) = ev.event else {
                    continue;
                };
                let conv_id = if msg.conversation_id.is_empty() {
                    "default".to_string()
                } else {
                    msg.conversation_id.clone()
                };

                // Add user msg to persistent store history
                let mut history = vec![];
                let _ = store.update(|cfg| {
                    let conv = cfg.history.entry(conv_id.clone()).or_default();
                    conv.push(("user".into(), msg.text.clone()));
                    history = conv.clone();
                });

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
                        let _ = store.update(|cfg| {
                            if let Some(conv) = cfg.history.get_mut(&conv_id) {
                                conv.push(("assistant".into(), reply.clone()));
                            }
                        });
                        if tx.send(Ok(delta_event(reply))).await.is_err() {
                            return;
                        }
                        if tx.send(Ok(turn_done(conv_id))).await.is_err() {
                            return;
                        }
                    }
                    Some((id, pc)) => {
                        let model =
                            match providers::effective_model(&id, &pc.api_key, pc.model.as_deref())
                                .await
                            {
                                Ok(m) => {
                                    // Remember the fallback so the model chip matches reality.
                                    if pc.model.as_deref() != Some(m.as_str()) {
                                        let _ = store.update(|c| {
                                            if let Some(p) = c.providers.get_mut(&id) {
                                                p.model = Some(m.clone());
                                            }
                                        });
                                    }
                                    m
                                }
                                Err(e) => {
                                    let _ = tx
                                        .send(Ok(error_event("model_unavailable", e.to_string())))
                                        .await;
                                    if tx.send(Ok(turn_done(conv_id))).await.is_err() {
                                        return;
                                    }
                                    continue;
                                }
                            };
                        let mut iterations = 0usize;
                        'agent: loop {
                            let mut deltas = providers::stream_chat(
                                &id,
                                &pc.api_key,
                                &model,
                                &system_prompt(),
                                history.clone(),
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
                                        break 'agent;
                                    }
                                }
                            }
                            if !full.is_empty() {
                                let _ = store.update(|cfg| {
                                    if let Some(conv) = cfg.history.get_mut(&conv_id) {
                                        conv.push(("assistant".into(), full.clone()));
                                    }
                                });
                                history.push(("assistant".into(), full.clone()));
                            }

                            let commands = extract_commands(&full);
                            if commands.is_empty() || iterations >= MAX_AGENT_ITERATIONS {
                                break;
                            }
                            iterations += 1;

                            let mut results = String::from("[MyOS] Command results:\n");
                            for cmd in commands {
                                let _ = tx.send(Ok(delta_event(format!("\n\n⚙️ `{cmd}`\n")))).await;
                                let output = run_host_command(&cmd).await;
                                let _ = tx
                                    .send(Ok(delta_event(format!("```\n{output}\n```\n\n"))))
                                    .await;
                                results.push_str(&format!("$ {cmd}\n{output}\n\n"));
                            }
                            let _ = store.update(|cfg| {
                                if let Some(conv) = cfg.history.get_mut(&conv_id) {
                                    conv.push(("user".into(), results.clone()));
                                }
                            });
                            history.push(("user".into(), results));
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
                auth_kind: if p.id == "local" {
                    pb::AuthKind::Local as i32
                } else {
                    pb::AuthKind::ApiKey as i32
                },
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
        let dynamic_models = if let Some(p) = cfg.providers.get(&id) {
            providers::fetch_models(&id, &p.api_key).await
        } else {
            None
        };

        let models: Vec<pb::Model> = if let Some(dyn_m) = dynamic_models {
            dyn_m
                .into_iter()
                .map(|(mid, name)| pb::Model {
                    id: mid,
                    display_name: name,
                })
                .collect()
        } else {
            providers::models(&id)
                .iter()
                .map(|m| pb::Model {
                    id: m.id.into(),
                    display_name: m.name.into(),
                })
                .collect()
        };

        let selected = cfg
            .providers
            .get(&id)
            .and_then(|p| p.model.clone())
            .or_else(|| models.first().map(|m| m.id.clone()))
            .unwrap_or_default();

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
        let valid = {
            let cfg = self.store.get();
            if let Some(p) = cfg.providers.get(&req.provider_id) {
                if let Some(dyn_m) = providers::fetch_models(&req.provider_id, &p.api_key).await {
                    dyn_m.iter().any(|(id, _)| *id == req.model_id)
                } else {
                    providers::models(&req.provider_id)
                        .iter()
                        .any(|m| m.id == req.model_id)
                }
            } else {
                providers::models(&req.provider_id)
                    .iter()
                    .any(|m| m.id == req.model_id)
            }
        };

        if !valid {
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

    async fn get_chat_history(
        &self,
        _request: Request<()>,
    ) -> Result<Response<pb::ChatHistoryList>, Status> {
        let cfg = self.store.get();
        let mut sessions = Vec::new();
        for (id, turns) in &cfg.history {
            // Find first user message for preview
            let preview = turns
                .iter()
                .find(|(r, _)| r == "user")
                .map(|(_, t)| {
                    let mut p = t.clone();
                    if p.len() > 60 {
                        p.truncate(57);
                        p.push_str("...");
                    }
                    p
                })
                .unwrap_or_else(|| "Empty chat".into());

            sessions.push(pb::ChatSession {
                id: id.clone(),
                preview,
                last_updated: None, // Simplified timestamp
            });
        }

        // Sort sessions so "default" or newer is at the top if possible, here just returning as-is
        Ok(Response::new(pb::ChatHistoryList { sessions }))
    }

    async fn create_loop(
        &self,
        request: Request<pb::LoopSpec>,
    ) -> Result<Response<pb::Loop>, Status> {
        let spec = request.into_inner();
        if spec.name.trim().is_empty() {
            return Err(Status::invalid_argument("loop name is required"));
        }
        if spec.goal.trim().is_empty() {
            return Err(Status::invalid_argument("loop goal is required"));
        }
        let level = match pb::LoopLevel::try_from(spec.level) {
            Ok(pb::LoopLevel::Assisted) => 2,
            Ok(pb::LoopLevel::Unattended) => 3,
            // Loops start at L1 report-only; higher levels are opt-in per loop.
            _ => 1,
        };
        let def = LoopDef {
            id: loops::new_id("loop"),
            name: spec.name.trim().to_string(),
            goal: spec.goal.trim().to_string(),
            interval_minutes: if spec.interval_minutes == 0 {
                60
            } else {
                spec.interval_minutes
            },
            level,
            enabled: true,
            created_at: chrono::Utc::now().timestamp(),
            last_run_at: None,
            run_count: 0,
            project_name: Some(spec.project_name.trim().to_string()).filter(|s| !s.is_empty()),
            project_id: None,
        };
        let saved = def.clone();
        self.store
            .update(|c| {
                c.loops.insert(saved.id.clone(), saved);
            })
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(loop_to_pb(&def)))
    }

    async fn list_loops(&self, _request: Request<()>) -> Result<Response<pb::LoopList>, Status> {
        let cfg = self.store.get();
        let mut loops: Vec<pb::Loop> = cfg.loops.values().map(loop_to_pb).collect();
        loops.sort_by(|a, b| {
            let (sa, sb) = (
                a.created_at.as_ref().map(|t| t.seconds).unwrap_or(0),
                b.created_at.as_ref().map(|t| t.seconds).unwrap_or(0),
            );
            sb.cmp(&sa)
        });
        Ok(Response::new(pb::LoopList { loops }))
    }

    async fn set_loop_enabled(
        &self,
        request: Request<pb::SetLoopEnabledRequest>,
    ) -> Result<Response<pb::Loop>, Status> {
        let req = request.into_inner();
        let mut updated = None;
        self.store
            .update(|c| {
                if let Some(l) = c.loops.get_mut(&req.id) {
                    l.enabled = req.enabled;
                    updated = Some(l.clone());
                }
            })
            .map_err(|e| Status::internal(e.to_string()))?;
        match updated {
            Some(l) => Ok(Response::new(loop_to_pb(&l))),
            None => Err(Status::not_found(format!("loop '{}' not found", req.id))),
        }
    }

    async fn run_loop_now(
        &self,
        request: Request<pb::LoopId>,
    ) -> Result<Response<pb::LoopRun>, Status> {
        let id = request.into_inner().id;
        let run = loops::run_loop(&self.store, &id)
            .await
            .map_err(|e| Status::internal(format!("{e:#}")))?;
        Ok(Response::new(run_to_pb(&run)))
    }

    async fn delete_loop(&self, request: Request<pb::LoopId>) -> Result<Response<()>, Status> {
        let id = request.into_inner().id;
        let mut existed = false;
        self.store
            .update(|c| {
                existed = c.loops.remove(&id).is_some();
                c.loop_runs.remove(&id);
            })
            .map_err(|e| Status::internal(e.to_string()))?;
        if existed {
            Ok(Response::new(()))
        } else {
            Err(Status::not_found(format!("loop '{id}' not found")))
        }
    }

    async fn get_loop_runs(
        &self,
        request: Request<pb::LoopId>,
    ) -> Result<Response<pb::LoopRunList>, Status> {
        let id = request.into_inner().id;
        let cfg = self.store.get();
        let runs = cfg
            .loop_runs
            .get(&id)
            .map(|rs| rs.iter().rev().map(run_to_pb).collect())
            .unwrap_or_default();
        Ok(Response::new(pb::LoopRunList { runs }))
    }

    async fn list_projects(
        &self,
        _request: Request<()>,
    ) -> Result<Response<pb::ProjectList>, Status> {
        let cfg = self.store.get();
        let mut projects: Vec<pb::Project> = cfg.projects.values().map(project_to_pb).collect();
        projects.sort_by(|a, b| {
            let (sa, sb) = (
                a.created_at.as_ref().map(|t| t.seconds).unwrap_or(0),
                b.created_at.as_ref().map(|t| t.seconds).unwrap_or(0),
            );
            sb.cmp(&sa)
        });
        Ok(Response::new(pb::ProjectList { projects }))
    }
}

type EventStream2 =
    Pin<Box<dyn tokio_stream::Stream<Item = Result<pb::ConnectProgress, Status>> + Send>>;
type AuditStream = Pin<Box<dyn tokio_stream::Stream<Item = Result<pb::AuditEntry, Status>> + Send>>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_myos_run_blocks() {
        let text = "I'll set that now.\n```myos-run\ntimedatectl set-timezone Asia/Kolkata\n```\nthen check:\n```myos-run\ntimedatectl status\n```\ndone";
        assert_eq!(
            extract_commands(text),
            vec![
                "timedatectl set-timezone Asia/Kolkata".to_string(),
                "timedatectl status".to_string(),
            ]
        );
    }

    #[test]
    fn ignores_plain_code_blocks() {
        assert!(extract_commands("```bash\nls\n```").is_empty());
        assert!(extract_commands("no blocks here").is_empty());
        assert!(extract_commands("```myos-run\n   \n```").is_empty());
    }
}
