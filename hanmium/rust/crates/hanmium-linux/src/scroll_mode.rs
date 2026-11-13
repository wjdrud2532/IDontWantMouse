//! 스크롤 모드: 앞 창의 스크롤 영역 하나를 골라 키보드로 스크롤한다 (맥판 ScrollMode 와 같은 키).
//!   h j k l·화살표: 누르고 있는 동안 부드럽게 (화살표는 Shift 와 함께면 빠르게)
//!   Shift+h·l: 뒤로·앞으로, Shift+j·k: 앞·뒤 탭 (Vimium H·L·J·K)
//!   d u: 반 페이지 (누르고 있으면 빠르게 계속) · gg G: 맨 위·맨 아래 · Tab Shift+Tab, Ctrl+n·p: 다음·이전 영역
//!   1~9: 그 번호 영역 · Enter: 그 영역을 눌러 포커스를 옮기고 끝내기 · f: 라벨로 · Esc·라벨 단축키: 끝내기
//!   그 밖의 Ctrl·Alt·Super 단축키(Ctrl+Tab, Ctrl+F, Ctrl+W …)는 앱으로 넘기고 모드를 다시 연다.
//! 움직임은 GNOME 확장(Scroller)이 화면 프레임마다 계산한다. 여기서는 누름·뗌만 알린다.

use crate::a11y::{A11y, Area, Origin};
use crate::evdev_keys;
use crate::label_mode::{front_window, Res};
use crate::shell::{Rect, ShellProxy};
use serde_json::{json, Value};
use std::time::Instant;

pub enum ScrollStep {
    Continue,
    Done,
    /// 라벨 모드로 (f)
    ToLabels,
    /// 앱에 보낼 단축키(뒤로·앞으로·탭). 데몬이 사용자가 Shift 를 뗀 뒤 모드를 닫고 보내고 다시 연다.
    Send(Vec<(u16, bool)>),
    /// 모드가 쓰지 않는 Ctrl·Alt·Super 단축키: 앱으로 넘긴다. 사용자가 아직 누르고 있는 키를 가상 키보드로 다시 누르면
    /// mutter 가 겹친 누름으로 보고 버리므로, 그 키(.1)를 뗀 뒤 수정키까지 붙여 보낸다.
    Pass(Vec<(u16, bool)>, u16),
}

/// Shift+h·l·j·k 가 앱에 보낼 단축키 (리눅스 앱 대부분이 받는 것): 뒤로 Alt+←, 앞으로 Alt+→, 앞 탭 Ctrl+PageUp, 뒤 탭 Ctrl+PageDown.
/// 누르고 있는 Shift 가 섞이면 다른 단축키(Ctrl+Shift+PageDown = 탭 옮기기)가 되므로 Shift 를 뗀 뒤에 보낸다.
pub fn shift_action(name: &str) -> Option<Vec<(u16, bool)>> {
    let (m, k) = match name {
        "h" => (56, 105),
        "l" => (56, 106),
        "j" => (29, 104),
        "k" => (29, 109),
        _ => return None,
    };
    Some(vec![(m, true), (k, true), (k, false), (m, false)])
}

/// 휠 한 단위(Clutter 의 매끈한 스크롤 1.0)가 앱에서 몇 px 움직이는지. Wayland 로는 10px 로 가지만 툴킷마다 다르게 쓴다
/// (jkhan 실측: Chrome 12px, GTK4 텍스트 편집기 2.5px = 0.1줄). 모르는 툴킷은 Wayland 값 10.
pub fn unit_px(toolkit: &str) -> f64 {
    let t = toolkit.to_ascii_lowercase();
    if t.contains("chrom") {
        12.0
    } else if t.contains("gtk") {
        2.5
    } else {
        10.0
    }
}

/// 맥판 기본값과 같다 (설정 창이 생기면 거기서)
const PX_PER_MS: f64 = 1.2;
const DASH: f64 = 3.0;
const ANIMATION: f64 = 0.25;

pub struct ScrollMode {
    areas: Vec<Area>,
    index: usize,
    last_g: Option<Instant>,
    pointer_before: (f64, f64),
}

impl ScrollMode {
    pub async fn open(shell: &ShellProxy<'_>, a: &A11y, origin: Origin, started: Instant) -> Res<ScrollMode> {
        let window = front_window(shell).await?;
        let mut areas = vec![];
        let mut toolkit = String::new();
        if let Some(app) = a.app_for_pid(window.pid).await {
            toolkit = a.toolkit(&app).await;
            if let Some(top) = a.window_for(&app, &window).await {
                a.wake(&[&app, &top]).await;
                let mut visited;
                (areas, visited) = a.scroll_areas(&top, &window, origin).await;
                // 막 깨운 Chromium 은 창 아래를 채우는 데 잠깐 걸린다 (라벨 모드와 같이 최대 1초)
                let waited = Instant::now();
                while visited <= 3 && waited.elapsed().as_millis() < 1000 {
                    tokio::time::sleep(std::time::Duration::from_millis(40)).await;
                    (areas, visited) = a.scroll_areas(&top, &window, origin).await;
                }
            }
        }
        let found = started.elapsed().as_millis();
        // 영역을 못 찾는 앱도 창 가운데로 휠을 보내면 대개 스크롤된다
        let whole = areas.is_empty();
        let areas = if whole {
            vec![Area { role: atspi::Role::Frame, name: window.title.clone(), rect: window.frame, object: Default::default(),
                        origin: (window.frame.x, window.frame.y) }]
        } else {
            areas
        };
        // 시작 영역: 가장 큰 것 (포커스 영역은 다음 단계)
        let index = (0..areas.len())
            .max_by(|&i, &j| (areas[i].rect.w * areas[i].rect.h).partial_cmp(&(areas[j].rect.w * areas[j].rect.h)).unwrap())
            .unwrap_or(0);
        let pointer_before = shell.pointer().await.unwrap_or((0.0, 0.0));
        let params = json!({
            "pxPerMs": PX_PER_MS, "dash": DASH, "accelTau": 80.0 * ANIMATION, "decelTau": 60.0 * ANIMATION,
            "glideMs": (250.0 * ANIMATION).max(120.0), "holdDelayMs": 120.0, "unitPx": unit_px(&toolkit),
        });
        shell.scroll_params(&params.to_string()).await?;
        let mut mode = ScrollMode { areas, index, last_g: None, pointer_before };
        mode.focus(shell, index).await?;
        // 휠이 앱에 닿아야 하므로 키보드 포커스만 가져온다(Grab 은 휠까지 잡는다)
        if !shell.key_focus(true).await? {
            shell.hide_overlay().await?;
            return Err("키보드를 잡지 못했습니다".into());
        }
        println!("스크롤 모드 [{}] ({toolkit}): 영역 {}개{} 찾기 {found}ms · 띄움 {}ms → 시작 {}", window.title,
                 mode.areas.len(), if whole { "(창 전체)" } else { "" }, started.elapsed().as_millis(), mode.index);
        Ok(mode)
    }

    fn aim(r: &Rect) -> (f64, f64) {
        r.center()
    }

    async fn focus(&mut self, shell: &ShellProxy<'_>, i: usize) -> Res<()> {
        self.index = i;
        let (x, y) = Self::aim(&self.areas[i].rect);
        shell.scroll_aim(x, y).await?;
        shell.show_overlay(&self.overlay()).await?;
        Ok(())
    }

    fn overlay(&self) -> String {
        let r = &self.areas[self.index].rect;
        let mut badges: Vec<Value> = vec![];
        if self.areas.len() > 1 {
            for (i, a) in self.areas.iter().enumerate().take(9) {
                badges.push(json!({"x": a.rect.x + 6.0, "y": a.rect.y + 4.0, "text": (i + 1).to_string(), "dim": i != self.index}));
            }
        }
        json!({"rects": [{"x": r.x, "y": r.y, "w": r.w, "h": r.h, "kind": "border"}], "badges": badges}).to_string()
    }

    pub async fn key(&mut self, shell: &ShellProxy<'_>, json: &str) -> Res<ScrollStep> {
        let info: Value = serde_json::from_str(json).unwrap_or(Value::Null);
        let code = info["keycode"].as_u64().unwrap_or(0).saturating_sub(8) as u16;
        let pressed = info["pressed"] == Value::Bool(true);
        let state = info["state"].as_u64().unwrap_or(0);
        let (shift, ctrl, alt) = (state & 1 != 0, state & 4 != 0, state & 8 != 0);
        let name = evdev_keys::key(code).map(|k| k.name()).unwrap_or("");
        if !pressed {
            shell.scroll_release(code as u32).await?;
            return Ok(ScrollStep::Continue);
        }
        if info["repeat"] == Value::Bool(true) {
            return Ok(ScrollStep::Continue);
        }
        let half = self.areas[self.index].rect.h / 2.0;
        let dir = match name {
            "h" | "left_arrow" => Some((-1.0, 0.0)),
            "j" | "down_arrow" => Some((0.0, 1.0)),
            "k" | "up_arrow" => Some((0.0, -1.0)),
            "l" | "right_arrow" => Some((1.0, 0.0)),
            _ => None,
        };
        let sup = state & ((1 << 6) | (1 << 26)) != 0;
        // 모드 키는 수정키 없이(Shift 만 허용)일 때만. Ctrl+Tab·Ctrl+F 같은 것은 앱 단축키로 넘긴다.
        let plain = !ctrl && !alt && !sup;
        if shift && plain {
            if let Some(keys) = shift_action(name) {
                shell.scroll_stop().await?;
                return Ok(ScrollStep::Send(keys));
            }
        }
        match name {
            "escape" => {
                self.close(shell).await?;
                return Ok(ScrollStep::Done);
            }
            "spacebar" if alt => {
                self.close(shell).await?;
                return Ok(ScrollStep::Done);
            }
            "tab" | "n" | "p" if (name == "tab" && plain) || (name != "tab" && ctrl && !alt && !shift && !sup) => {
                let n = self.areas.len();
                let back = if name == "tab" { shift } else { name == "p" };
                let i = if back { (self.index + n - 1) % n } else { (self.index + 1) % n };
                self.focus(shell, i).await?;
            }
            "return_or_enter" | "keypad_enter" if plain => {
                self.close(shell).await?;
                let (x, y) = self.areas[self.index].rect.center();
                shell.click(x, y, 1).await?;
                return Ok(ScrollStep::Done);
            }
            "f" if plain && !shift => {
                self.close(shell).await?;
                return Ok(ScrollStep::ToLabels);
            }
            "d" | "u" if plain => {
                let sign = if name == "d" { 1.0 } else { -1.0 };
                shell.scroll_page(code as u32, 0.0, sign * half, 0.0, sign * DASH).await?;
            }
            "g" if plain && shift => shell.scroll_jump(1.0).await?,
            "g" if plain => {
                if self.last_g.is_some_and(|t| t.elapsed().as_secs_f64() < 0.5) {
                    shell.scroll_jump(-1.0).await?;
                    self.last_g = None;
                } else {
                    self.last_g = Some(Instant::now());
                }
            }
            n if plain && n.len() == 1 && n.chars().next().is_some_and(|c| c.is_ascii_digit() && c != '0') => {
                let i = n.parse::<usize>().unwrap() - 1;
                if i < self.areas.len() {
                    self.focus(shell, i).await?;
                }
            }
            _ => {
                if let Some((dx, dy)) = dir.filter(|_| plain) {
                    shell.scroll_hold(code as u32, dx, dy).await?;
                } else if !plain && !evdev_keys::is_modifier(code) {
                    shell.scroll_stop().await?;
                    let mods: Vec<u16> = [(ctrl, 29), (alt, 56), (shift, 42), (sup, 125)]
                        .iter()
                        .filter(|(on, _)| *on)
                        .map(|&(_, c)| c)
                        .collect();
                    let mut keys: Vec<(u16, bool)> = mods.iter().map(|&m| (m, true)).collect();
                    keys.extend([(code, true), (code, false)]);
                    keys.extend(mods.iter().rev().map(|&m| (m, false)));
                    return Ok(ScrollStep::Pass(keys, code));
                }
            }
        }
        Ok(ScrollStep::Continue)
    }

    /// 끝내기: 스크롤을 멈추고, 테두리를 지우고, 포인터를 처음 자리로
    pub async fn close(&mut self, shell: &ShellProxy<'_>) -> Res<()> {
        shell.scroll_stop().await?;
        shell.hide_overlay().await?;
        shell.move_pointer(self.pointer_before.0, self.pointer_before.1).await?;
        Ok(())
    }
}
