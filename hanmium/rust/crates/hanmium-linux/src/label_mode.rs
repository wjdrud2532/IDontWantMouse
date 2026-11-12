//! 라벨 모드: 앞 창의 클릭 대상에 라벨을 띄우고, 친 글자로 골라 누른다.

use crate::a11y::{A11y, Origin, Target};
use crate::evdev_keys;
use crate::shell::{self, ShellProxy, Window};
use hanmium_core::labels;
use serde_json::{json, Value};
use std::time::Instant;

pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub enum Step {
    Continue,
    Done,
}

pub struct LabelMode {
    targets: Vec<Target>,
    names: Vec<String>,
    typed: String,
}

/// 포커스가 있는 창, 없으면 맨 앞 창
pub async fn front_window(shell: &ShellProxy<'_>) -> Res<Window> {
    let list = shell::parse_windows(&shell.windows().await?);
    list.iter().find(|w| w.focused).or(list.first()).cloned().ok_or_else(|| "창이 없습니다".into())
}

pub async fn find_targets(shell: &ShellProxy<'_>, a: &A11y, origin: Origin) -> Res<(Window, Vec<Target>, usize)> {
    let window = front_window(shell).await?;
    let app = a.app_for_pid(window.pid).await.ok_or("이 창의 앱이 접근성 버스에 없습니다")?;
    let top = a.window_for(&app, &window).await.ok_or("앱에서 창을 찾지 못했습니다")?;
    a.wake(&[&app, &top]).await;
    let (mut targets, mut visited) = a.targets(&top, &window, origin).await;
    // 막 깨운 Chromium 은 창 아래를 채우는 데 잠깐 걸린다: 비어 있으면 조금씩 다시 본다(최대 1초)
    let started = Instant::now();
    while visited <= 3 && started.elapsed().as_millis() < 1000 {
        tokio::time::sleep(std::time::Duration::from_millis(40)).await;
        (targets, visited) = a.targets(&top, &window, origin).await;
    }
    if started.elapsed().as_millis() > 0 && visited > 3 && started.elapsed().as_millis() >= 40 {
        println!("접근성을 깨우고 {}ms 기다림", started.elapsed().as_millis());
    }
    Ok((window, targets, visited))
}

impl LabelMode {
    /// 대상을 찾아 라벨을 띄우고 키보드를 잡는다
    pub async fn open(shell: &ShellProxy<'_>, a: &A11y, origin: Origin, started: Instant) -> Res<LabelMode> {
        let (window, targets, visited) = find_targets(shell, a, origin).await?;
        let found = started.elapsed().as_millis();
        if targets.is_empty() {
            return Err(format!("[{}] 클릭 대상이 없습니다", window.title).into());
        }
        let alphabet = labels::alphabet(labels::DEFAULT_ALPHABET);
        let names = labels::make(targets.len(), &alphabet);
        let mode = LabelMode { targets, names, typed: String::new() };
        shell.show_overlay(&mode.overlay()).await?;
        if !shell.grab(true).await? {
            shell.hide_overlay().await?;
            return Err("키보드를 잡지 못했습니다".into());
        }
        println!("라벨 모드 [{}]: 대상 {}개(노드 {visited}개) 찾기 {found}ms · 띄움 {}ms", window.title,
                 mode.targets.len(), started.elapsed().as_millis());
        Ok(mode)
    }

    fn overlay(&self) -> String {
        let typed = self.typed.chars().count();
        let labels: Vec<Value> = self
            .targets
            .iter()
            .zip(&self.names)
            .filter(|(_, n)| n.starts_with(&self.typed))
            .map(|(t, n)| json!({"x": t.rect.x, "y": t.rect.y + (t.rect.h - 18.0).max(0.0) / 2.0, "text": n, "typed": typed}))
            .collect();
        json!({ "labels": labels }).to_string()
    }

    /// 확장이 보낸 키 하나(JSON). 고르거나 닫으면 Done.
    pub async fn key(&mut self, shell: &ShellProxy<'_>, a: &A11y, json: &str) -> Res<Step> {
        let info: Value = serde_json::from_str(json).unwrap_or(Value::Null);
        if info["pressed"] != Value::Bool(true) {
            return Ok(Step::Continue);
        }
        let code = info["keycode"].as_u64().unwrap_or(0).saturating_sub(8) as u16;
        // 모드 중에 라벨 단축키(Alt+Space)를 다시 누르면 닫는다 — 잡은 동안은 단축키가 확장 키 바인딩으로 가지 않는다
        let alt = info["state"].as_u64().unwrap_or(0) & (1 << 3) != 0;
        match evdev_keys::key(code).map(|k| k.name()) {
            Some("escape") => return self.close(shell).await,
            Some("spacebar") if alt => return self.close(shell).await,
            Some("delete_or_backspace") => {
                self.typed.pop();
            }
            _ => {
                if let Some(c) = evdev_keys::char_of(code) {
                    self.typed.push(c);
                }
            }
        }
        let matching: Vec<usize> = (0..self.names.len()).filter(|&i| self.names[i].starts_with(&self.typed)).collect();
        if matching.is_empty() {
            self.typed.clear();
        } else if matching.len() == 1 && self.names[matching[0]] == self.typed {
            shell.hide_overlay().await?;
            let t = &self.targets[matching[0]];
            let pressed = a.activate(t).await;
            if !pressed {
                let (x, y) = t.rect.center();
                shell.click(x, y, 1).await?;
            }
            println!("고름 {}: {:?} {:?} ({})", self.typed, t.role, t.name, if pressed { "접근성 동작" } else { "클릭" });
            return Ok(Step::Done);
        }
        shell.show_overlay(&self.overlay()).await?;
        Ok(Step::Continue)
    }

    pub async fn close(&mut self, shell: &ShellProxy<'_>) -> Res<Step> {
        shell.hide_overlay().await?;
        println!("닫음");
        Ok(Step::Done)
    }
}
