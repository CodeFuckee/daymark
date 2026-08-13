//! 文件监控：notify 递归监听 → 事件流回调 Dart。
//!
//! 设计约定（DESIGN.md §5.3）：
//! - 递归监控配置的目录列表，Create/Modify/Remove 事件转发
//! - 排除规则在 Rust 侧过滤（隐藏文件、@eaDir、node_modules、.git 等）
//! - 节流聚合放在 Dart 侧 CollectService（便于测试），Rust 只负责原始事件
//!
//! Linux（inotify）上 `RecursiveMode::Recursive` 会为每个子目录逐个添加
//! watch，大目录树（如网络挂载点）的同步遍历可能耗时数分钟，阻塞 FRB
//! handler 线程（issue #6：保存设置卡在"保存中…"）。因此 Linux 上把递归
//! watch 移到后台线程执行；macOS（FSEvents）/Windows（ReadDirectoryChangesW）
//! 原生支持递归，`watch()` 很快，保持同步执行以便错误即时反馈。
//! 后台线程完成前可能收到新一轮 watch/stop：用递增 generation 标记，
//! 完成时 generation 不匹配则丢弃 watcher，防止旧 watcher 覆盖新监控。

use anyhow::{anyhow, Result};
use crate::frb_generated::StreamSink;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
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

/// 全局递增 generation（watch 请求序号）
static WATCH_GEN: AtomicU64 = AtomicU64::new(0);

/// 每个 id 当前有效的 generation；stop 后移除（后台线程据此丢弃过期 watcher）
static CURRENT_GEN: Lazy<Mutex<HashMap<u64, u64>>> =
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
    let sink_cb = sink.clone();
    let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
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
            let _ = sink_cb.add(FileEvent { path: p, kind: kind.to_string() });
        }
    })
    .map_err(|e| anyhow!("cannot create watcher: {e}"))?;

    let paths: Vec<String> = paths
        .into_iter()
        .filter(|p| !p.trim().is_empty())
        .collect();
    if paths.is_empty() {
        return Err(anyhow!("no directory to watch"));
    }

    // 本次 watch 的 generation；stop_watching 会移除它使后台线程完成时丢弃
    let gen = WATCH_GEN.fetch_add(1, Ordering::SeqCst) + 1;
    CURRENT_GEN.lock().unwrap().insert(id, gen);

    let do_watch = move || {
        // watch() 需要 &mut；闭包内转为可变绑定
        let mut watcher = watcher;
        // 部分目录不存在时不影响已成功的目录
        let mut watched_any = false;
        for p in &paths {
            if !Path::new(p).is_dir() {
                eprintln!("[daymark_core] watch: not a directory, skipped: {p}");
                continue;
            }
            if let Err(e) = watcher.watch(Path::new(p), RecursiveMode::Recursive) {
                eprintln!("[daymark_core] cannot watch {p}: {e}");
                continue;
            }
            watched_any = true;
        }
        // 完成前已被新一轮 watch/stop 取代 → 丢弃，避免覆盖新监控
        if CURRENT_GEN.lock().unwrap().get(&id) != Some(&gen) {
            return;
        }
        if !watched_any {
            eprintln!("[daymark_core] watch: no valid directory to watch");
            return;
        }
        WATCHERS.lock().unwrap().insert(id, watcher);
        SINKS.lock().unwrap().insert(id, sink);
    };

    #[cfg(target_os = "linux")]
    {
        // Linux inotify 递归 watch 大目录树极慢：移出 FRB handler 线程（issue #6）
        std::thread::spawn(do_watch);
    }
    #[cfg(not(target_os = "linux"))]
    {
        do_watch();
    }
    Ok(())
}

/// 停止监听
pub fn stop_watching(id: u64) -> Result<()> {
    // 使在途的后台 watch 线程完成时丢弃 watcher
    CURRENT_GEN.lock().unwrap().remove(&id);
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
