// Hanmium 키 바꾸기(키보드 규칙) 실제 키 시험. Tools/live-keys.sh 로 돌린다.
// 시험 키를 HID 단계로 보내면(사용자 데이터 'TEST') 앞에 있는 Hanmium 탭이 받아 바꾼다. 바뀐 결과(Hanmium 표시 'HNMK')와
// 그대로 지나간 키는 세션 단계 탭에서 기록한 뒤 버려서 앱에는 닿지 않는다. 포인터 이동만 실제로 움직이고 끝나면 되돌린다.
//   - HID 탭(듣기만, Hanmium 탭보다 앞): 사용자의 진짜 입력이 섞이면 그 항목을 다시 한다.
//   - 세션 뒤 탭(듣기만): 시험 키가 앱까지 새어 나가면 바로 멈춘다.
// 기대 값은 사용자 규칙(~/Library/Application Support/Hanmium/keyboard.json: ₩ 레이어, 마우스 모드, ⌥hjkl, Tab)에 맞춰 적었다.
// 규칙을 바꾸면 아래 항목도 고친다.  인자로 항목 이름 일부를 주면 그 항목만 돌린다:  live-keys.sh 포인터 마우스
import Cocoa
import CoreGraphics
import IOKit
import IOKit.hid

let TEST: Int64 = 0x5445_5354
let HNMK: Int64 = 0x484E_4D4B

final class Rec {
    let lock = NSLock()
    var dropping = false      // TEST·HNMK 이벤트 버리기
    var strict = false        // 진짜 키도 버리기 (라벨 시험 동안)
    var capturing = false
    var outs: [String] = []
    var scrollSum = 0, scrollEvents = 0, moves = 0
    var interfere: [String] = []
    var interfereMouse = 0
    var lastReal = Date()
    var ts: (UInt64, UInt64, UInt64)?
    var leaks: [String] = []
    /// HID 탭에서 본 시험 키의 키보드 표시(칸 87). 보낸 값이 그대로 오는지 확인한다.
    var seenDevices = Set<UInt64>()
}
let rec = Rec()

func mods(_ f: CGEventFlags) -> String {
    var s = ""
    if f.contains(.maskControl) { s += "⌃" }
    if f.contains(.maskAlternate) { s += "⌥" }
    if f.contains(.maskShift) { s += "⇧" }
    if f.contains(.maskCommand) { s += "⌘" }
    return s
}

var rawPort: CFMachPort?
var outPort: CFMachPort?

let rawCB: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let p = rawPort { CGEvent.tapEnable(tap: p, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let ud = event.getIntegerValueField(.eventSourceUserData)
    rec.lock.lock()
    if ud == TEST, rec.ts == nil {
        rec.ts = (event.timestamp, mach_absolute_time(), clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }
    if ud == TEST, type == .keyDown || type == .keyUp || type == .flagsChanged {
        rec.seenDevices.insert(UInt64(bitPattern: event.getIntegerValueField(serviceField)))
    }
    if ud != TEST && ud != HNMK {
        let isMove = type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged || type == .scrollWheel
        rec.lastReal = Date()
        if rec.capturing {
            if isMove { rec.interfereMouse += 1 }
            else { rec.interfere.append("t\(type.rawValue) k\(event.getIntegerValueField(.keyboardEventKeycode)) ud\(ud)") }
        }
    }
    rec.lock.unlock()
    return Unmanaged.passUnretained(event)
}

let outCB: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let p = outPort { CGEvent.tapEnable(tap: p, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let ud = event.getIntegerValueField(.eventSourceUserData)
    let ours = ud == TEST || ud == HNMK
    let src = ud == HNMK ? "*" : ud == TEST ? "=" : "?"
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    rec.lock.lock()
    defer { rec.lock.unlock() }
    let isKey = type == .keyDown || type == .keyUp || type == .flagsChanged
    let drop = rec.dropping && (ours || (rec.strict && isKey))
    if rec.capturing && ours {
        switch type {
        case .keyDown:
            let r = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? "r" : ""
            rec.outs.append("\(src)↓\(code)\(mods(event.flags))\(r)")
        case .keyUp: rec.outs.append("\(src)↑\(code)\(mods(event.flags))")
        case .flagsChanged: rec.outs.append("\(src)F\(code)\(mods(event.flags))")
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let n = event.getIntegerValueField(.mouseEventButtonNumber) + 1
            let c = event.getIntegerValueField(.mouseEventClickState)
            rec.outs.append("\(src)M\(n)↓" + (c > 1 ? "c\(c)" : ""))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            rec.outs.append("\(src)M\(event.getIntegerValueField(.mouseEventButtonNumber) + 1)↑")
        case .scrollWheel:
            rec.scrollSum += Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            rec.scrollEvents += 1
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            rec.moves += 1
        default: break
        }
    }
    if type == .mouseMoved { return Unmanaged.passUnretained(event) }  // 포인터는 실제로 움직이게 둔다
    return drop ? nil : Unmanaged.passUnretained(event)
}

var leakPort: CFMachPort?
let leakCB: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let p = leakPort { CGEvent.tapEnable(tap: p, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let ud = event.getIntegerValueField(.eventSourceUserData)
    if (ud == TEST || ud == HNMK) && type != .mouseMoved {
        rec.lock.lock(); rec.leaks.append("t\(type.rawValue) k\(event.getIntegerValueField(.keyboardEventKeycode))"); rec.lock.unlock()
    }
    return Unmanaged.passUnretained(event)
}

func mask(_ types: [CGEventType]) -> CGEventMask { types.reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) } }
let all: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                          .otherMouseDown, .otherMouseUp, .scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
guard let rp = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                 eventsOfInterest: mask(all), callback: rawCB, userInfo: nil),
      let op = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                 eventsOfInterest: mask(all), callback: outCB, userInfo: nil)
else { print("탭을 만들 수 없음"); exit(1) }
guard let lp = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                 eventsOfInterest: mask(all), callback: leakCB, userInfo: nil)
else { print("확인 탭을 만들 수 없음"); exit(1) }
rawPort = rp; outPort = op; leakPort = lp
for p in [rp, op, lp] {
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, p, 0), .commonModes)
    CGEvent.tapEnable(tap: p, enable: true)
}

// MARK: 보내기
let source = CGEventSource(stateID: .privateState)
let NONE = CGEventFlags(rawValue: 0x100)
let LSHIFT = CGEventFlags(rawValue: 0x100 | 0x2 | CGEventFlags.maskShift.rawValue)
let LOPT = CGEventFlags(rawValue: 0x100 | 0x20 | CGEventFlags.maskAlternate.rawValue)
let LCTRL = CGEventFlags(rawValue: 0x100 | 0x1 | CGEventFlags.maskControl.rawValue)
let LCMD = CGEventFlags(rawValue: 0x100 | 0x8 | CGEventFlags.maskCommand.rawValue)
let LOPTSHIFT = CGEventFlags(rawValue: LOPT.rawValue | LSHIFT.rawValue)
let NP = CGEventFlags(rawValue: 0x100 | CGEventFlags.maskNumericPad.rawValue)
func plus(_ a: CGEventFlags, _ b: CGEventFlags) -> CGEventFlags { CGEventFlags(rawValue: a.rawValue | b.rawValue) }

func wait(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }
/// 시험 키를 이 키보드에서 온 것처럼(이벤트의 서비스 ID 칸 87, Hanmium 키보드별 설정 시험). 0 이면 표시 없음.
var defaultDevice: UInt64 = 0
var testDevice: UInt64 = 0
let serviceField = unsafeBitCast(UInt32(87), to: CGEventField.self)
func key(_ c: UInt16, _ down: Bool, _ f: CGEventFlags = NONE, rep: Bool = false) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: down) else { return }
    e.flags = f
    if testDevice != 0 { e.setIntegerValueField(serviceField, value: Int64(bitPattern: testDevice)) }
    if rep { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    e.setIntegerValueField(.eventSourceUserData, value: TEST)
    e.post(tap: .cghidEventTap)
    wait(0.012)
}
func tap(_ c: UInt16, _ f: CGEventFlags = NONE) { key(c, true, f); wait(0.03); key(c, false, f); wait(0.03) }
func mod(_ c: UInt16, _ f: CGEventFlags) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: true) else { return }
    e.type = .flagsChanged
    e.flags = f
    if testDevice != 0 { e.setIntegerValueField(serviceField, value: Int64(bitPattern: testDevice)) }
    e.setIntegerValueField(.eventSourceUserData, value: TEST)
    e.post(tap: .cghidEventTap)
    wait(0.02)
}
func hold(_ c: UInt16, _ f: CGEventFlags, _ s: Double) {
    key(c, true, f)
    var t = 0.0
    // 실제 키보드처럼 0.25초 뒤부터 반복 입력도 보낸다
    while t < s { wait(0.05); t += 0.05; if t > 0.25 { key(c, true, f, rep: true) } }
    key(c, false, f)
}
var origin: CGPoint?
func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
func overlayWindows() -> Int {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter {
        ($0[kCGWindowOwnerName as String] as? String) == "Hanmium" &&
        (($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0) > 200
    }.count
}
func logLines() -> Int {
    (try? String(contentsOfFile: NSHomeDirectory() + "/Library/Logs/Hanmium.log", encoding: .utf8))?
        .split(separator: "\n").filter { $0.contains("라벨 모드") }.count ?? 0
}

let G: UInt16 = 50, SP: UInt16 = 49, H: UInt16 = 4, J: UInt16 = 38, K: UInt16 = 40, L: UInt16 = 37
let TAB: UInt16 = 48, SEMI: UInt16 = 41, A: UInt16 = 0, C: UInt16 = 8, NUMLOCK: UInt16 = 71
let KP: [String: UInt16] = ["0": 82, "1": 83, "2": 84, "3": 85, "4": 86, "5": 87, "6": 88, "7": 89, "8": 91, "9": 92,
                            ".": 65, "*": 67, "/": 75, "-": 78]
let LSHIFTK: UInt16 = 56, LOPTK: UInt16 = 58, LCTRLK: UInt16 = 59, LCMDK: UInt16 = 55

struct Result { var outs: [String]; var scroll: Int; var scrollEvents: Int; var moved: CGVector; var moves: Int; var extra: String }
struct Case {
    let name: String
    var mouse = false
    var strict = false
    let run: () -> String
    let check: (Result) -> String?
}
func keysOnly(_ r: Result) -> [String] { r.outs.filter { !$0.hasPrefix("=F") } }
func expect(_ e: [String]) -> (Result) -> String? {
    { r in keysOnly(r) == e ? nil : "기대 \(e)" }
}
func move(_ c: UInt16, _ f: CGEventFlags, pre: (() -> Void)? = nil, post: (() -> Void)? = nil) -> () -> String {
    {
        let screen = CGDisplayBounds(CGMainDisplayID())
        CGWarpMouseCursorPosition(CGPoint(x: screen.midX, y: screen.midY))
        wait(0.3)
        origin = cursor()
        pre?()
        hold(c, f, 0.4)
        post?()
        wait(0.15)
        return ""
    }
}
func dirCheck(_ dx: Int, _ dy: Int) -> (Result) -> String? {
    { r in
        let m = r.moved
        if !keysOnly(r).isEmpty { return "키가 나옴" }
        func ok(_ v: CGFloat, _ want: Int) -> Bool { want == 0 ? abs(v) <= 3 : (want > 0 ? v >= 150 && v <= 700 : v <= -150 && v >= -700) }
        return ok(m.dx, dx) && ok(m.dy, dy) ? nil : "포인터 이동 기대 방향 (\(dx),\(dy))"
    }
}
func wheelCheck(up: Bool) -> (Result) -> String? {
    { r in
        if !keysOnly(r).isEmpty { return "키가 나옴" }
        return r.scrollEvents >= 5 && (up ? r.scroll > 100 : r.scroll < -100) ? nil : "휠 \(up ? "위" : "아래") 기대"
    }
}

var cases: [Case] = []
func add(_ name: String, mouse: Bool = false, strict: Bool = false, _ run: @escaping () -> Void, _ check: @escaping (Result) -> String?) {
    cases.append(Case(name: name, mouse: mouse, strict: strict, run: { run(); return "" }, check: check))
}

add("새는지 확인: F13 하나", { tap(105) }, expect(["=↓105", "=↑105"]))
add("일반 글자 a h j k l 그대로", { for c in [A, H, J, K, L] { tap(c) } },
    expect(["=↓0", "=↑0", "=↓4", "=↑4", "=↓38", "=↑38", "=↓40", "=↑40", "=↓37", "=↑37"]))
add("수정키 조합 그대로 (⌘C ⇧H ⌥A ⌥⇧H ⇧Tab ⌃Tab)", {
    mod(LCMDK, LCMD); tap(C, LCMD); mod(LCMDK, NONE)
    mod(LSHIFTK, LSHIFT); tap(H, LSHIFT); mod(LSHIFTK, NONE)
    mod(LOPTK, LOPT); tap(A, LOPT); mod(LSHIFTK, LOPTSHIFT); tap(H, LOPTSHIFT); mod(LSHIFTK, LOPT); mod(LOPTK, NONE)
    mod(LSHIFTK, LSHIFT); tap(TAB, LSHIFT); mod(LSHIFTK, NONE)
    mod(LCTRLK, LCTRL); tap(TAB, LCTRL); mod(LCTRLK, NONE)
}, expect(["=↓8⌘", "=↑8⌘", "=↓4⇧", "=↑4⇧", "=↓0⌥", "=↑0⌥", "=↓4⌥⇧", "=↑4⌥⇧", "=↓48⇧", "=↑48⇧", "=↓48⌃", "=↑48⌃"]))
add("₩ 혼자 짧게 → ₩", { key(G, true); wait(0.08); key(G, false) }, expect(["*↓50", "*↑50"]))
add("₩ 1.3초 혼자 누르고 떼기 → 아무것도 안 나옴", { hold(G, NONE, 1.3) }, expect([]))
add("₩ + h j k l → ← ↓ ↑ →", { key(G, true); wait(0.05); for c in [H, J, K, L] { tap(c) }; key(G, false) },
    expect(["*↓123", "*↑123", "*↓125", "*↑125", "*↓126", "*↑126", "*↓124", "*↑124"]))
add("₩ + j 꾹 누르기 → ↓ 반복", { key(G, true); wait(0.05); key(J, true); wait(0.3)
    for _ in 0..<3 { key(J, true, rep: true); wait(0.04) }; key(J, false); key(G, false) },
    expect(["*↓125", "*↓125r", "*↓125r", "*↓125r", "*↑125"]))
add("₩ + Space + h j k l → ⌥← ⌥↓ ⌥↑ ⌥→", { key(G, true); wait(0.05); key(SP, true); wait(0.05)
    for c in [H, J, K, L] { tap(c) }; key(SP, false); key(G, false) },
    expect(["*↓123⌥", "*↑123⌥", "*↓125⌥", "*↑125⌥", "*↓126⌥", "*↑126⌥", "*↓124⌥", "*↑124⌥"]))
add("₩ + Space + ⇧ + h l j → ⌥⇧← ⌥⇧→ ⌥⇧↓ (선택)", { key(G, true); wait(0.05); key(SP, true); wait(0.05)
    mod(LSHIFTK, LSHIFT); tap(H, LSHIFT); tap(L, LSHIFT); tap(J, LSHIFT); mod(LSHIFTK, NONE); key(SP, false); key(G, false) },
    expect(["*↓123⌥⇧", "*↑123⌥⇧", "*↓124⌥⇧", "*↑124⌥⇧", "*↓125⌥⇧", "*↑125⌥⇧"]))
add("₩ + Space 혼자 → Space", { key(G, true); wait(0.05); key(SP, true); wait(0.06); key(SP, false); key(G, false) },
    expect(["*↓49", "*↑49"]))
add("[임시 진단] ₩ + Space + 왼⇧ + ; → 9", { key(G, true); wait(0.05); key(SP, true); wait(0.05)
    mod(LSHIFTK, LSHIFT); tap(SEMI, LSHIFT); mod(LSHIFTK, NONE); key(SP, false); key(G, false) },
    expect(["*↓25", "*↑25"]))
// 키보드별 설정(keyboard.json devices) 시험: § → ₩ 를 걸어 둔 키보드가 연결돼 있으면 그 키보드의 § 는 ₩ 레이어로,
// 키보드별 설정이 없는 다른 키보드의 § 는 그대로인지 본다(macOS 가 ISO 로 보는 키보드는 왼쪽 위 키가 § = 키 코드 10).
func connectedKeyboards() -> [(vendor: Int, product: Int, service: UInt64)] {
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    return (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []).compactMap { s in
        guard IOHIDServiceClientConformsTo(s, 1, 6) != 0,
              let v = (IOHIDServiceClientCopyProperty(s, "VendorID" as CFString) as? NSNumber)?.intValue,
              let p = (IOHIDServiceClientCopyProperty(s, "ProductID" as CFString) as? NSNumber)?.intValue, v != 0,
              let id = (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value else { return nil }
        return (v, p, id)
    }
}
let settingsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Hanmium/keyboard.json")
let deviceSettings = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))) as? [String: Any])?["devices"]
    as? [[String: Any]] ?? []
func identifiers(_ d: [String: Any]) -> (Int, Int)? {
    let ids = d["identifiers"] as? [String: Any]
    guard let v = ids?["vendor_id"] as? Int, let p = ids?["product_id"] as? Int else { return nil }
    return (v, p)
}
let keyboards = connectedKeyboards()
let sectionDevice: UInt64? = deviceSettings.first { d in
    (d["simple_modifications"] as? [[String: Any]] ?? []).contains {
        ($0["from"] as? [String: Any])?["key_code"] as? String == "non_us_backslash"
            && ((($0["to"] as? [[String: Any]])?.first)?["key_code"] as? String) == "grave_accent_and_tilde"
    }
}.flatMap(identifiers).flatMap { id in keyboards.first { $0.vendor == id.0 && $0.product == id.1 }?.service }
let plainDevice: UInt64? = keyboards.first { k in
    !deviceSettings.contains { identifiers($0).map { $0 == (k.vendor, k.product) } ?? false }
}?.service
// HANMIUM_TEST_DEVICE=1234:ABCD (제조사:제품 16진수, 설정 › 키보드별 설정의 키보드 이름 옆 번호) 이면 모든 시험 키를 그 키보드에서 온 것으로 보낸다(그 키보드의 단축키 확인)
if let want = ProcessInfo.processInfo.environment["HANMIUM_TEST_DEVICE"] {
    let parts = want.split(separator: ":").compactMap { Int($0, radix: 16) }
    if parts.count == 2, let k = keyboards.first(where: { $0.vendor == parts[0] && $0.product == parts[1] }) {
        defaultDevice = k.service
    } else {
        print("HANMIUM_TEST_DEVICE=\(want) 키보드가 연결돼 있지 않음"); exit(2)
    }
}
testDevice = defaultDevice
if defaultDevice != 0 { print(String(format: "시험 키를 키보드 0x%llx 에서 온 것으로 보냄", defaultDevice)) }
let SECTION: UInt16 = 10
if let sectionDevice {
    add("키보드별 § → ₩: § 혼자 → ₩", { testDevice = sectionDevice; tap(SECTION); testDevice = defaultDevice },
        expect(["*↓50", "*↑50"]))
    add("키보드별 § → ₩: § + h j → ← ↓", { testDevice = sectionDevice; key(SECTION, true); wait(0.05); tap(H); tap(J)
        key(SECTION, false); testDevice = defaultDevice }, expect(["*↓123", "*↑123", "*↓125", "*↑125"]))
}
if let plainDevice {
    add("키보드별 설정 없는 키보드: § 그대로", { testDevice = plainDevice; tap(SECTION); testDevice = defaultDevice },
        expect(["=↓10", "=↑10"]))
}
add("₩ + Tab → Tab", { key(G, true); wait(0.05); tap(TAB); key(G, false) }, expect(["*↓48", "*↑48"]))
add("₩ + ⌥h / ⌥l → 왼쪽·오른쪽 클릭", { key(G, true); wait(0.05); mod(LOPTK, LOPT); tap(H, LOPT); wait(0.05); tap(L, LOPT)
    mod(LOPTK, NONE); key(G, false); wait(0.1) }, expect(["*M1↓", "*M1↑", "*M2↓", "*M2↑"]))
add("₩ + ⌥k → 휠 위로", mouse: true, { key(G, true); wait(0.05); mod(LOPTK, LOPT); hold(K, LOPT, 0.35); mod(LOPTK, NONE); key(G, false); wait(0.1) },
    wheelCheck(up: true))
add("₩ + ⌥j → 휠 아래로", mouse: true, { key(G, true); wait(0.05); mod(LOPTK, LOPT); hold(J, LOPT, 0.35); mod(LOPTK, NONE); key(G, false); wait(0.1) },
    wheelCheck(up: false))
for (c, n, dx, dy) in [(H, "h ←", -1, 0), (J, "j ↓", 0, 1), (K, "k ↑", 0, -1), (L, "l →", 1, 0)] {
    cases.append(Case(name: "⌥ + \(n) 포인터 이동", mouse: true,
                      run: move(c, LOPT, pre: { mod(LOPTK, LOPT) }, post: { mod(LOPTK, NONE) }), check: dirCheck(dx, dy)))
}
add("Tab → 라벨 열기, 다시 Tab → 닫기", strict: true, {}, { _ in nil })  // 아래에서 따로 처리
add("마우스 모드 상태 맞추기 (끔)", { print("   " + forceMouseMode(false)) }, { _ in nil })
add("마우스 모드 꺼짐: 숫자 패드 8 → 그대로 8", { tap(KP["8"]!, NP) }, expect(["=↓91", "=↑91"]))
add("⇧ + NumLock → 마우스 모드 켜기", { mod(LSHIFTK, LSHIFT); tap(NUMLOCK, plus(LSHIFT, NP)); mod(LSHIFTK, NONE) }, expect([]))
add("마우스 모드: 7 → Home, 1 → End", { tap(KP["7"]!, NP); tap(KP["1"]!, NP) }, expect(["*↓115", "*↑115", "*↓119", "*↑119"]))
for (k, n, dx, dy) in [("8", "8 ↑", 0, -1), ("2", "2 ↓", 0, 1), ("4", "4 ←", -1, 0), ("6", "6 →", 1, 0)] {
    cases.append(Case(name: "마우스 모드: \(n) 포인터 이동", mouse: true, run: move(KP[k]!, NP), check: dirCheck(dx, dy)))
}
add("마우스 모드: 5 / * - → 왼쪽·왼쪽·오른쪽·가운데 클릭", { for k in ["5", "/", "*", "-"] { tap(KP[k]!, NP); wait(0.6) } },
    expect(["*M1↓", "*M1↑", "*M1↓", "*M1↑", "*M2↓", "*M2↑", "*M3↓", "*M3↑"]))
add("마우스 모드: 5 두 번 빠르게 → 더블클릭", { tap(KP["5"]!, NP); wait(0.08); tap(KP["5"]!, NP); wait(0.6) },
    expect(["*M1↓", "*M1↑", "*M1↓c2", "*M1↑"]))
add("마우스 모드: 0 . → 뒤로·앞으로 버튼", { tap(KP["0"]!, NP); tap(KP["."]!, NP); wait(0.1) }, expect(["*M4↓", "*M4↑", "*M5↓", "*M5↑"]))
add("마우스 모드: 9 → 휠 위로", mouse: true, { hold(KP["9"]!, NP, 0.35); wait(0.1) }, wheelCheck(up: true))
add("마우스 모드: 3 → 휠 아래로", mouse: true, { hold(KP["3"]!, NP, 0.35); wait(0.1) }, wheelCheck(up: false))
add("⇧ + NumLock → 마우스 모드 끄기, 숫자 패드 8 → 그대로", { mod(LSHIFTK, LSHIFT); tap(NUMLOCK, plus(LSHIFT, NP)); mod(LSHIFTK, NONE); tap(KP["8"]!, NP) },
    expect(["=↓91", "=↑91"]))
add("끝난 뒤 상태: h, 숫자 패드 5 그대로", { tap(H); tap(KP["5"]!, NP) }, expect(["=↓4", "=↑4", "=↓87", "=↑87"]))

/// 숫자 패드 7 을 눌러 Home 이 나오면 마우스 모드가 켜진 것
func probeMouseMode() -> Bool? {
    rec.lock.lock(); rec.outs = []; rec.capturing = true; rec.lock.unlock()
    tap(KP["7"]!, NP); wait(0.15)
    rec.lock.lock(); rec.capturing = false; let o = rec.outs.filter { !$0.hasPrefix("=F") }; rec.lock.unlock()
    if o == ["*↓115", "*↑115"] { return true }
    if o == ["=↓89", "=↑89"] { return false }
    print("   (상태 확인 결과를 알 수 없음: \(o))")
    return nil
}
func toggleMouseMode() { mod(LSHIFTK, LSHIFT); tap(NUMLOCK, plus(LSHIFT, NP)); mod(LSHIFTK, NONE); wait(0.05) }
func forceMouseMode(_ on: Bool) -> String {
    let before = probeMouseMode()
    if let before, before != on { toggleMouseMode() }
    let after = probeMouseMode()
    return "처음 \(before.map { $0 ? "켜짐" : "꺼짐" } ?? "?") → \(after.map { $0 ? "켜짐" : "꺼짐" } ?? "?")"
}

// MARK: 실행
let filters = Array(CommandLine.arguments.dropFirst())
let start = cursor()
func waitIdle(_ s: Double) -> Bool {
    let limit = Date().addingTimeInterval(60)
    while Date() < limit {
        rec.lock.lock(); let idle = Date().timeIntervalSince(rec.lastReal); rec.lock.unlock()
        if idle >= s { return true }
        wait(0.1)
    }
    return false
}
func cleanup() {
    for c in [G, SP, H, J, K, L, TAB, SEMI] { key(c, false) }
    for (_, c) in KP { key(c, false, NP) }
    mod(LSHIFTK, NONE); mod(LOPTK, NONE)
}

DispatchQueue.global().async {
    rec.lock.lock(); rec.dropping = true; rec.lock.unlock()
    // 다른 프로그램이 스스로 보내는 입력이 있는지 1초 본다
    rec.lock.lock(); rec.capturing = true; rec.lock.unlock()
    wait(1.0)
    rec.lock.lock(); rec.capturing = false; let base = rec.interfere.count; rec.interfere = []; rec.interfereMouse = 0; rec.lock.unlock()
    print("기준선: 진짜 키 \(base)개")
    var pass = 0, fail = 0, skipped = 0
    for c in cases where filters.isEmpty || filters.contains(where: { c.name.contains($0) }) {
        var attempt = 0
        while true {
            attempt += 1
            if !waitIdle(c.strict ? 2.0 : 1.0) { print("⏭  \(c.name): 입력이 멈추지 않아 건너뜀"); skipped += 1; break }
            rec.lock.lock()
            rec.outs = []; rec.scrollSum = 0; rec.scrollEvents = 0; rec.moves = 0; rec.interfere = []; rec.interfereMouse = 0
            rec.strict = c.strict; rec.capturing = true
            rec.lock.unlock()
            var extra = ""
            var tabFail: String?
            origin = nil
            let p0 = cursor()
            if c.name.hasPrefix("Tab →") {
                let w0 = overlayWindows(), l0 = logLines()
                tap(TAB); wait(0.7)
                let w1 = overlayWindows(), l1 = logLines()
                tap(TAB); wait(0.6)
                let w2 = overlayWindows()
                extra = "창 \(w0)→\(w1)→\(w2), 라벨 로그 +\(l1 - l0)"
                if !(w1 > w0 && w2 == w0 && l1 > l0) { tabFail = "라벨이 열리고 닫혀야 함" }
            } else {
                _ = c.run()
            }
            wait(0.2)
            let p1 = cursor()
            rec.lock.lock()
            rec.capturing = false; rec.strict = false
            let r = Result(outs: rec.outs, scroll: rec.scrollSum, scrollEvents: rec.scrollEvents,
                           moved: CGVector(dx: p1.x - (origin ?? p0).x, dy: p1.y - (origin ?? p0).y), moves: rec.moves, extra: extra)
            let inter = rec.interfere, interMouse = rec.interfereMouse
            rec.lock.unlock()
            if !inter.isEmpty || (c.mouse && interMouse > 0) {
                print("↻  \(c.name): 사용자 입력과 겹쳐 다시 함 (\(inter.prefix(3)) 마우스 \(interMouse))")
                cleanup()
                if attempt < 4 { continue }
                skipped += 1; break
            }
            rec.lock.lock(); let leaks = rec.leaks; rec.lock.unlock()
            if !leaks.isEmpty { print("🛑 시험 키가 앱까지 새어 나감 \(leaks.prefix(5)) — 멈춤"); cleanup(); wait(0.3); exit(4) }
            let problem = c.name.hasPrefix("Tab →") ? (r.outs.filter { !$0.hasPrefix("=F") }.isEmpty ? tabFail : "키가 나옴") : c.check(r)
            var detail = "나옴 \(keysOnly(r))"
            if c.mouse { detail += String(format: " 포인터 (%.0f, %.0f) 이동 %d번 휠 합 %d (%d번)", r.moved.dx, r.moved.dy, r.moves, r.scroll, r.scrollEvents) }
            if !extra.isEmpty { detail += " " + extra }
            if let problem { fail += 1; print("❌ \(c.name): \(problem) / \(detail)") } else { pass += 1; print("✅ \(c.name): \(detail)") }
            break
        }
    }
    cleanup()
    print("끝: 마우스 모드 " + forceMouseMode(false))
    CGWarpMouseCursorPosition(start)
    wait(0.5)
    rec.lock.lock(); rec.dropping = false; let ts = rec.ts; rec.lock.unlock()
    if let ts { print("시각 단위: event.timestamp=\(ts.0) mach=\(ts.1) uptime_ns=\(ts.2)") }
    rec.lock.lock()
    let seen = rec.seenDevices.map { String(format: "0x%llx", $0) }.sorted()
    rec.lock.unlock()
    print("시험 키의 키보드 표시(칸 87): \(seen.joined(separator: ", "))")
    print("통과 \(pass) · 실패 \(fail) · 건너뜀 \(skipped)")
    exit(fail == 0 && skipped == 0 ? 0 : 1)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 240) { print("시간 초과"); cleanup(); exit(3) }
CFRunLoopRun()
