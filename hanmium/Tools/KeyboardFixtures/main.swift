import AppKit

// 키보드 규칙 엔진(KeyboardEngine) 회귀 시험. Karabiner 에서 옮겨 온 규칙과 같은 모양(rules.json)으로 키 입력을 차례로 넣고
// 내보내는 것이 맞는지 본다. 실제 키를 보내지 않는다. Tools/keyboard-fixtures.sh 로 돌린다.

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tools/KeyboardFixtures/rules.json"
let root = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
let rules = (root["rules"] as! [[String: Any]]).map { KeyRule(json: $0) }

func makeEngine() -> KeyboardEngine {
    let engine = KeyboardEngine()
    var compiled = KeyboardEngine.Rules()
    compiled.manipulators = rules.flatMap { $0.manipulators.compactMap { $0 } }
    compiled.simple = [KeyNames.code("f13")!: KeyNames.code("escape")!]
    engine.rules = compiled
    return engine
}

typealias O = KeyboardEngine.Output
let k = { (n: String) in KeyNames.code(n)! }
let none: CGEventFlags = []
let lshift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02)
let lopt = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
let caps = CGEventFlags.maskAlphaShift
let cmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
let arrow = CGEventFlags(rawValue: CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue)

var failures = 0
var checks = 0
func expect<T: Equatable>(_ name: String, _ got: T, _ want: T, line: Int = #line) {
    checks += 1
    if got != want {
        failures += 1
        print("✗ \(name) (줄 \(line))\n    받음: \(got)\n    기대: \(want)")
    }
}
func expect(_ name: String, _ got: [O], _ want: [O], line: Int = #line) {
    checks += 1
    if got != want {
        failures += 1
        print("✗ \(name) (줄 \(line))\n    받음: \(got)\n    기대: \(want)")
    }
}

// 0. 키보드별 바꾸기(키보드 A: ISO 로 보여 왼쪽 위가 § 인 키보드, § → ₩)·키보드 조건(device_if). 다른 키보드와 모르는 키보드는 그대로.
do {
    let kbA = KeyEventSource(identity: KeyboardIdentity(vendorID: 0xFFFE, productID: 0x0001), builtIn: false)
    let kbB = KeyEventSource(identity: KeyboardIdentity(vendorID: 0xFFFE, productID: 0x0002), builtIn: false)
    let e = makeEngine()
    e.rules.deviceKeys = [kbA.identity: [k("non_us_backslash"): k("grave_accent_and_tilde")]]
    let sec = k("non_us_backslash")
    expect("키보드 A § 누름(₩ 레이어)", e.keyDown(sec, flags: none, isRepeat: false, time: 0, device: kbA), [])
    expect("키보드 A § + h → ←", e.keyDown(k("h"), flags: none, isRepeat: false, time: 0.1, device: kbA),
           [.key(123, down: true, flags: arrow, isRepeat: false)])
    _ = e.keyUp(k("h"), flags: none, time: 0.2)
    expect("키보드 A § 뗌", e.keyUp(sec, flags: none, time: 0.3), [])
    expect("키보드 A § 혼자 → ₩", e.keyDown(sec, flags: none, isRepeat: false, time: 1, device: kbA), [])
    expect("키보드 A § 혼자 뗌", e.keyUp(sec, flags: none, time: 1.1),
           [.key(50, down: true, flags: none, isRepeat: false), .key(50, down: false, flags: none, isRepeat: false)])
    expect("키보드 B § 그대로", e.keyDown(sec, flags: none, isRepeat: false, time: 2, device: kbB), [.pass])
    expect("키보드 B § 뗌 그대로", e.keyUp(sec, flags: none, time: 2.1), [.pass])
    expect("모르는 키보드 § 그대로", e.keyDown(sec, flags: none, isRepeat: false, time: 3), [.pass])
    _ = e.keyUp(sec, flags: none, time: 3.1)
    // 규칙에 안 걸리는 키를 키보드별로 바꾸면 바꾼 키로(반복·뗌도)
    e.rules.deviceKeys[kbA.identity]![k("q")] = k("w")
    expect("키보드 A q → w", e.keyDown(k("q"), flags: none, isRepeat: false, time: 4, device: kbA),
           [.key(k("w"), down: true, flags: none, isRepeat: false)])
    expect("키보드 A q 반복 → w", e.keyDown(k("q"), flags: none, isRepeat: true, time: 4.5, device: kbA),
           [.key(k("w"), down: true, flags: none, isRepeat: true)])
    expect("키보드 A q 뗌 → w", e.keyUp(k("q"), flags: none, time: 4.6), [.key(k("w"), down: false, flags: none, isRepeat: false)])
    // device_if: 규칙을 키보드 A 에서만
    var rule = KeyRule(json: ["description": "키보드 A 에서만 x → y", "manipulators": [
        ["type": "basic", "from": ["key_code": "x"], "to": [["key_code": "y"]]]]])
    rule.setKeyboards([kbA.identity])
    expect("규칙의 키보드", rule.keyboards.map(\.productID), [0x0001])
    e.rules.manipulators = rule.manipulators.compactMap { $0 } + e.rules.manipulators
    expect("키보드 A x → y", e.keyDown(k("x"), flags: none, isRepeat: false, time: 5, device: kbA),
           [.key(k("y"), down: true, flags: none, isRepeat: false)])
    _ = e.keyUp(k("x"), flags: none, time: 5.1)
    expect("키보드 B x 그대로", e.keyDown(k("x"), flags: none, isRepeat: false, time: 6, device: kbB), [.pass])
    _ = e.keyUp(k("x"), flags: none, time: 6.1)
    rule.setKeyboards([])
    expect("모든 키보드로 되돌림", rule.keyboards.count, 0)
}

// 1. ₩ 만 짧게: 뗄 때 ₩
do {
    let e = makeEngine()
    expect("₩ 누름", e.keyDown(k("grave_accent_and_tilde"), flags: none, isRepeat: false, time: 0), [])
    expect("₩ 뗌", e.keyUp(k("grave_accent_and_tilde"), flags: none, time: 0.1),
           [.key(50, down: true, flags: none, isRepeat: false), .key(50, down: false, flags: none, isRepeat: false)])
    expect("₩ 뗀 뒤 h 는 그대로", e.keyDown(k("h"), flags: none, isRepeat: false, time: 0.2), [.pass])
}

// 2. ₩ + h → ←, 반복도 ←, ₩ 은 나가지 않음
do {
    let e = makeEngine()
    _ = e.keyDown(k("grave_accent_and_tilde"), flags: none, isRepeat: false, time: 0)
    expect("₩+h", e.keyDown(k("h"), flags: none, isRepeat: false, time: 0.1),
           [.key(123, down: true, flags: arrow, isRepeat: false)])
    expect("₩+h 반복", e.keyDown(k("h"), flags: none, isRepeat: true, time: 0.6),
           [.key(123, down: true, flags: arrow, isRepeat: true)])
    expect("h 뗌", e.keyUp(k("h"), flags: none, time: 0.7), [.key(123, down: false, flags: arrow, isRepeat: false)])
    expect("₩ 뗌(다른 키를 눌렀으니 ₩ 없음)", e.keyUp(k("grave_accent_and_tilde"), flags: none, time: 0.8), [])
}

// 3. ₩ 을 1초 넘게 누르고 떼면 아무것도 없음
do {
    let e = makeEngine()
    _ = e.keyDown(k("grave_accent_and_tilde"), flags: none, isRepeat: false, time: 0)
    expect("₩ 오래 누름", e.keyUp(k("grave_accent_and_tilde"), flags: none, time: 1.2), [])
}

// 4. Tab → Hanmium 라벨, Hanmium 을 쓸 수 없으면 Tab 그대로
do {
    let e = makeEngine()
    expect("Tab", e.keyDown(k("tab"), flags: none, isRepeat: false, time: 0), [.hanmium("labels")])
    expect("Tab 뗌", e.keyUp(k("tab"), flags: none, time: 0.1), [])
    expect("Caps Lock 켠 Tab", e.keyDown(k("tab"), flags: caps, isRepeat: false, time: 1), [.hanmium("labels")])
    _ = e.keyUp(k("tab"), flags: caps, time: 1.1)
    expect("⌘Tab 은 그대로", e.keyDown(k("tab"), flags: cmd, isRepeat: false, time: 2), [.pass])
    expect("⌘Tab 뗌도 그대로", e.keyUp(k("tab"), flags: cmd, time: 2.1), [.pass])
    e.hanmiumAvailable = { _ in false }
    expect("Hanmium 꺼짐 → Tab 그대로", e.keyDown(k("tab"), flags: none, isRepeat: false, time: 3), [.pass])
    expect("Hanmium 꺼짐 → Tab 뗌 그대로", e.keyUp(k("tab"), flags: none, time: 3.1), [.pass])
}

// 5. ₩ + Tab → Tab
do {
    let e = makeEngine()
    _ = e.keyDown(k("grave_accent_and_tilde"), flags: none, isRepeat: false, time: 0)
    expect("₩+Tab", e.keyDown(k("tab"), flags: none, isRepeat: false, time: 0.1),
           [.key(48, down: true, flags: none, isRepeat: false)])
    expect("₩+Tab 뗌", e.keyUp(k("tab"), flags: none, time: 0.2), [.key(48, down: false, flags: none, isRepeat: false)])
    _ = e.keyUp(k("grave_accent_and_tilde"), flags: none, time: 0.3)
}

// 6. ⌥h → 포인터 ←(⌥ 은 빼고), 뗄 때 멈춤
do {
    let e = makeEngine()
    let v = MouseKeyVector(x: -1536, y: nil, verticalWheel: nil, horizontalWheel: nil, speedMultiplier: nil)
    expect("⌥h", e.keyDown(k("h"), flags: lopt, isRepeat: false, time: 0), [.motionStart(1, v, flags: none)])
    expect("⌥h 반복은 버림", e.keyDown(k("h"), flags: lopt, isRepeat: true, time: 0.5), [])
    expect("⌥h 뗌", e.keyUp(k("h"), flags: lopt, time: 0.6), [.motionStop(1)])
    expect("⇪ 켠 ⌥h", e.keyDown(k("h"), flags: CGEventFlags(rawValue: lopt.rawValue | caps.rawValue), isRepeat: false,
                                   time: 1), [.motionStart(2, v, flags: caps)])
}

// 7. ₩ + ⌥h → 왼쪽 클릭(⌥ 없이), 뗄 때 버튼 뗌
do {
    let e = makeEngine()
    _ = e.keyDown(k("grave_accent_and_tilde"), flags: none, isRepeat: false, time: 0)
    expect("₩+⌥h", e.keyDown(k("h"), flags: lopt, isRepeat: false, time: 0.1), [.button(1, down: true, flags: none)])
    expect("₩+⌥h 뗌", e.keyUp(k("h"), flags: lopt, time: 0.2), [.button(1, down: false, flags: none)])
}

// 8. ⇧NumLock 으로 마우스 모드, 숫자패드 8·5·7·9, 다시 ⇧NumLock 이면 그대로
do {
    let e = makeEngine()
    let numpad = CGEventFlags.maskNumericPad
    expect("숫자패드 8 (마우스 모드 전)", e.keyDown(k("keypad_8"), flags: numpad, isRepeat: false, time: 0), [.pass])
    _ = e.keyUp(k("keypad_8"), flags: numpad, time: 0.1)
    expect("⇧NumLock", e.keyDown(k("keypad_num_lock"), flags: lshift, isRepeat: false, time: 1), [])
    _ = e.keyUp(k("keypad_num_lock"), flags: lshift, time: 1.1)
    let up = MouseKeyVector(x: nil, y: -1536, verticalWheel: nil, horizontalWheel: nil, speedMultiplier: nil)
    expect("숫자패드 8", e.keyDown(k("keypad_8"), flags: numpad, isRepeat: false, time: 2), [.motionStart(1, up, flags: none)])
    expect("숫자패드 8 뗌", e.keyUp(k("keypad_8"), flags: numpad, time: 2.1), [.motionStop(1)])
    expect("숫자패드 5", e.keyDown(k("keypad_5"), flags: numpad, isRepeat: false, time: 3), [.button(1, down: true, flags: none)])
    expect("숫자패드 5 뗌", e.keyUp(k("keypad_5"), flags: numpad, time: 3.1), [.button(1, down: false, flags: none)])
    expect("숫자패드 7 → Home", e.keyDown(k("keypad_7"), flags: numpad, isRepeat: false, time: 4),
           [.key(115, down: true, flags: .maskSecondaryFn, isRepeat: false)])
    _ = e.keyUp(k("keypad_7"), flags: numpad, time: 4.1)
    let wheel = MouseKeyVector(x: nil, y: nil, verticalWheel: -48, horizontalWheel: nil, speedMultiplier: nil)
    expect("숫자패드 9 → 휠 위", e.keyDown(k("keypad_9"), flags: numpad, isRepeat: false, time: 5), [.motionStart(2, wheel, flags: none)])
    _ = e.keyUp(k("keypad_9"), flags: numpad, time: 5.1)
    _ = e.keyDown(k("keypad_num_lock"), flags: lshift, isRepeat: false, time: 6)
    _ = e.keyUp(k("keypad_num_lock"), flags: lshift, time: 6.1)
    expect("마우스 모드 끈 뒤 숫자패드 8", e.keyDown(k("keypad_8"), flags: numpad, isRepeat: false, time: 7), [.pass])
}

// 9. ₩ + Space + ⇧h → ⌥⇧← (단어 선택), ₩ + Space 짧게 → Space
do {
    let e = makeEngine()
    _ = e.keyDown(k("grave_accent_and_tilde"), flags: none, isRepeat: false, time: 0)
    expect("₩+Space", e.keyDown(k("spacebar"), flags: none, isRepeat: false, time: 0.1), [])
    let word = CGEventFlags(rawValue: arrow.rawValue | lopt.rawValue | CGEventFlags.maskShift.rawValue | 0x02 | 0x04)
    expect("₩+Space+⇧h", e.keyDown(k("h"), flags: lshift, isRepeat: false, time: 0.2),
           [.key(123, down: true, flags: word, isRepeat: false)])
    _ = e.keyUp(k("h"), flags: lshift, time: 0.3)
    expect("Space 뗌(다른 키를 눌렀으니 Space 없음)", e.keyUp(k("spacebar"), flags: none, time: 0.4), [])
    expect("₩+Space 짧게", e.keyDown(k("spacebar"), flags: none, isRepeat: false, time: 0.5), [])
    expect("Space 혼자 뗌", e.keyUp(k("spacebar"), flags: none, time: 0.6),
           [.key(49, down: true, flags: none, isRepeat: false), .key(49, down: false, flags: none, isRepeat: false)])
    expect("Space 뗀 뒤 h → ⌥←(단어)가 아니라 ←", e.keyDown(k("h"), flags: none, isRepeat: false, time: 0.7),
           [.key(123, down: true, flags: arrow, isRepeat: false)])
}

// 10. ⇧₩ 짧게 → ~ (⇧ 는 optional any 라 그대로)
do {
    let e = makeEngine()
    _ = e.flagsChanged(lshift)
    _ = e.keyDown(k("grave_accent_and_tilde"), flags: lshift, isRepeat: false, time: 0)
    expect("⇧₩", e.keyUp(k("grave_accent_and_tilde"), flags: lshift, time: 0.1),
           [.key(50, down: true, flags: lshift, isRepeat: false), .key(50, down: false, flags: lshift, isRepeat: false)])
}

// 11. ₩ 누른 채 ⇧ 를 누르면(다른 키) ₩ 는 나가지 않음
do {
    let e = makeEngine()
    _ = e.keyDown(k("grave_accent_and_tilde"), flags: none, isRepeat: false, time: 0)
    _ = e.flagsChanged(lshift)
    expect("₩ 누르는 중 ⇧", e.keyUp(k("grave_accent_and_tilde"), flags: lshift, time: 0.2), [])
}

// 12. 그 밖의 키·단순 바꾸기·지원 안 하는 조작
do {
    let e = makeEngine()
    expect("a", e.keyDown(k("a"), flags: none, isRepeat: false, time: 0), [.pass])
    expect("a 반복", e.keyDown(k("a"), flags: none, isRepeat: true, time: 0.5), [.pass])
    expect("a 뗌", e.keyUp(k("a"), flags: none, time: 0.6), [.pass])
    expect("F13 → Esc", e.keyDown(k("f13"), flags: none, isRepeat: false, time: 1), [.key(53, down: true, flags: none, isRepeat: false)])
    expect("F13 뗌", e.keyUp(k("f13"), flags: none, time: 1.1), [.key(53, down: false, flags: none, isRepeat: false)])
    let unsupported = rules.last!.manipulators.first!!
    expect("simultaneous 는 지원 안 함", unsupported.isSupported ? [.pass] : [], [])
}

// 13. 요약 문구
print(rules[3].manipulators.compactMap { $0?.summary }.joined(separator: "\n"))

if failures == 0 {
    print("키보드 규칙 시험 \(checks)개 모두 통과")
} else {
    print("키보드 규칙 시험 \(checks)개 중 \(failures)개 실패")
    exit(1)
}
