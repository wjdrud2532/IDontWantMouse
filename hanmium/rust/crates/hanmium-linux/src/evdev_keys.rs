//! 리눅스 evdev 키 코드 ↔ Karabiner 키 이름. GNOME 확장이 보내는 하드웨어 키 코드는 evdev + 8 이다.

use hanmium_core::Key;

/// (evdev 코드, Karabiner 이름)
pub const TABLE: &[(u16, &str)] = &[
    (1, "escape"), (2, "1"), (3, "2"), (4, "3"), (5, "4"), (6, "5"), (7, "6"), (8, "7"), (9, "8"), (10, "9"), (11, "0"),
    (12, "hyphen"), (13, "equal_sign"), (14, "delete_or_backspace"), (15, "tab"), (16, "q"), (17, "w"), (18, "e"),
    (19, "r"), (20, "t"), (21, "y"), (22, "u"), (23, "i"), (24, "o"), (25, "p"), (26, "open_bracket"),
    (27, "close_bracket"), (28, "return_or_enter"), (29, "left_control"), (30, "a"), (31, "s"), (32, "d"), (33, "f"),
    (34, "g"), (35, "h"), (36, "j"), (37, "k"), (38, "l"), (39, "semicolon"), (40, "quote"),
    (41, "grave_accent_and_tilde"), (42, "left_shift"), (43, "backslash"), (44, "z"), (45, "x"), (46, "c"), (47, "v"),
    (48, "b"), (49, "n"), (50, "m"), (51, "comma"), (52, "period"), (53, "slash"), (54, "right_shift"),
    (55, "keypad_asterisk"), (56, "left_option"), (57, "spacebar"), (58, "caps_lock"), (59, "f1"), (60, "f2"),
    (61, "f3"), (62, "f4"), (63, "f5"), (64, "f6"), (65, "f7"), (66, "f8"), (67, "f9"), (68, "f10"),
    (69, "keypad_num_lock"), (70, "scroll_lock"), (71, "keypad_7"), (72, "keypad_8"), (73, "keypad_9"),
    (74, "keypad_hyphen"), (75, "keypad_4"), (76, "keypad_5"), (77, "keypad_6"), (78, "keypad_plus"), (79, "keypad_1"),
    (80, "keypad_2"), (81, "keypad_3"), (82, "keypad_0"), (83, "keypad_period"), (86, "non_us_backslash"),
    (87, "f11"), (88, "f12"), (96, "keypad_enter"), (97, "right_control"), (98, "keypad_slash"), (99, "print_screen"),
    (100, "right_option"), (102, "home"), (103, "up_arrow"), (104, "page_up"), (105, "left_arrow"),
    (106, "right_arrow"), (107, "end"), (108, "down_arrow"), (109, "page_down"), (110, "insert"),
    (111, "delete_forward"), (117, "keypad_equal_sign"), (119, "pause"), (121, "keypad_comma"), (122, "lang1"),
    (123, "lang2"), (125, "left_command"), (126, "right_command"), (127, "application"), (183, "f13"), (184, "f14"),
    (185, "f15"), (186, "f16"), (187, "f17"), (188, "f18"), (189, "f19"), (190, "f20"), (191, "f21"), (192, "f22"),
    (193, "f23"), (194, "f24"),
];

pub fn key(code: u16) -> Option<Key> {
    TABLE.iter().find(|(c, _)| *c == code).and_then(|(_, n)| Key::named(n))
}

pub fn code(key: Key) -> Option<u16> {
    TABLE.iter().find(|(_, n)| *n == key.name()).map(|(c, _)| *c)
}

/// 라벨·스크롤 키로 쓰는 글자 (자판 배치·한글 입력기와 상관없이 키 자리로)
pub fn char_of(code: u16) -> Option<char> {
    let name = key(code)?.name();
    let mut chars = name.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) => Some(c),
        _ => match name {
            "slash" => Some('/'),
            _ => None,
        },
    }
}
