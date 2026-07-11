//! Loop engine: loops are MyOS's first-class unit of agent work.
//!
//! A loop is a standing goal executed on a cadence. Projects are never created
//! directly — a loop creates its project on first run and every subsequent run
//! advances it. Modeled on the loop-engineering primitives
//! (github.com/cobusgreyling/loop-engineering): automations/scheduling,
//! state/memory, and a phased autonomy ladder (L1 report → L2 assisted →
//! L3 unattended). M1 executes every loop at L1: runs produce reports only,
//! no tool side effects beyond the loop's own project directory.

use crate::providers;
use crate::state::{LoopDef, LoopRunRecord, MAX_RUNS_PER_LOOP, ProjectDef, Store, state_dir};
use anyhow::{Context, Result, bail};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

static RUN_SEQ: AtomicU64 = AtomicU64::new(0);

pub fn new_id(prefix: &str) -> String {
    let seq = RUN_SEQ.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}-{}-{seq}", chrono::Utc::now().timestamp_millis())
}

fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

pub fn slugify(name: &str) -> String {
    let slug: String = name
        .to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect();
    let slug = slug.trim_matches('-').to_string();
    if slug.is_empty() {
        "project".into()
    } else {
        slug
    }
}

pub fn projects_dir() -> PathBuf {
    state_dir().join("projects")
}

/// Background scheduler: wakes every 30s and runs any enabled loop whose
/// cadence has elapsed. Runs execute sequentially to keep provider load sane.
pub fn spawn_scheduler(store: Arc<Store>) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(30));
        loop {
            tick.tick().await;
            let due: Vec<String> = {
                let cfg = store.get();
                let now = now();
                cfg.loops
                    .values()
                    .filter(|l| {
                        l.enabled
                            && match l.last_run_at {
                                None => true,
                                Some(last) => now - last >= (l.interval_minutes as i64).max(1) * 60,
                            }
                    })
                    .map(|l| l.id.clone())
                    .collect()
            };
            for id in due {
                if let Err(e) = run_loop(&store, &id).await {
                    eprintln!("loop {id} run failed: {e:#}");
                }
            }
        }
    });
}

/// Execute one run of a loop: ensure its project exists, prompt the selected
/// provider with the goal + prior run context, persist the report.
pub async fn run_loop(store: &Arc<Store>, loop_id: &str) -> Result<LoopRunRecord> {
    let Some(def) = store.get().loops.get(loop_id).cloned() else {
        bail!("loop '{loop_id}' not found");
    };

    let project = ensure_project(store, &def)?;

    let run_id = new_id("run");
    let started = now();
    store.update(|c| {
        if let Some(l) = c.loops.get_mut(loop_id) {
            l.last_run_at = Some(started);
            l.run_count += 1;
        }
    })?;

    let cfg = store.get();
    let provider = cfg
        .selected_provider
        .as_ref()
        .and_then(|id| cfg.providers.get(id).map(|p| (id.clone(), p.clone())));

    let mut record = LoopRunRecord {
        id: run_id,
        loop_id: loop_id.to_string(),
        started_at: started,
        finished_at: None,
        succeeded: false,
        report: String::new(),
    };

    match provider {
        None => {
            record.report = "No AI provider connected; loop skipped.".into();
        }
        Some((pid, pc)) => {
            let model =
                match providers::effective_model(&pid, &pc.api_key, pc.model.as_deref()).await {
                    Ok(m) => m,
                    Err(e) => {
                        record.report = format!("Run skipped: {e}");
                        record.finished_at = Some(now());
                        let saved = record.clone();
                        store.update(|c| {
                            c.loop_runs
                                .entry(loop_id.to_string())
                                .or_default()
                                .push(saved);
                        })?;
                        return Ok(record);
                    }
                };
            let system = loop_system_prompt(&def, project.as_ref());
            let prior = last_report(&cfg, loop_id);
            let mut user = format!("Loop goal:\n{}\n", def.goal);
            if let Some(prior) = prior {
                user.push_str(&format!(
                    "\nYour previous run reported:\n{prior}\n\nContinue from there."
                ));
            }
            user.push_str("\nProduce this run's report now.");
            let mut rx = providers::stream_chat(
                &pid,
                &pc.api_key,
                &model,
                &system,
                vec![("user".into(), user)],
                def.level >= 3,
            );
            let mut full = String::new();
            let mut failed = None;
            while let Some(item) = rx.recv().await {
                match item {
                    Ok(text) => full.push_str(&text),
                    Err(e) => {
                        failed = Some(e);
                        break;
                    }
                }
            }
            match failed {
                Some(e) if full.is_empty() => record.report = format!("Run failed: {e}"),
                _ => {
                    record.report = full;
                    record.succeeded = true;
                }
            }
        }
    }
    record.finished_at = Some(now());

    if record.succeeded {
        if let Some(p) = &project {
            append_run_log(p, &record)?;
        }
    }

    let saved = record.clone();
    store.update(|c| {
        let runs = c.loop_runs.entry(loop_id.to_string()).or_default();
        runs.push(saved);
        if runs.len() > MAX_RUNS_PER_LOOP {
            let excess = runs.len() - MAX_RUNS_PER_LOOP;
            runs.drain(..excess);
        }
    })?;
    Ok(record)
}

/// Loops make projects: on the first run of a loop with a project name, create
/// the project directory, seed PROJECT.md, and register it.
fn ensure_project(store: &Arc<Store>, def: &LoopDef) -> Result<Option<ProjectDef>> {
    let Some(name) = def.project_name.as_deref().filter(|n| !n.is_empty()) else {
        return Ok(None);
    };
    if let Some(pid) = &def.project_id {
        if let Some(p) = store.get().projects.get(pid) {
            return Ok(Some(p.clone()));
        }
    }
    let slug = slugify(name);
    let path = projects_dir().join(&slug);
    std::fs::create_dir_all(&path).with_context(|| format!("create {}", path.display()))?;
    let project = ProjectDef {
        id: format!("project-{slug}"),
        name: name.to_string(),
        path: path.to_string_lossy().into_owned(),
        created_by_loop_id: def.id.clone(),
        created_at: now(),
    };
    let seed = format!(
        "# {name}\n\nCreated by loop `{loop_name}` ({loop_id}).\n\n## Goal\n\n{goal}\n",
        name = name,
        loop_name = def.name,
        loop_id = def.id,
        goal = def.goal,
    );
    let project_md = path.join("PROJECT.md");
    if !project_md.exists() {
        std::fs::write(&project_md, seed)
            .with_context(|| format!("write {}", project_md.display()))?;
    }
    let saved = project.clone();
    store.update(|c| {
        c.projects.insert(saved.id.clone(), saved.clone());
        if let Some(l) = c.loops.get_mut(&def.id) {
            l.project_id = Some(saved.id.clone());
        }
    })?;
    Ok(Some(project))
}

fn append_run_log(project: &ProjectDef, run: &LoopRunRecord) -> Result<()> {
    use std::io::Write;
    let log = PathBuf::from(&project.path).join("RUNS.md");
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log)
        .with_context(|| format!("open {}", log.display()))?;
    let ts = chrono::DateTime::from_timestamp(run.started_at, 0)
        .map(|t| t.to_rfc3339())
        .unwrap_or_default();
    writeln!(f, "\n## Run {} — {}\n\n{}\n", run.id, ts, run.report)?;
    Ok(())
}

fn last_report(cfg: &crate::state::Config, loop_id: &str) -> Option<String> {
    cfg.loop_runs
        .get(loop_id)?
        .iter()
        .rev()
        .find(|r| r.succeeded && !r.report.is_empty())
        .map(|r| {
            let mut t = r.report.clone();
            if t.len() > 2000 {
                t.truncate(2000);
                t.push_str("…");
            }
            t
        })
}

fn loop_system_prompt(def: &LoopDef, project: Option<&ProjectDef>) -> String {
    let level = match def.level {
        3 => "L3 (unattended)",
        2 => "L2 (assisted)",
        _ => "L1 (report-only)",
    };
    let project_line = project
        .map(|p| {
            format!(
                "You are advancing the project \"{}\" at {}.",
                p.name, p.path
            )
        })
        .unwrap_or_else(|| "This loop has no project attached.".into());
    format!(
        "You are a MyOS loop runner executing the loop \"{name}\" at autonomy level {level}. \
         {project_line} \
         Loops run unattended on a cadence; each run you assess the goal, do the thinking, \
         and emit a concise markdown report of findings and the concrete next step. \
         At L1 you cannot execute tools or modify the system — report only.",
        name = def.name,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_flattens_names() {
        assert_eq!(slugify("My Cool App!"), "my-cool-app");
        assert_eq!(slugify("---"), "project");
    }
}
