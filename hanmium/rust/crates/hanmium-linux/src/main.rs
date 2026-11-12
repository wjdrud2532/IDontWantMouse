//! hanmium (리눅스). 지금 되는 것:
//!   hanmium windows                 확장이 아는 창 목록
//!   hanmium dump [--buffer]         앞 창의 클릭 대상 (AT-SPI)
//!   hanmium labels [--buffer]       라벨 모드 한 번: 라벨을 띄우고 키를 받아 고른 것을 누른다(Esc 로 닫기)
//! 확장(org.hanmium.Shell)이 켜진 GNOME 세션에서 돌린다. 시험은 rust/linux/test-session.sh.

mod a11y;
mod evdev_keys;
mod shell;

use a11y::{A11y, Origin, Target};
use futures_util::StreamExt;
use hanmium_core::labels;
use serde_json::{json, Value};
use shell::{ShellProxy, Window};
use std::time::Instant;

type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let origin = if args.iter().any(|a| a == "--buffer") { Origin::Buffer } else { Origin::Frame };
    let result = match args.first().map(String::as_str) {
        Some("windows") => windows().await,
        Some("dump") => dump(origin).await,
        Some("labels") => label_mode(origin).await,
        _ => {
            eprintln!("사용법: hanmium windows | dump [--buffer] | labels [--buffer]");
            std::process::exit(2);
        }
    };
    if let Err(e) = result {
        eprintln!("오류: {e}");
        std::process::exit(1);
    }
}

async fn connect() -> Res<(zbus::Connection, ShellProxy<'static>)> {
    let session = zbus::Connection::session().await?;
    let shell = ShellProxy::new(&session).await?;
    Ok((session, shell))
}

/// 포커스가 있는 창, 없으면 맨 앞 창
async fn front_window(shell: &ShellProxy<'_>) -> Res<Window> {
    let list = shell::parse_windows(&shell.windows().await?);
    list.iter().find(|w| w.focused).or(list.first()).cloned().ok_or_else(|| "창이 없습니다".into())
}

async fn windows() -> Res<()> {
    let (_s, shell) = connect().await?;
    for w in shell::parse_windows(&shell.windows().await?) {
        println!("{}{} pid {} {:?} 틀 {:?} 버퍼 {:?} {}", if w.focused { "* " } else { "  " }, w.id, w.pid,
                 w.app.unwrap_or_default(), w.frame, w.buffer, w.title);
    }
    Ok(())
}

async fn find_targets(origin: Origin) -> Res<(ShellProxy<'static>, A11y, Window, Vec<Target>)> {
    let (_s, shell) = connect().await?;
    let window = front_window(&shell).await?;
    let a = A11y::new().await?;
    let started = Instant::now();
    let app = a.app_for_pid(window.pid).await.ok_or("이 창의 앱이 접근성 버스에 없습니다")?;
    let top = a.window_for(&app, &window).await.ok_or("앱에서 창을 찾지 못했습니다")?;
    let (targets, visited) = a.targets(&top, &window, origin).await;
    eprintln!("[{}] 대상 {}개 (노드 {visited}개, {}ms)", window.title, targets.len(), started.elapsed().as_millis());
    Ok((shell, a, window, targets))
}

async fn dump(origin: Origin) -> Res<()> {
    let (_shell, _a, window, targets) = find_targets(origin).await?;
    println!("창 {} 틀 {:?}", window.title, window.frame);
    for t in &targets {
        println!("  {:?} {:?} ({:.0},{:.0} {:.0}x{:.0}){}", t.role, t.name, t.rect.x, t.rect.y, t.rect.w, t.rect.h,
                 if t.has_action { "" } else { " (동작 없음)" });
    }
    Ok(())
}

fn overlay_json(targets: &[Target], names: &[String], typed: &str) -> String {
    let labels: Vec<Value> = targets
        .iter()
        .zip(names)
        .filter(|(_, n)| n.starts_with(typed))
        .map(|(t, n)| json!({"x": t.rect.x, "y": t.rect.y + (t.rect.h - 18.0).max(0.0) / 2.0, "text": n, "typed": typed.chars().count()}))
        .collect();
    json!({ "labels": labels }).to_string()
}

async fn label_mode(origin: Origin) -> Res<()> {
    let (shell, a, _window, targets) = find_targets(origin).await?;
    if targets.is_empty() {
        return Err("클릭 대상이 없습니다".into());
    }
    let alphabet = labels::alphabet(labels::DEFAULT_ALPHABET);
    let names = labels::make(targets.len(), &alphabet);
    let mut keys = shell.receive_key().await?;
    let mut typed = String::new();
    shell.show_overlay(&overlay_json(&targets, &names, &typed)).await?;
    if !shell.grab(true).await? {
        shell.hide_overlay().await?;
        return Err("키보드를 잡지 못했습니다".into());
    }
    println!("라벨 {}개", names.len());
    while let Some(signal) = keys.next().await {
        let info: Value = serde_json::from_str(&signal.args()?.json).unwrap_or(Value::Null);
        if info["pressed"] != Value::Bool(true) {
            continue;
        }
        let code = info["keycode"].as_u64().unwrap_or(0).saturating_sub(8) as u16;
        match evdev_keys::key(code).map(|k| k.name()) {
            Some("escape") => {
                shell.hide_overlay().await?;
                println!("닫음");
                return Ok(());
            }
            Some("delete_or_backspace") => {
                typed.pop();
            }
            _ => {
                if let Some(c) = evdev_keys::char_of(code) {
                    typed.push(c);
                }
            }
        }
        let matching: Vec<usize> = (0..names.len()).filter(|&i| names[i].starts_with(&typed)).collect();
        if matching.is_empty() {
            typed.clear();
        } else if matching.len() == 1 && names[matching[0]] == typed {
            shell.hide_overlay().await?;
            let t = &targets[matching[0]];
            let pressed = a.activate(t).await;
            if !pressed {
                let (x, y) = t.rect.center();
                shell.click(x, y, 1).await?;
            }
            println!("고름 {typed}: {:?} {:?} ({})", t.role, t.name, if pressed { "접근성 동작" } else { "클릭" });
            return Ok(());
        }
        shell.show_overlay(&overlay_json(&targets, &names, &typed)).await?;
    }
    Ok(())
}
