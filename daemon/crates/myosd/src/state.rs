use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct ProviderConfig {
    pub api_key: String,
    pub model: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Config {
    pub selected_provider: Option<String>,
    #[serde(default)]
    pub providers: HashMap<String, ProviderConfig>,
}

pub struct Store {
    path: PathBuf,
    config: Mutex<Config>,
}

impl Store {
    pub fn load() -> Result<Self> {
        let path = state_dir().join("providers.toml");
        let config = match std::fs::read_to_string(&path) {
            Ok(text) => {
                toml::from_str(&text).with_context(|| format!("parse {}", path.display()))?
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Config::default(),
            Err(e) => return Err(e).with_context(|| format!("read {}", path.display())),
        };
        Ok(Self {
            path,
            config: Mutex::new(config),
        })
    }

    pub fn get(&self) -> Config {
        self.config.lock().unwrap().clone()
    }

    pub fn update(&self, f: impl FnOnce(&mut Config)) -> Result<()> {
        let mut guard = self.config.lock().unwrap();
        f(&mut guard);
        let snapshot = guard.clone();
        drop(guard);
        self.save(&snapshot)
    }

    fn save(&self, cfg: &Config) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create {}", parent.display()))?;
        }
        let text = toml::to_string_pretty(cfg).context("serialize config")?;
        std::fs::write(&self.path, text)
            .with_context(|| format!("write {}", self.path.display()))?;
        // API keys live in this file until the vault (M2) lands.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&self.path, std::fs::Permissions::from_mode(0o600))?;
        }
        Ok(())
    }
}

fn state_dir() -> PathBuf {
    std::env::var_os("MYOS_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/lib/myos"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_config() {
        let dir = tempfile::tempdir().unwrap();
        // Safety: tests in this module are the only env mutators and run serially per-process env.
        unsafe { std::env::set_var("MYOS_STATE_DIR", dir.path()) };
        let store = Store::load().unwrap();
        store
            .update(|c| {
                c.selected_provider = Some("anthropic".into());
                c.providers.insert(
                    "anthropic".into(),
                    ProviderConfig {
                        api_key: "sk-test".into(),
                        model: Some("claude-opus-4-8".into()),
                    },
                );
            })
            .unwrap();
        let reloaded = Store::load().unwrap().get();
        assert_eq!(reloaded.selected_provider.as_deref(), Some("anthropic"));
        assert_eq!(
            reloaded.providers["anthropic"].model.as_deref(),
            Some("claude-opus-4-8")
        );
        unsafe { std::env::remove_var("MYOS_STATE_DIR") };
    }
}
