//! 全局热键：global-hotkey 三平台注册 → 触发事件流回调 Dart。
//!
//! 设计约定（DESIGN.md §5.1/§6.1）：
//! - modifiers 传字符串数组（如 ["Ctrl", "Shift"]），key 传 Code 名（如 "KeyL"、"F5"）
//! - 注册失败（被占用/无显示环境）返回错误，由 Dart 侧提示改键
//! - GlobalHotKeyManager 必须长存（drop 后热键失效）

use anyhow::{anyhow, Result};
use crate::frb_generated::StreamSink;
use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager};
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::sync::Mutex;

/// 管理器长存（drop 后热键全部失效）。
///
/// Windows 平台的 `GlobalHotKeyManager` 含 `hwnd: HWND`（即 `*mut c_void`），
/// 自动实现为 `!Send`，直接放 `Mutex` 会编译失败（E0277，仅 Windows target，
/// CI #607/#612 实测）。`unsafe impl Send + Sync` 安全性论证：
/// 1. Manager 创建后仅存于 static（进程生命周期），不移动、从不 drop；
/// 2. register/unregister 调用的是基于 hwnd 的 `RegisterHotKey`/`UnregisterHotKey`，
///    WM_HOTKEY 投递到 hwnd 所属窗口线程的消息队列，跨线程调用安全；
/// 3. 所有访问经 Mutex 互斥（&SendManager 共享安全，满足 static 的 Sync 约束）。
struct SendManager(Mutex<Option<GlobalHotKeyManager>>);
unsafe impl Send for SendManager {}
unsafe impl Sync for SendManager {}

static MANAGER: Lazy<SendManager> = Lazy::new(|| SendManager(Mutex::new(None)));

/// 注册的 hotkey 与其对应 sink（key = Dart 侧传入的 id）
static HOTKEYS: Lazy<Mutex<HashMap<u64, (HotKey, StreamSink<u32>)>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// global-hotkey 内部 id → Dart 侧 id（监听线程反查）
static INTERNAL_TO_USER: Lazy<Mutex<HashMap<u32, u64>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// 注册全局热键。[id] 由 Dart 侧生成并传入（FRB stream 模式吞返回值，
/// 调用方需要 id 做注销），事件触发时通过 [stream] 转发 [id]。
pub fn register_hotkey(
    id: u64,
    modifiers: Vec<String>,
    key: String,
    stream: StreamSink<u32>,
) -> Result<()> {
    let mods = parse_modifiers(&modifiers)?;
    let code = parse_code(&key)?;
    let hotkey = HotKey::new(Some(mods), code);

    // GlobalHotKeyManager 无 Clone：注册在锁内完成
    {
        let mut guard = MANAGER.0.lock().unwrap();
        if guard.is_none() {
            let m = GlobalHotKeyManager::new().map_err(|e| anyhow!("hotkey manager: {e}"))?;
            *guard = Some(m);
        }
        guard
            .as_ref()
            .unwrap()
            .register(hotkey)
            .map_err(|e| anyhow!("register hotkey failed (被占用或环境不支持): {e}"))?;
    }

    // global-hotkey 内部 id → 我们的 id（监听线程反查用）
    INTERNAL_TO_USER.lock().unwrap().insert(hotkey.id(), id);
    HOTKEYS.lock().unwrap().insert(id, (hotkey, stream.clone()));

    // 全局事件监听线程只需启动一次
    ensure_listener();
    Ok(())
}

/// 注销热键
pub fn unregister_hotkey(id: u64) -> Result<()> {
    if let Some((hotkey, _)) = HOTKEYS.lock().unwrap().remove(&id) {
        INTERNAL_TO_USER.lock().unwrap().remove(&hotkey.id());
        let manager = MANAGER.0.lock().unwrap();
        if let Some(m) = manager.as_ref() {
            let _ = m.unregister(hotkey);
        }
    }
    Ok(())
}

/// 监听线程：把 GlobalHotKeyEvent 按内部 id 反查后转发给对应 sink
fn ensure_listener() {
    use std::sync::Once;
    static LISTENER: Once = Once::new();
    LISTENER.call_once(|| {
        std::thread::spawn(move || {
            let receiver = GlobalHotKeyEvent::receiver();
            loop {
                match receiver.recv() {
                    Ok(event) => {
                        let internal_id = event.id();
                        if let Some(user_id) =
                            INTERNAL_TO_USER.lock().unwrap().get(&internal_id).copied()
                        {
                            if let Some((_, sink)) = HOTKEYS.lock().unwrap().get(&user_id) {
                                let _ = sink.add(user_id as u32);
                            }
                        }
                    }
                    Err(_) => {
                        // 通道关闭：监听结束
                        break;
                    }
                }
            }
        });
    });
}

// ─────────────────────────── 解析与映射 ───────────────────────────

fn parse_modifiers(mods: &[String]) -> Result<Modifiers> {
    let mut out = Modifiers::empty();
    for m in mods {
        match m.to_lowercase().as_str() {
            "ctrl" | "control" => out |= Modifiers::CONTROL,
            "shift" => out |= Modifiers::SHIFT,
            "alt" => out |= Modifiers::ALT,
            "meta" | "super" | "cmd" | "command" => out |= Modifiers::META,
            _ => return Err(anyhow!("unknown modifier: {m}")),
        }
    }
    Ok(out)
}

fn parse_code(key: &str) -> Result<Code> {
    use Code::*;
    let k = key.trim();
    let code = match k {
        // 字母
        "KeyA" => KeyA, "KeyB" => KeyB, "KeyC" => KeyC, "KeyD" => KeyD,
        "KeyE" => KeyE, "KeyF" => KeyF, "KeyG" => KeyG, "KeyH" => KeyH,
        "KeyI" => KeyI, "KeyJ" => KeyJ, "KeyK" => KeyK, "KeyL" => KeyL,
        "KeyM" => KeyM, "KeyN" => KeyN, "KeyO" => KeyO, "KeyP" => KeyP,
        "KeyQ" => KeyQ, "KeyR" => KeyR, "KeyS" => KeyS, "KeyT" => KeyT,
        "KeyU" => KeyU, "KeyV" => KeyV, "KeyW" => KeyW, "KeyX" => KeyX,
        "KeyY" => KeyY, "KeyZ" => KeyZ,
        // 数字
        "Digit0" => Digit0, "Digit1" => Digit1, "Digit2" => Digit2, "Digit3" => Digit3,
        "Digit4" => Digit4, "Digit5" => Digit5, "Digit6" => Digit6, "Digit7" => Digit7,
        "Digit8" => Digit8, "Digit9" => Digit9,
        // 功能键
        "F1" => F1, "F2" => F2, "F3" => F3, "F4" => F4,
        "F5" => F5, "F6" => F6, "F7" => F7, "F8" => F8,
        "F9" => F9, "F10" => F10, "F11" => F11, "F12" => F12,
        // 常用功能键
        "Space" => Space, "Enter" => Enter, "Tab" => Tab,
        "Escape" => Escape, "Backspace" => Backspace, "Delete" => Delete,
        "Insert" => Insert, "Home" => Home, "End" => End,
        "PageUp" => PageUp, "PageDown" => PageDown,
        "ArrowUp" => ArrowUp, "ArrowDown" => ArrowDown,
        "ArrowLeft" => ArrowLeft, "ArrowRight" => ArrowRight,
        _ => return Err(anyhow!("unknown key code: {key}")),
    };
    Ok(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modifiers_parse() {
        let m = parse_modifiers(&["Ctrl".into(), "shift".into()]).unwrap();
        assert!(m.contains(Modifiers::CONTROL));
        assert!(m.contains(Modifiers::SHIFT));
        assert!(!m.contains(Modifiers::ALT));
    }

    #[test]
    fn modifiers_parse_unknown() {
        assert!(parse_modifiers(&["Hyper".into()]).is_err());
    }

    #[test]
    fn key_parse() {
        assert_eq!(parse_code("KeyL").unwrap(), Code::KeyL);
        assert_eq!(parse_code("F5").unwrap(), Code::F5);
        assert!(parse_code("Nonexistent").is_err());
    }
}
