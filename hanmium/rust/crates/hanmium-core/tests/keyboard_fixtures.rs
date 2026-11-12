//! 키보드 규칙 엔진 회귀 시험. 맥판(Tools/KeyboardFixtures/main.swift)의 46개를 그대로 옮겼다. 같은 규칙 파일
//! (Tools/KeyboardFixtures/rules.json)에 키 입력을 차례로 넣고 내보내는 것이 맞는지 본다.
//! 맥판과 다른 점: 화살표에 붙는 fn·숫자패드 같은 맥 고유 플래그는 코어가 아니라 백엔드가 붙이므로 기대값에 없다.

use hanmium_core::engine::{Engine, Output, Rules};
use hanmium_core::keys::{Key, Mods};
use hanmium_core::rules::{MouseKey, Rule};

fn rules() -> Vec<Rule> {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../Tools/KeyboardFixtures/rules.json");
    let text = std::fs::read_to_string(path).expect("rules.json");
    let root: serde_json::Value = serde_json::from_str(&text).unwrap();
    root["rules"].as_array().unwrap().iter().map(|r| Rule { json: r.clone() }).collect()
}

fn engine() -> Engine {
    let mut compiled = Rules { alone_timeout: 1.0, ..Default::default() };
    compiled.manipulators = rules().iter().flat_map(|r| r.manipulators().into_iter().flatten()).collect();
    compiled.simple.insert(Key::of("f13"), Key::of("escape"));
    Engine::new(compiled)
}

fn k(n: &str) -> Key {
    Key::of(n)
}
fn key(n: &str, down: bool, mods: Mods) -> Output {
    Output::Key { key: k(n), down, mods, repeat: false }
}
fn rep(n: &str) -> Output {
    Output::Key { key: k(n), down: true, mods: Mods::NONE, repeat: true }
}
fn btn(n: u8, down: bool) -> Output {
    Output::Button { n, down, mods: Mods::NONE }
}
fn mk(x: Option<f64>, y: Option<f64>, wheel: Option<f64>) -> MouseKey {
    MouseKey { x, y, vertical_wheel: wheel, ..Default::default() }
}

const N: Mods = Mods::NONE;
const LSHIFT: Mods = Mods::LSHIFT;
const LALT: Mods = Mods::LALT;

struct Check {
    count: usize,
    failures: Vec<String>,
}

impl Check {
    fn expect(&mut self, name: &str, got: Vec<Output>, want: Vec<Output>) {
        self.count += 1;
        if got != want {
            self.failures.push(format!("✗ {name}\n    받음: {got:?}\n    기대: {want:?}"));
        }
    }
}

#[test]
fn keyboard_fixtures() {
    let mut c = Check { count: 0, failures: vec![] };
    let g = "grave_accent_and_tilde";

    // 1. ₩ 만 짧게: 뗄 때 ₩
    {
        let mut e = engine();
        c.expect("₩ 누름", e.key_down(k(g), N, false, 0.0), vec![]);
        c.expect("₩ 뗌", e.key_up(k(g), N, 0.1), vec![key(g, true, N), key(g, false, N)]);
        c.expect("₩ 뗀 뒤 h 는 그대로", e.key_down(k("h"), N, false, 0.2), vec![Output::Pass]);
    }
    // 2. ₩ + h → ←, 반복도 ←, ₩ 은 나가지 않음
    {
        let mut e = engine();
        e.key_down(k(g), N, false, 0.0);
        c.expect("₩+h", e.key_down(k("h"), N, false, 0.1), vec![key("left_arrow", true, N)]);
        c.expect("₩+h 반복", e.key_down(k("h"), N, true, 0.6), vec![rep("left_arrow")]);
        c.expect("h 뗌", e.key_up(k("h"), N, 0.7), vec![key("left_arrow", false, N)]);
        c.expect("₩ 뗌(다른 키를 눌렀으니 ₩ 없음)", e.key_up(k(g), N, 0.8), vec![]);
    }
    // 3. ₩ 을 1초 넘게 누르고 떼면 아무것도 없음
    {
        let mut e = engine();
        e.key_down(k(g), N, false, 0.0);
        c.expect("₩ 오래 누름", e.key_up(k(g), N, 1.2), vec![]);
    }
    // 4. Tab → Hanmium 라벨, Hanmium 을 쓸 수 없으면 Tab 그대로
    {
        let mut e = engine();
        c.expect("Tab", e.key_down(k("tab"), N, false, 0.0), vec![Output::Hanmium("labels".into())]);
        c.expect("Tab 뗌", e.key_up(k("tab"), N, 0.1), vec![]);
        c.expect("Caps Lock 켠 Tab", e.key_down(k("tab"), Mods::CAPS, false, 1.0), vec![Output::Hanmium("labels".into())]);
        e.key_up(k("tab"), Mods::CAPS, 1.1);
        c.expect("⌘Tab 은 그대로", e.key_down(k("tab"), Mods::LMETA, false, 2.0), vec![Output::Pass]);
        c.expect("⌘Tab 뗌도 그대로", e.key_up(k("tab"), Mods::LMETA, 2.1), vec![Output::Pass]);
        e.hanmium_available = Box::new(|_| false);
        c.expect("Hanmium 꺼짐 → Tab 그대로", e.key_down(k("tab"), N, false, 3.0), vec![Output::Pass]);
        c.expect("Hanmium 꺼짐 → Tab 뗌 그대로", e.key_up(k("tab"), N, 3.1), vec![Output::Pass]);
    }
    // 5. ₩ + Tab → Tab
    {
        let mut e = engine();
        e.key_down(k(g), N, false, 0.0);
        c.expect("₩+Tab", e.key_down(k("tab"), N, false, 0.1), vec![key("tab", true, N)]);
        c.expect("₩+Tab 뗌", e.key_up(k("tab"), N, 0.2), vec![key("tab", false, N)]);
        e.key_up(k(g), N, 0.3);
    }
    // 6. ⌥h → 포인터 ←(⌥ 은 빼고), 뗄 때 멈춤
    {
        let mut e = engine();
        let v = mk(Some(-1536.0), None, None);
        c.expect("⌥h", e.key_down(k("h"), LALT, false, 0.0), vec![Output::MotionStart { id: 1, vector: v.clone(), mods: N }]);
        c.expect("⌥h 반복은 버림", e.key_down(k("h"), LALT, true, 0.5), vec![]);
        c.expect("⌥h 뗌", e.key_up(k("h"), LALT, 0.6), vec![Output::MotionStop(1)]);
        c.expect("⇪ 켠 ⌥h", e.key_down(k("h"), LALT | Mods::CAPS, false, 1.0),
                 vec![Output::MotionStart { id: 2, vector: v, mods: Mods::CAPS }]);
    }
    // 7. ₩ + ⌥h → 왼쪽 클릭(⌥ 없이), 뗄 때 버튼 뗌
    {
        let mut e = engine();
        e.key_down(k(g), N, false, 0.0);
        c.expect("₩+⌥h", e.key_down(k("h"), LALT, false, 0.1), vec![btn(1, true)]);
        c.expect("₩+⌥h 뗌", e.key_up(k("h"), LALT, 0.2), vec![btn(1, false)]);
    }
    // 8. ⇧NumLock 으로 마우스 모드, 숫자패드 8·5·7·9, 다시 ⇧NumLock 이면 그대로
    {
        let mut e = engine();
        c.expect("숫자패드 8 (마우스 모드 전)", e.key_down(k("keypad_8"), N, false, 0.0), vec![Output::Pass]);
        e.key_up(k("keypad_8"), N, 0.1);
        c.expect("⇧NumLock", e.key_down(k("keypad_num_lock"), LSHIFT, false, 1.0), vec![]);
        e.key_up(k("keypad_num_lock"), LSHIFT, 1.1);
        let up = mk(None, Some(-1536.0), None);
        c.expect("숫자패드 8", e.key_down(k("keypad_8"), N, false, 2.0), vec![Output::MotionStart { id: 1, vector: up, mods: N }]);
        c.expect("숫자패드 8 뗌", e.key_up(k("keypad_8"), N, 2.1), vec![Output::MotionStop(1)]);
        c.expect("숫자패드 5", e.key_down(k("keypad_5"), N, false, 3.0), vec![btn(1, true)]);
        c.expect("숫자패드 5 뗌", e.key_up(k("keypad_5"), N, 3.1), vec![btn(1, false)]);
        c.expect("숫자패드 7 → Home", e.key_down(k("keypad_7"), N, false, 4.0), vec![key("home", true, N)]);
        e.key_up(k("keypad_7"), N, 4.1);
        let wheel = mk(None, None, Some(-48.0));
        c.expect("숫자패드 9 → 휠 위", e.key_down(k("keypad_9"), N, false, 5.0), vec![Output::MotionStart { id: 2, vector: wheel, mods: N }]);
        e.key_up(k("keypad_9"), N, 5.1);
        e.key_down(k("keypad_num_lock"), LSHIFT, false, 6.0);
        e.key_up(k("keypad_num_lock"), LSHIFT, 6.1);
        c.expect("마우스 모드 끈 뒤 숫자패드 8", e.key_down(k("keypad_8"), N, false, 7.0), vec![Output::Pass]);
    }
    // 9. ₩ + Space + ⇧h → ⌥⇧← (단어 선택), ₩ + Space 짧게 → Space
    {
        let mut e = engine();
        e.key_down(k(g), N, false, 0.0);
        c.expect("₩+Space", e.key_down(k("spacebar"), N, false, 0.1), vec![]);
        let word = LALT | LSHIFT | Mods::RSHIFT;
        c.expect("₩+Space+⇧h", e.key_down(k("h"), LSHIFT, false, 0.2), vec![key("left_arrow", true, word)]);
        e.key_up(k("h"), LSHIFT, 0.3);
        c.expect("Space 뗌(다른 키를 눌렀으니 Space 없음)", e.key_up(k("spacebar"), N, 0.4), vec![]);
        c.expect("₩+Space 짧게", e.key_down(k("spacebar"), N, false, 0.5), vec![]);
        c.expect("Space 혼자 뗌", e.key_up(k("spacebar"), N, 0.6), vec![key("spacebar", true, N), key("spacebar", false, N)]);
        c.expect("Space 뗀 뒤 h → ⌥←(단어)가 아니라 ←", e.key_down(k("h"), N, false, 0.7), vec![key("left_arrow", true, N)]);
    }
    // 10. ⇧₩ 짧게 → ~ (⇧ 는 optional any 라 그대로)
    {
        let mut e = engine();
        e.modifiers_changed(LSHIFT);
        e.key_down(k(g), LSHIFT, false, 0.0);
        c.expect("⇧₩", e.key_up(k(g), LSHIFT, 0.1), vec![key(g, true, LSHIFT), key(g, false, LSHIFT)]);
    }
    // 11. ₩ 누른 채 ⇧ 를 누르면(다른 키) ₩ 는 나가지 않음
    {
        let mut e = engine();
        e.key_down(k(g), N, false, 0.0);
        e.modifiers_changed(LSHIFT);
        c.expect("₩ 누르는 중 ⇧", e.key_up(k(g), LSHIFT, 0.2), vec![]);
    }
    // 12. 그 밖의 키·단순 바꾸기·지원 안 하는 조작
    {
        let mut e = engine();
        c.expect("a", e.key_down(k("a"), N, false, 0.0), vec![Output::Pass]);
        c.expect("a 반복", e.key_down(k("a"), N, true, 0.5), vec![Output::Pass]);
        c.expect("a 뗌", e.key_up(k("a"), N, 0.6), vec![Output::Pass]);
        c.expect("F13 → Esc", e.key_down(k("f13"), N, false, 1.0), vec![key("escape", true, N)]);
        c.expect("F13 뗌", e.key_up(k("f13"), N, 1.1), vec![key("escape", false, N)]);
        let unsupported = rules().last().unwrap().manipulators()[0].clone().unwrap();
        c.expect("simultaneous 는 지원 안 함", if unsupported.is_supported() { vec![Output::Pass] } else { vec![] }, vec![]);
    }

    for f in &c.failures {
        println!("{f}");
    }
    println!("키보드 규칙 시험 {}개 중 실패 {}개", c.count, c.failures.len());
    assert!(c.failures.is_empty(), "{}", c.failures.join("\n"));
    assert_eq!(c.count, 46, "맥판과 같은 46개");
}
