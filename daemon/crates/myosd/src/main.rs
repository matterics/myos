mod pb {
    tonic::include_proto!("myos.agent.v1");
}
mod loops;
mod providers;
mod service;
mod state;

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::net::UnixListener;
use tokio_stream::wrappers::UnixListenerStream;

#[tokio::main]
async fn main() -> Result<()> {
    let socket = socket_path();
    serve(&socket).await
}

fn socket_path() -> PathBuf {
    std::env::var_os("MYOS_AGENT_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(default_socket_path)
}

fn default_socket_path() -> PathBuf {
    PathBuf::from("/run/myos/agent.sock")
}

async fn serve(socket: &Path) -> Result<()> {
    if let Some(parent) = socket.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .with_context(|| format!("create socket directory {}", parent.display()))?;
    }
    if tokio::fs::try_exists(socket).await? {
        tokio::fs::remove_file(socket).await?;
    }

    let listener = UnixListener::bind(socket)
        .with_context(|| format!("bind agent socket {}", socket.display()))?;

    // M1 live image runs a single interactive user; tighten to a group in M2.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o666))?;
    }

    println!("myosd listening on {}", socket.display());

    let store = Arc::new(state::Store::load().context("load provider config")?);
    loops::spawn_scheduler(store.clone());
    let svc = service::AgentService::new(store);

    tonic::transport::Server::builder()
        .add_service(pb::agent_server::AgentServer::new(svc))
        .serve_with_incoming_shutdown(UnixListenerStream::new(listener), async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .context("serve gRPC")?;

    let _ = tokio::fs::remove_file(socket).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_socket_matches_the_ipc_contract() {
        assert_eq!(default_socket_path(), PathBuf::from("/run/myos/agent.sock"));
    }

    #[tokio::test]
    async fn creates_parent_and_socket() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("nested/agent.sock");
        let parent = socket.parent().unwrap();
        tokio::fs::create_dir_all(parent).await.unwrap();
        let listener = UnixListener::bind(&socket).unwrap();
        assert!(socket.exists());
        drop(listener);
    }
}
