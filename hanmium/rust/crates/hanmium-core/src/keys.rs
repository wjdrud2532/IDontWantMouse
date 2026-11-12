//! 키 이름과 수정키.

use std::collections::HashMap;
use std::fmt;
use std::sync::OnceLock;

/// Karabiner-Elements 의 key_code 이름들. 순서가 곧 [`Key`] 번호다(바꾸지 말고 뒤에 더한다).
pub const KEY_NAMES: &[&str] = &[
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w",
    "x", "y", "z", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "return_or_enter", "escape",
    "delete_or_backspace", "tab", "spacebar", "hyphen", "equal_sign", "open_bracket", "close_bracket", "backslash",
    "non_us_pound", "semicolon", "quote", "grave_accent_and_tilde", "comma", "period", "slash", "caps_lock", "f1",
    "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18",
    "f19", "f20", "f21", "f22", "f23", "f24", "print_screen", "scroll_lock", "pause", "insert", "home", "page_up",
    "delete_forward", "end", "page_down", "right_arrow", "left_arrow", "down_arrow", "up_arrow", "keypad_num_lock",
    "keypad_slash", "keypad_asterisk", "keypad_hyphen", "keypad_plus", "keypad_enter", "keypad_1", "keypad_2",
    "keypad_3", "keypad_4", "keypad_5", "keypad_6", "keypad_7", "keypad_8", "keypad_9", "keypad_0", "keypad_period",
    "non_us_backslash", "application", "power", "keypad_equal_sign", "help", "international1", "international2",
    "international3", "lang1", "lang2", "keypad_comma", "left_control", "left_shift", "left_option", "left_command",
    "right_control", "right_shift", "right_option", "right_command", "fn",
];

/// 키 하나 (Karabiner key_code 이름의 번호)
#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Key(pub u16);

fn index() -> &'static HashMap<&'static str, u16> {
    static INDEX: OnceLock<HashMap<&'static str, u16>> = OnceLock::new();
    INDEX.get_or_init(|| KEY_NAMES.iter().enumerate().map(|(i, n)| (*n, i as u16)).collect())
}

impl Key {
    /// Karabiner 이름으로. 모르는 이름이면 None.
    pub fn named(name: &str) -> Option<Key> {
        index().get(name).map(|&i| Key(i))
    }

    /// 시험·코드에서 쓰는 짧은 꼴. 이름이 틀리면 멈춘다.
    pub fn of(name: &str) -> Key {
        Key::named(name).unwrap_or_else(|| panic!("모르는 키 이름: {name}"))
    }

    pub fn name(self) -> &'static str {
        KEY_NAMES.get(self.0 as usize).copied().unwrap_or("?")
    }

    /// 수정키라면 그 수정키 비트
    pub fn modifier(self) -> Option<Mods> {
        Mods::from_name(self.name()).filter(|m| !m.is_empty() && *m != Mods::CAPS)
    }
}

impl fmt::Debug for Key {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// 누른 수정키들. 왼쪽·오른쪽을 따로 센다. option = Alt, command = Super(윈도우 키) 로 본다.
#[derive(Copy, Clone, PartialEq, Eq, Hash, Default)]
pub struct Mods(pub u16);

impl Mods {
    pub const NONE: Mods = Mods(0);
    pub const LSHIFT: Mods = Mods(1 << 0);
    pub const RSHIFT: Mods = Mods(1 << 1);
    pub const LCTRL: Mods = Mods(1 << 2);
    pub const RCTRL: Mods = Mods(1 << 3);
    pub const LALT: Mods = Mods(1 << 4);
    pub const RALT: Mods = Mods(1 << 5);
    pub const LMETA: Mods = Mods(1 << 6);
    pub const RMETA: Mods = Mods(1 << 7);
    pub const CAPS: Mods = Mods(1 << 8);
    pub const FN: Mods = Mods(1 << 9);

    /// (Karabiner 일반 이름, 왼쪽, 오른쪽)
    pub const SIDES: [(&'static str, Mods, Mods); 4] = [
        ("shift", Mods::LSHIFT, Mods::RSHIFT),
        ("control", Mods::LCTRL, Mods::RCTRL),
        ("option", Mods::LALT, Mods::RALT),
        ("command", Mods::LMETA, Mods::RMETA),
    ];

    /// 하나씩: (Karabiner 이름, 비트)
    pub const EACH: [(&'static str, Mods); 10] = [
        ("left_shift", Mods::LSHIFT),
        ("right_shift", Mods::RSHIFT),
        ("left_control", Mods::LCTRL),
        ("right_control", Mods::RCTRL),
        ("left_option", Mods::LALT),
        ("right_option", Mods::RALT),
        ("left_command", Mods::LMETA),
        ("right_command", Mods::RMETA),
        ("caps_lock", Mods::CAPS),
        ("fn", Mods::FN),
    ];

    pub fn contains(self, other: Mods) -> bool {
        self.0 & other.0 == other.0
    }
    pub fn intersects(self, other: Mods) -> bool {
        self.0 & other.0 != 0
    }
    pub fn is_empty(self) -> bool {
        self.0 == 0
    }
    pub fn minus(self, other: Mods) -> Mods {
        Mods(self.0 & !other.0)
    }

    /// Karabiner 이름 하나(left_shift, caps_lock, fn). 일반 이름(shift)은 왼쪽으로 본다(to 의 modifiers 처럼).
    pub fn from_name(name: &str) -> Option<Mods> {
        if let Some((_, m)) = Mods::EACH.iter().find(|(n, _)| *n == name) {
            return Some(*m);
        }
        Mods::SIDES.iter().find(|(n, _, _)| *n == name).map(|(_, l, _)| *l)
    }

    /// 지금 눌린 수정키들의 Karabiner 이름
    pub fn names(self) -> Vec<&'static str> {
        Mods::EACH.iter().filter(|(_, m)| self.contains(*m)).map(|(n, _)| *n).collect()
    }

    /// left_shift → shift 처럼 일반 이름 (수정키가 아니면 그대로)
    pub fn generic(name: &str) -> &str {
        for (g, _, _) in Mods::SIDES {
            if name.ends_with(g) {
                return g;
            }
        }
        name
    }
}

impl std::ops::BitOr for Mods {
    type Output = Mods;
    fn bitor(self, rhs: Mods) -> Mods {
        Mods(self.0 | rhs.0)
    }
}

impl std::ops::BitOrAssign for Mods {
    fn bitor_assign(&mut self, rhs: Mods) {
        self.0 |= rhs.0;
    }
}

impl fmt::Debug for Mods {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if self.is_empty() {
            return f.write_str("-");
        }
        f.write_str(&self.names().join("+"))
    }
}
