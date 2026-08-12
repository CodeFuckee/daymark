//! 文件监控：notify 递归监听 → 事件流回调 Dart。
//!
//! 设计约定（DESIGN.md §5.3）：
//! - 递归监控配置的目录列表，Create/Modify/Remove 事件转发
//! - 排除规则在 Rust 侧过滤（隐藏文件、@eaDir、node_modules、.git 等）
//! - 节流聚合放在 Dart 侧 CollectService（便于测试），Rust 只负责原始事件

use anyhow::{anyhow, Result};
use crate::frb_generated::StreamSink;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

/// 单个文件变更事件
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FileEvent {
    pub path: String,
    /// create | modify | remove
    pub kind: String,
}

/// watcher 句柄（key = Dart 侧传入的 id）
static WATCHERS: Lazy<Mutex<HashMap<u64, RecommendedWatcher>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// 事件 sink（与 watcher 一一对应）
static SINKS: Lazy<Mutex<HashMap<u64, StreamSink<FileEvent>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// 开始递归监听 [paths]，命中 [excludes] 的路径被过滤。
/// [id] 由 Dart 侧生成并传入（FRB stream 模式吞返回值），供 [stop_watching] 使用。
pub fn watch_directories(
    id: u64,
    paths: Vec<String>,
    excludes: Vec<String>,
    stream: StreamSink<FileEvent>,
) -> Result<()> {
    let excludes: Vec<String> = excludes
        .into_iter()
        .filter(|s| !s.trim().is_empty())
        .collect();
    let sink = stream.clone();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(ev) = res else { return };
        let kind = match ev.kind {
            EventKind::Create(_) => "create",
            EventKind::Modify(_) => "modify",
            EventKind::Remove(_) => "remove",
            _ => return,
        };
        for path in ev.paths {
            let p = path.to_string_lossy().to_string();
            if is_excluded(&p, &excludes) {
                continue;
            }
            let _ = sink.add(FileEvent { path: p, kind: kind.to_string() });
        }
    })
    .map_err(|e| anyhow!("cannot create watcher: {e}"))?;

    // 先注册，后 watch：部分目录不存在时不影响已成功的目录
    let mut watched_any = false;
    for p in &paths {
        if p.trim().is_empty() {
            continue;
        }
        if !Path::new(p).is_dir() {
            eprintln!("[daymark_core] watch: not a directory, skipped: {p}");
            continue;
        }
        watcher
            .watch(Path::new(p), RecursiveMode::Recursive)
            .map_err(|e| anyhow!("cannot watch {p}: {e}"))?;
        watched_any = true;
    }
    if !watched_any {
        return Err(anyhow!("no valid directory to watch"));
    }
    WATCHERS.lock().unwrap().insert(id, watcher);
    SINKS.lock().unwrap().insert(id, stream);
    Ok(())
}

/// 停止监听
pub fn stop_watching(id: u64) -> Result<()> {
    if let Some(mut watchers) = WATCHERS.lock().ok() {
        watchers.remove(&id);
    }
    SINKS.lock().unwrap().remove(&id);
    Ok(())
}

/// 排除规则：子串匹配（v1 简化）。命中即丢弃。
fn is_excluded(path: &str, excludes: &[String]) -> bool {
    excludes.iter().any(|pat| path.contains(pat.as_str()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exclusion_matches_substring() {
        let excludes = vec![".git".to_string(), "node_modules".to_string()];
        assert!(is_excluded("/a/b/.git/config", &excludes));
        assert!(is_excluded("/a/node_modules/x", &excludes));
        assert!(!is_excluded("/a/gitlab/config", &excludes));
        assert!(!is_excluded("/a/b.txt", &excludes));
    }
}
