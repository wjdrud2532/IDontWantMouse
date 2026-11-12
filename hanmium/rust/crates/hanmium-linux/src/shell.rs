//! GNOME Shell 확장(org.hanmium.Shell) 부르기. 확장 쪽은 rust/gnome-extension/hanmium@hanmium.local/extension.js.

use serde_json::Value;

#[zbus::proxy(interface = "org.hanmium.Shell", default_service = "org.hanmium.Shell", default_path = "/org/hanmium/Shell")]
pub trait Shell {
    fn ping(&self) -> zbus::Result<String>;
    fn prepare(&self) -> zbus::Result<()>;
    fn windows(&self) -> zbus::Result<String>;
    fn activate(&self, id: u64) -> zbus::Result<()>;
    fn show_overlay(&self, json: &str) -> zbus::Result<()>;
    fn hide_overlay(&self) -> zbus::Result<()>;
    fn grab(&self, on: bool) -> zbus::Result<bool>;
    fn click(&self, x: f64, y: f64, button: u32) -> zbus::Result<()>;
    fn scroll(&self, x: f64, y: f64, dx: f64, dy: f64) -> zbus::Result<()>;
    fn move_pointer(&self, x: f64, y: f64) -> zbus::Result<()>;
    fn test_key(&self, keycode: u32, pressed: bool) -> zbus::Result<()>;
    fn screenshot(&self, path: &str) -> zbus::Result<bool>;
    #[zbus(signal)]
    fn key(&self, json: String) -> zbus::Result<()>;
    #[zbus(signal)]
    fn hotkey(&self, name: String) -> zbus::Result<()>;
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    fn from_json(v: &Value) -> Rect {
        let f = |k: &str| v.get(k).and_then(Value::as_f64).unwrap_or(0.0);
        Rect { x: f("x"), y: f("y"), w: f("w"), h: f("h") }
    }
    pub fn center(&self) -> (f64, f64) {
        (self.x + self.w / 2.0, self.y + self.h / 2.0)
    }
    pub fn intersects(&self, o: &Rect) -> bool {
        self.x < o.x + o.w && o.x < self.x + self.w && self.y < o.y + o.h && o.y < self.y + self.h
    }
}

/// 확장이 알려 주는 창 하나
#[derive(Clone, Debug)]
pub struct Window {
    pub id: u64,
    pub pid: i32,
    pub app: Option<String>,
    pub title: String,
    /// 창 틀(그림자 뺀 창 모양)
    pub frame: Rect,
    /// 그림자까지 든 버퍼 (GTK 의 클라이언트 쪽 장식 창은 이 안에 그림자 여백이 있다)
    pub buffer: Rect,
    pub focused: bool,
}

pub fn parse_windows(json: &str) -> Vec<Window> {
    let list: Value = serde_json::from_str(json).unwrap_or(Value::Null);
    list.as_array()
        .map(|a| {
            a.iter()
                .map(|w| Window {
                    id: w.get("id").and_then(Value::as_u64).unwrap_or(0),
                    pid: w.get("pid").and_then(Value::as_i64).unwrap_or(0) as i32,
                    app: w.get("app").and_then(Value::as_str).map(String::from),
                    title: w.get("title").and_then(Value::as_str).unwrap_or("").to_string(),
                    frame: Rect::from_json(&w["frame"]),
                    buffer: Rect::from_json(&w["buffer"]),
                    focused: w.get("focused").and_then(Value::as_bool).unwrap_or(false),
                })
                .collect()
        })
        .unwrap_or_default()
}
