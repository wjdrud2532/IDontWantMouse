//! 수정키 맞추기. 맥은 키 이벤트마다 수정키 플래그를 붙일 수 있지만 리눅스(uinput)·윈도우(SendInput)는 수정키 상태가 곧
//! 그 장치에서 눌려 있는 수정키다. 그래서 바꾼 키를 내보내기 전에 수정키를 실제로 눌렀다 떼서 원하는 상태로 맞춘다
//! (₩+Space+h → ⌥← 는 ⌥ 를 누르고 ← 를 누르고, ⌥+h → 포인터 이동 중에는 ⌥ 를 뗀다).

use crate::keys::{Key, Mods};

/// 비트마다 그 수정키의 키 (왼쪽·오른쪽)
pub const MOD_KEYS: [(Mods, &str); 8] = [
    (Mods::LSHIFT, "left_shift"),
    (Mods::RSHIFT, "right_shift"),
    (Mods::LCTRL, "left_control"),
    (Mods::RCTRL, "right_control"),
    (Mods::LALT, "left_option"),
    (Mods::RALT, "right_option"),
    (Mods::LMETA, "left_command"),
    (Mods::RMETA, "right_command"),
];

/// 내보내는 장치의 수정키를 now 에서 want 로 바꾸려면 누르고 뗄 키들. 떼는 것을 먼저 한다.
/// caps_lock·fn 은 켜고 끄는 상태라 건드리지 않는다.
pub fn reconcile(now: Mods, want: Mods) -> Vec<(Key, bool)> {
    let mut out = vec![];
    for (bit, name) in MOD_KEYS {
        if now.contains(bit) && !want.contains(bit) {
            out.push((Key::of(name), false));
        }
    }
    for (bit, name) in MOD_KEYS {
        if !now.contains(bit) && want.contains(bit) {
            out.push((Key::of(name), true));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_then_press() {
        let r = reconcile(Mods::LALT | Mods::LSHIFT, Mods::LSHIFT | Mods::LMETA);
        assert_eq!(r, vec![(Key::of("left_option"), false), (Key::of("left_command"), true)]);
        assert!(reconcile(Mods::CAPS, Mods::NONE).is_empty());
    }
}
