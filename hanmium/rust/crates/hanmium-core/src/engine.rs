//! 키보드 규칙 엔진. 키 입력 하나를 받아 무엇을 내보낼지 정한다(백엔드가 실제로 보낸다). 운영체제를 건드리지 않아서
//! 따로 시험할 수 있다(tests/keyboard_fixtures.rs). Karabiner-Elements 의 basic 조작과 같은 순서·뜻으로 동작한다:
//! - 규칙을 위에서부터, 조작을 위에서부터 보고 처음 맞는 것 하나만 쓴다. 맞는 것이 없으면 단순 바꾸기, 그것도 없으면 그대로.
//! - from 의 mandatory 수정키는 내보내는 키에서 뺀다. optional 은 그대로 둔다. 둘 다 없으면 수정키를 누르지 않았을 때만 맞는다.
//! - to 의 마지막 키·버튼은 from 키를 뗄 때까지 누르고 있는다(반복 입력도 그 키로). 그 앞 것은 눌렀다 뗀다.
//! - to_if_alone 은 그 키를 누른 동안 다른 키·버튼을 누르지 않고 제한 시간 안에 뗐을 때 눌렀다 뗀다.
//! - to_after_key_up 은 뗄 때. mouse_key 는 누르고 있는 동안 계속.
//!
//! 수정키를 누르고 떼는 것은 [`Engine::modifiers_changed`] 로 알린다(맥의 flagsChanged). 수정키 자체를 바꾸는 규칙
//! (from 이 left_shift 인 것)은 아직 맞추지 않는다.

use crate::keys::{Key, Mods};
use crate::rules::{Manipulator, MouseKey, ToEvent, VarValue, ALONE_TIMEOUT_KEY};
use regex::Regex;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq)]
pub enum Output {
    /// 받은 입력을 그대로 보낸다(이것만 있을 때)
    Pass,
    Key { key: Key, down: bool, mods: Mods, repeat: bool },
    /// 1 왼쪽, 2 오른쪽, 3 가운데, 4 뒤로, 5 앞으로
    Button { n: u8, down: bool, mods: Mods },
    MotionStart { id: u32, vector: MouseKey, mods: Mods },
    MotionStop(u32),
    /// Hanmium 모드 열기: "labels" | "search" | "scroll"
    Hanmium(String),
}

#[derive(Default)]
pub struct Rules {
    pub manipulators: Vec<Manipulator>,
    pub simple: HashMap<Key, Key>,
    /// 초. 조작에 basic.to_if_alone_timeout_milliseconds 가 있으면 그것.
    pub alone_timeout: f64,
}

#[derive(Default)]
struct Active {
    passthrough: bool,
    simple_to: Option<Key>,
    /// to 의 마지막 키: from 키를 뗄 때까지 누르고 있는다
    held_key: Option<(Key, Mods)>,
    held_button: Option<(u8, Mods)>,
    motions: Vec<u32>,
    after_up: Vec<ToEvent>,
    alone: Option<Vec<ToEvent>>,
    alone_start: f64,
    alone_timeout: f64,
    interrupted: bool,
    /// mandatory 로 쓴 수정키(내보내는 키에서 뺀다)
    strip: Mods,
}

pub struct Engine {
    pub rules: Rules,
    pub variables: HashMap<String, VarValue>,
    /// 조건 frontmost_application_if 에 쓰는 앞 앱 이름(맥 번들 ID, 리눅스 앱 ID 등)
    pub frontmost: Box<dyn Fn() -> Option<String> + Send>,
    /// {"hanmium": …} 를 지금 열 수 있는지(Hanmium 이 꺼졌거나 그 앱에서 쓰지 않으면 원래 키가 가게 한다)
    pub hanmium_available: Box<dyn Fn(&str) -> bool + Send>,
    active: HashMap<Key, Active>,
    next_motion: u32,
    last_mods: Mods,
    regex_cache: HashMap<String, Option<Regex>>,
}

impl Default for Engine {
    fn default() -> Self {
        Engine {
            rules: Rules { alone_timeout: 1.0, ..Default::default() },
            variables: HashMap::new(),
            frontmost: Box::new(|| None),
            hanmium_available: Box::new(|_| true),
            active: HashMap::new(),
            next_motion: 1,
            last_mods: Mods::NONE,
            regex_cache: HashMap::new(),
        }
    }
}

impl Engine {
    pub fn new(rules: Rules) -> Engine {
        Engine { rules, ..Default::default() }
    }

    pub fn reset(&mut self) {
        self.active.clear();
        self.variables.clear();
    }

    /// 다른 키나 마우스 버튼을 눌렀다: 누르고 있는 키들의 to_if_alone 은 이제 나가지 않는다
    pub fn interrupt(&mut self) {
        for a in self.active.values_mut() {
            a.interrupted = true;
        }
    }

    /// 수정키가 바뀜. 새로 누른 수정키는 다른 키를 누른 것과 같다.
    pub fn modifiers_changed(&mut self, mods: Mods) -> Vec<Output> {
        let watched = Mods::LSHIFT | Mods::RSHIFT | Mods::LCTRL | Mods::RCTRL | Mods::LALT | Mods::RALT | Mods::LMETA
            | Mods::RMETA | Mods::FN;
        let before = Mods(self.last_mods.0 & watched.0);
        let now = Mods(mods.0 & watched.0);
        if !now.minus(before).is_empty() {
            self.interrupt();
        }
        self.last_mods = mods;
        vec![Output::Pass]
    }

    pub fn key_down(&mut self, key: Key, mods: Mods, repeat: bool, time: f64) -> Vec<Output> {
        if repeat || self.active.contains_key(&key) {
            return self.repeat_key(key);
        }
        self.interrupt();
        // 맞추는 동안 변수·정규식 저장소를 고쳐야 해서 조작 목록을 잠깐 꺼내 둔다
        let manipulators = std::mem::take(&mut self.rules.manipulators);
        let mut out = None;
        for m in &manipulators {
            if let Some(strip) = self.matches(m, key, mods) {
                out = Some(self.apply(m, key, mods, strip, time));
                break;
            }
        }
        self.rules.manipulators = manipulators;
        if let Some(out) = out {
            return out;
        }
        if let Some(&to) = self.rules.simple.get(&key) {
            self.active.insert(key, Active { simple_to: Some(to), ..Default::default() });
            return vec![Output::Key { key: to, down: true, mods: out_mods(mods, Mods::NONE, Mods::NONE), repeat: false }];
        }
        self.active.insert(key, Active { passthrough: true, ..Default::default() });
        vec![Output::Pass]
    }

    pub fn key_up(&mut self, key: Key, mods: Mods, time: f64) -> Vec<Output> {
        let Some(a) = self.active.remove(&key) else { return vec![Output::Pass] };
        if a.passthrough {
            return vec![Output::Pass];
        }
        if let Some(to) = a.simple_to {
            return vec![Output::Key { key: to, down: false, mods: out_mods(mods, Mods::NONE, Mods::NONE), repeat: false }];
        }
        let mut out = vec![];
        if let Some((k, m)) = a.held_key {
            out.push(Output::Key { key: k, down: false, mods: m, repeat: false });
        }
        if let Some((n, m)) = a.held_button {
            out.push(Output::Button { n, down: false, mods: m });
        }
        out.extend(a.motions.iter().map(|&id| Output::MotionStop(id)));
        out.extend(self.tap(&a.after_up, mods, a.strip));
        if let Some(alone) = &a.alone {
            if !a.interrupted && time - a.alone_start < a.alone_timeout {
                out.extend(self.tap(alone, mods, a.strip));
            }
        }
        out
    }

    fn repeat_key(&self, key: Key) -> Vec<Output> {
        let Some(a) = self.active.get(&key) else { return vec![Output::Pass] };
        if a.passthrough {
            return vec![Output::Pass];
        }
        if let Some(to) = a.simple_to {
            return vec![Output::Key { key: to, down: true, mods: out_mods(self.last_mods, Mods::NONE, Mods::NONE), repeat: true }];
        }
        if let Some((k, m)) = a.held_key {
            return vec![Output::Key { key: k, down: true, mods: m, repeat: true }];
        }
        vec![]
    }

    // MARK: 맞추기

    /// 맞으면 mandatory 로 쓴 수정키(뺄 것), 아니면 None
    fn matches(&mut self, m: &Manipulator, key: Key, mods: Mods) -> Option<Mods> {
        if !m.is_supported() || m.from.key != Some(key) {
            return None;
        }
        let strip = match_modifiers(&m.from.mandatory, &m.from.optional, mods)?;
        for c in &m.conditions {
            if !self.condition(c) {
                return None;
            }
        }
        // Hanmium 을 지금 열 수 없으면(꺼짐·이 앱에서 쓰지 않음) 이 조작은 없는 것으로 친다
        for e in &m.to {
            if let Some(h) = &e.hanmium {
                if !(self.hanmium_available)(h) {
                    return None;
                }
            }
        }
        Some(strip)
    }

    fn condition(&mut self, c: &crate::rules::Condition) -> bool {
        match c.kind.as_str() {
            "variable_if" | "variable_unless" => {
                let zero = VarValue::Int(0);
                let value = self.variables.get(c.name.as_deref().unwrap_or("")).unwrap_or(&zero);
                let equal = value.same(c.value.as_ref().unwrap_or(&zero));
                if c.kind == "variable_if" { equal } else { !equal }
            }
            "frontmost_application_if" | "frontmost_application_unless" => {
                let id = (self.frontmost)().unwrap_or_default();
                let hit = c.bundle_identifiers.iter().any(|p| {
                    let re = self.regex_cache.entry(p.clone()).or_insert_with(|| Regex::new(p).ok());
                    re.as_ref().is_some_and(|r| r.is_match(&id))
                });
                if c.kind == "frontmost_application_if" { hit } else { !hit }
            }
            _ => false,
        }
    }

    // MARK: 내보내기

    fn apply(&mut self, m: &Manipulator, key: Key, mods: Mods, strip: Mods, time: f64) -> Vec<Output> {
        let mut a = Active { strip, ..Default::default() };
        a.alone_timeout = m.parameters.get(ALONE_TIMEOUT_KEY).map(|ms| ms / 1000.0).unwrap_or(self.rules.alone_timeout);
        let mut out = vec![];
        let last = m.to.iter().rposition(|e| e.key.is_some() || e.button.is_some());
        for (i, e) in m.to.iter().enumerate() {
            if let Some((name, value)) = &e.set_variable {
                self.variables.insert(name.clone(), value.clone());
            }
            if let Some(h) = &e.hanmium {
                out.push(Output::Hanmium(h.clone()));
            }
            if let Some(k) = e.key {
                let f = out_mods(mods, strip, add_mods(&e.modifiers));
                out.push(Output::Key { key: k, down: true, mods: f, repeat: false });
                if Some(i) == last {
                    a.held_key = Some((k, f));
                } else {
                    out.push(Output::Key { key: k, down: false, mods: f, repeat: false });
                }
            }
            if let Some(n) = e.button {
                let f = out_mods(mods, strip, add_mods(&e.modifiers));
                out.push(Output::Button { n, down: true, mods: f });
                if Some(i) == last {
                    a.held_button = Some((n, f));
                } else {
                    out.push(Output::Button { n, down: false, mods: f });
                }
            }
            if let Some(v) = &e.mouse_key {
                let id = self.next_motion;
                self.next_motion += 1;
                out.push(Output::MotionStart { id, vector: v.clone(), mods: out_mods(mods, strip, Mods::NONE) });
                a.motions.push(id);
            }
        }
        a.after_up = m.to_after_key_up.clone();
        if let Some(alone) = &m.to_if_alone {
            a.alone = Some(alone.clone());
            a.alone_start = time;
        }
        self.active.insert(key, a);
        out
    }

    /// 눌렀다 바로 떼는 것들(to_after_key_up, to_if_alone)
    fn tap(&mut self, events: &[ToEvent], mods: Mods, strip: Mods) -> Vec<Output> {
        let mut out = vec![];
        for e in events {
            if let Some((name, value)) = &e.set_variable {
                self.variables.insert(name.clone(), value.clone());
            }
            if let Some(h) = &e.hanmium {
                out.push(Output::Hanmium(h.clone()));
            }
            if let Some(k) = e.key {
                let f = out_mods(mods, strip, add_mods(&e.modifiers));
                out.push(Output::Key { key: k, down: true, mods: f, repeat: false });
                out.push(Output::Key { key: k, down: false, mods: f, repeat: false });
            }
            if let Some(n) = e.button {
                let f = out_mods(mods, strip, add_mods(&e.modifiers));
                out.push(Output::Button { n, down: true, mods: f });
                out.push(Output::Button { n, down: false, mods: f });
            }
        }
        out
    }
}

/// from.modifiers 가 지금 누른 수정키와 맞으면 뺄 수정키(mandatory 로 쓴 것), 아니면 None.
pub fn match_modifiers(mandatory: &[String], optional: &[String], mods: Mods) -> Option<Mods> {
    let mut remaining = mods;
    let mut stripped = Mods::NONE;
    for name in mandatory {
        if let Some((_, l, r)) = Mods::SIDES.iter().find(|(g, _, _)| g == name) {
            let hit = Mods(remaining.0 & (l.0 | r.0));
            if hit.is_empty() {
                return None;
            }
            remaining = remaining.minus(hit);
            stripped |= hit;
        } else {
            let m = Mods::from_name(name)?;
            if !remaining.contains(m) {
                return None;
            }
            remaining = remaining.minus(m);
            stripped |= m;
        }
    }
    if !optional.iter().any(|o| o == "any") {
        for name in remaining.names() {
            if !optional.iter().any(|o| o == name || o == Mods::generic(name)) {
                return None;
            }
        }
    }
    Some(stripped)
}

/// to 에 적은 수정키("shift" 는 왼쪽)
fn add_mods(names: &[String]) -> Mods {
    names.iter().filter_map(|n| Mods::from_name(n)).fold(Mods::NONE, |a, b| a | b)
}

/// 내보낼 키의 수정키: 지금 수정키에서 뺄 것과 fn 을 빼고 to 의 수정키를 더한다.
/// (화살표에 원래 붙는 fn 같은 운영체제 고유 플래그는 백엔드가 붙인다)
pub fn out_mods(mods: Mods, strip: Mods, adding: Mods) -> Mods {
    mods.minus(strip).minus(Mods::FN) | adding
}
