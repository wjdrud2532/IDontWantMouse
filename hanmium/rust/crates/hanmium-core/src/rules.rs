//! Karabiner-Elements 규칙 JSON 읽기 (complex_modifications 의 basic 조작).
//!
//! 지원: from.key_code + modifiers(mandatory·optional), conditions(variable_if/unless, frontmost_application_if/unless),
//! to·to_if_alone·to_after_key_up 의 key_code(+modifiers)·pointing_button·mouse_key·set_variable, 그리고 Hanmium 모드를
//! 바로 여는 {"hanmium": "labels" | "search" | "scroll"}. 그 밖의 것이 든 조작은 `unsupported` 에 적고 엔진이 건너뛴다.

use crate::keys::Key;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::fmt;

/// 변수 값. 정한 적 없는 변수는 0 이고, 0 과 false·1 과 true 는 같다고 본다.
#[derive(Clone, Debug, PartialEq)]
pub enum VarValue {
    Int(i64),
    Bool(bool),
    Str(String),
}

impl VarValue {
    fn from_json(v: &Value) -> Option<VarValue> {
        match v {
            Value::Number(n) => n.as_i64().map(VarValue::Int),
            Value::Bool(b) => Some(VarValue::Bool(*b)),
            Value::String(s) => Some(VarValue::Str(s.clone())),
            _ => None,
        }
    }

    pub fn same(&self, other: &VarValue) -> bool {
        fn norm(v: &VarValue) -> VarValue {
            match v {
                VarValue::Bool(b) => VarValue::Int(*b as i64),
                x => x.clone(),
            }
        }
        norm(self) == norm(other)
    }
}

impl fmt::Display for VarValue {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            VarValue::Int(i) => write!(f, "{i}"),
            VarValue::Bool(b) => write!(f, "{b}"),
            VarValue::Str(s) => write!(f, "\"{s}\""),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct MouseKey {
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub vertical_wheel: Option<f64>,
    pub horizontal_wheel: Option<f64>,
    pub speed_multiplier: Option<f64>,
}

impl MouseKey {
    fn from_json(v: &Value) -> MouseKey {
        let f = |k: &str| v.get(k).and_then(Value::as_f64);
        MouseKey {
            x: f("x"),
            y: f("y"),
            vertical_wheel: f("vertical_wheel"),
            horizontal_wheel: f("horizontal_wheel"),
            speed_multiplier: f("speed_multiplier"),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct From {
    pub key: Option<Key>,
    pub mandatory: Vec<String>,
    pub optional: Vec<String>,
}

#[derive(Clone, Debug, Default)]
pub struct ToEvent {
    pub key: Option<Key>,
    pub modifiers: Vec<String>,
    /// 1 왼쪽, 2 오른쪽, 3 가운데, 4 뒤로, 5 앞으로
    pub button: Option<u8>,
    pub mouse_key: Option<MouseKey>,
    pub set_variable: Option<(String, VarValue)>,
    pub hanmium: Option<String>,
    pub unsupported: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct Condition {
    pub kind: String,
    pub name: Option<String>,
    pub value: Option<VarValue>,
    pub bundle_identifiers: Vec<String>,
}

pub const SUPPORTED_CONDITIONS: [&str; 4] =
    ["variable_if", "variable_unless", "frontmost_application_if", "frontmost_application_unless"];

#[derive(Clone, Debug, Default)]
pub struct Manipulator {
    pub from: From,
    pub to: Vec<ToEvent>,
    pub to_if_alone: Option<Vec<ToEvent>>,
    pub to_after_key_up: Vec<ToEvent>,
    pub conditions: Vec<Condition>,
    pub parameters: HashMap<String, f64>,
    /// 지원하지 않는 것들(있으면 엔진이 이 조작을 쓰지 않는다)
    pub unsupported: Vec<String>,
}

pub const ALONE_TIMEOUT_KEY: &str = "basic.to_if_alone_timeout_milliseconds";
pub const POINTER_SCALE_KEY: &str = "mouse_key_xy_scale";
pub const WHEEL_SCALE_KEY: &str = "mouse_key_wheels_scale";

/// button1 → 1 … button32 → 32
pub fn button_number(name: &str) -> Option<u8> {
    let n: u8 = name.strip_prefix("button")?.parse().ok()?;
    (1..=32).contains(&n).then_some(n)
}

/// Karabiner 는 modifiers 를 목록으로도, 문자열 하나로도 받는다
fn strings(v: Option<&Value>) -> Vec<String> {
    match v {
        Some(Value::Array(a)) => a.iter().filter_map(|x| x.as_str().map(String::from)).collect(),
        Some(Value::String(s)) => vec![s.clone()],
        _ => vec![],
    }
}

fn obj(v: &Value) -> Result<&Map<String, Value>, String> {
    v.as_object().ok_or_else(|| "객체({ … })가 아닙니다".to_string())
}

impl ToEvent {
    pub fn from_json(v: &Value) -> Result<ToEvent, String> {
        let o = obj(v)?;
        let mut e = ToEvent { modifiers: strings(o.get("modifiers")), ..Default::default() };
        if let Some(name) = o.get("key_code").and_then(Value::as_str) {
            e.key = Key::named(name);
            if e.key.is_none() {
                e.unsupported.push(format!("key_code {name}"));
            }
        }
        if let Some(name) = o.get("pointing_button").and_then(Value::as_str) {
            e.button = button_number(name);
            if e.button.is_none() {
                e.unsupported.push(format!("pointing_button {name}"));
            }
        }
        if let Some(m) = o.get("mouse_key") {
            e.mouse_key = Some(MouseKey::from_json(m));
        }
        if let Some(sv) = o.get("set_variable") {
            let name = sv.get("name").and_then(Value::as_str).ok_or("set_variable.name 이 없습니다")?;
            let value = sv.get("value").and_then(VarValue::from_json).ok_or("set_variable.value 가 없습니다")?;
            e.set_variable = Some((name.to_string(), value));
        }
        if let Some(h) = o.get("hanmium").and_then(Value::as_str) {
            e.hanmium = Some(h.to_string());
            if !["labels", "search", "scroll"].contains(&h) {
                e.unsupported.push(format!("hanmium {h}"));
            }
        }
        for k in ["shell_command", "consumer_key_code", "select_input_source", "sticky_modifier", "software_function",
                  "apple_vendor_keyboard_key_code"] {
            if o.contains_key(k) {
                e.unsupported.push(k.to_string());
            }
        }
        Ok(e)
    }
}

fn events(v: Option<&Value>) -> Result<Vec<ToEvent>, String> {
    match v {
        None => Ok(vec![]),
        Some(Value::Array(a)) => a.iter().map(ToEvent::from_json).collect(),
        Some(other) => Ok(vec![ToEvent::from_json(other)?]),
    }
}

impl Manipulator {
    pub fn from_json(v: &Value) -> Result<Manipulator, String> {
        let o = obj(v)?;
        let mut m = Manipulator::default();
        if let Some(t) = o.get("type").and_then(Value::as_str) {
            if t != "basic" {
                m.unsupported.push(format!("type {t}"));
            }
        }
        let from = o.get("from").ok_or("\"from\" 이 없습니다")?;
        let fo = obj(from)?;
        for k in ["simultaneous", "pointing_button", "consumer_key_code", "any"] {
            if fo.contains_key(k) {
                m.unsupported.push(format!("from.{k}"));
            }
        }
        match fo.get("key_code").and_then(Value::as_str) {
            None => m.unsupported.push("from 키 없음".into()),
            Some(name) => {
                m.from.key = Key::named(name);
                if m.from.key.is_none() {
                    m.unsupported.push(format!("key_code {name}"));
                }
            }
        }
        if let Some(mods) = fo.get("modifiers") {
            m.from.mandatory = strings(mods.get("mandatory"));
            m.from.optional = strings(mods.get("optional"));
        }
        m.to = events(o.get("to"))?;
        m.to_if_alone = match o.get("to_if_alone") {
            None => None,
            v => Some(events(v)?),
        };
        m.to_after_key_up = events(o.get("to_after_key_up"))?;
        for k in ["to_if_held_down", "to_delayed_action"] {
            if o.contains_key(k) {
                m.unsupported.push(k.to_string());
            }
        }
        if let Some(Value::Array(conds)) = o.get("conditions") {
            for c in conds {
                let kind = c.get("type").and_then(Value::as_str).ok_or("조건에 type 이 없습니다")?.to_string();
                if !SUPPORTED_CONDITIONS.contains(&kind.as_str()) {
                    m.unsupported.push(format!("조건 {kind}"));
                }
                m.conditions.push(Condition {
                    kind,
                    name: c.get("name").and_then(Value::as_str).map(String::from),
                    value: c.get("value").and_then(VarValue::from_json),
                    bundle_identifiers: strings(c.get("bundle_identifiers")),
                });
            }
        }
        if let Some(Value::Object(p)) = o.get("parameters") {
            for (k, v) in p {
                if let Some(x) = v.as_f64() {
                    m.parameters.insert(k.clone(), x);
                }
            }
        }
        let inner: Vec<String> = m
            .to
            .iter()
            .chain(m.to_if_alone.iter().flatten())
            .chain(m.to_after_key_up.iter())
            .flat_map(|e| e.unsupported.clone())
            .collect();
        m.unsupported.extend(inner);
        Ok(m)
    }

    pub fn is_supported(&self) -> bool {
        self.unsupported.is_empty()
    }
}

/// 규칙 하나. 읽은 JSON 을 그대로 들고 있어서(모르는 항목도 지우지 않는다) Karabiner 와 오가도 잃는 것이 없다.
#[derive(Clone, Debug)]
pub struct Rule {
    pub json: Value,
}

impl Rule {
    pub fn description(&self) -> &str {
        self.json.get("description").and_then(Value::as_str).unwrap_or("(설명 없음)")
    }

    pub fn enabled(&self) -> bool {
        self.json.get("enabled").and_then(Value::as_bool).unwrap_or(true)
    }

    /// 조작 목록. JSON 이 틀린 조작은 None.
    pub fn manipulators(&self) -> Vec<Option<Manipulator>> {
        self.json
            .get("manipulators")
            .and_then(Value::as_array)
            .map(|a| a.iter().map(|m| Manipulator::from_json(m).ok()).collect())
            .unwrap_or_default()
    }

    /// 설정에서 손으로 고친 규칙 확인
    pub fn parse(text: &str) -> Result<Rule, String> {
        let json: Value = serde_json::from_str(text).map_err(|e| format!("JSON 이 아닙니다: {e}"))?;
        if !json.is_object() {
            return Err("규칙은 { … } 로 된 JSON 객체여야 합니다".into());
        }
        if !json.get("description").is_some_and(Value::is_string) {
            return Err("\"description\" (설명) 이 없습니다".into());
        }
        let list = json.get("manipulators").and_then(Value::as_array).filter(|a| !a.is_empty());
        let list = list.ok_or("\"manipulators\" (조작 목록) 가 비어 있습니다")?;
        for (i, m) in list.iter().enumerate() {
            Manipulator::from_json(m).map_err(|e| format!("조작 {}: {e}", i + 1))?;
        }
        Ok(Rule { json })
    }
}
