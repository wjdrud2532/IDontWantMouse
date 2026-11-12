// 라벨·스크롤 모드를 실제 키로 시험한다. Tools/live-modes.sh 로 돌린다 (20초쯤).
// 이 프로그램이 스크롤 영역 두 개(#a 왼쪽, #b 오른쪽)가 있는 시험 창을 띄워 앞으로 가져오고, 단축키와 모드 키를 HID 단계로 보낸다.
// 결과는 Hanmium 로그, Hanmium 창 수, 시험 창 영역의 scrollTop, Hanmium 이 시험 창에 넘긴 단축키(⌘[ 등)로 확인한다.
// 키를 보내기 전마다 앞 앱이 시험 창(또는 Hanmium)인지 보고, 아니거나 사용자의 진짜 입력이 섞이면 바로 멈춘다.
// 끝나면 원래 앞에 있던 앱으로 돌아간다.
import AppKit
import ApplicationServices
import WebKit

setvbuf(stdout, nil, _IOLBF, 0)
let TEST: Int64 = 0x5445_5354
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let previousApp = NSWorkspace.shared.frontmostApplication
guard AXIsProcessTrusted() else { print("손쉬운 사용 권한이 없음 (터미널에 권한을 주고 터미널에서 실행)"); exit(2) }
guard let hanmium = NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.Hanmium").first
else { print("Hanmium 이 실행 중이 아님"); exit(2) }
let hanmiumPID = hanmium.processIdentifier
let myPID = getpid()

let html = """
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;height:100%;overflow:hidden;font:14px -apple-system}
#a,#b{position:absolute;top:0;bottom:0;overflow:auto}
#a{left:0;width:50%;background:#eef}#b{right:0;width:50%;background:#fee}
p{margin:0;padding:6px 12px;height:22px}
</style></head><body><div id="a"></div><div id="b"></div><script>
for (const id of ['a', 'b']) {
  const d = document.getElementById(id)
  for (let i = 0; i < 400; i++) {
    const p = document.createElement('p')
    p.innerHTML = i % 15 == 0 ? `<a href="#">${id} 링크 ${i}</a>` : `${id} 줄 ${i}`
    d.appendChild(p)
  }
}
</script></body></html>
"""

final class Loader: NSObject, WKNavigationDelegate {
    var loaded = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
}
let loader = Loader()
let screen = NSScreen.main!.visibleFrame
let win = NSWindow(contentRect: NSRect(x: screen.midX - 450, y: screen.midY - 320, width: 900, height: 640),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.title = "Hanmium 모드 시험"
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
web.navigationDelegate = loader
win.contentView = web
web.loadHTMLString(html, baseURL: nil)

// Hanmium 이 시험 창에 넘긴 단축키를 모은다(웹 보기에는 넘기지 않는다)
var received: [String] = []
let recvLock = NSLock()
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
    var m = ""
    if e.modifierFlags.contains(.control) { m += "⌃" }
    if e.modifierFlags.contains(.option) { m += "⌥" }
    if e.modifierFlags.contains(.shift) { m += "⇧" }
    if e.modifierFlags.contains(.command) { m += "⌘" }
    recvLock.lock(); received.append("\(m)\(e.keyCode)"); recvLock.unlock()
    return nil
}

// 사용자의 진짜 입력: 이 프로그램도 Hanmium 도 보내지 않은 키·클릭
var interference: [String] = []
let rawCB: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return Unmanaged.passUnretained(event) }
    let ud = event.getIntegerValueField(.eventSourceUserData)
    let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
    if ud != TEST && ud != 0x484E_4D4B && pid != myPID && pid != hanmiumPID {
        recvLock.lock(); interference.append("종류 \(type.rawValue) 키 \(event.getIntegerValueField(.keyboardEventKeycode))"); recvLock.unlock()
    }
    return Unmanaged.passUnretained(event)
}
let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
guard let rawTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: types.reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) },
                                     callback: rawCB, userInfo: nil)
else { print("입력 감시 탭을 만들 수 없음"); exit(2) }
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, rawTap, 0), .commonModes)

// MARK: 도구

func wait(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }
func onMain<T>(_ f: @escaping () -> T) -> T {
    var r: T!
    DispatchQueue.main.sync { r = f() }
    return r
}
struct Abort: Error { let why: String }
/// 키를 보내도 되는지: 앞 앱이 시험 창이나 Hanmium 이고 사용자 입력이 없었다
func safe() throws {
    let front = onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    guard front == myPID || front == hanmiumPID else { throw Abort(why: "앞 앱이 시험 창이 아님 (pid \(front ?? -1))") }
    recvLock.lock(); let i = interference; recvLock.unlock()
    if !i.isEmpty { throw Abort(why: "사용자 입력이 섞임 \(i.prefix(3))") }
}
let source = CGEventSource(stateID: .hidSystemState)
func post(_ code: UInt16, _ down: Bool, _ flags: CGEventFlags = [], rep: Bool = false, type: CGEventType? = nil) throws {
    try safe()
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
    if let type { e.type = type }
    e.flags = CGEventFlags(rawValue: flags.rawValue | 0x100)
    if rep { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    e.setIntegerValueField(.eventSourceUserData, value: TEST)
    e.post(tap: .cghidEventTap)
    wait(0.015)
}
func tap(_ code: UInt16, _ flags: CGEventFlags = []) throws { try post(code, true, flags); wait(0.03); try post(code, false, flags); wait(0.03) }
func mod(_ code: UInt16, _ flags: CGEventFlags) throws { try post(code, true, flags, type: .flagsChanged) }
let SHIFT = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x2)
let OPT = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
func optSpace() throws { try mod(58, OPT); try tap(49, OPT); try mod(58, []) }
func shifted(_ code: UInt16) throws { try mod(56, SHIFT); try tap(code, SHIFT); try mod(56, []) }
/// 실제 키보드처럼 누르고 있는 동안 반복 입력을 보낸다
func hold(_ code: UInt16, _ s: Double) throws {
    try post(code, true)
    var t = 0.0
    while t < s { wait(0.033); t += 0.033; if t > 0.3 { try post(code, true, rep: true) } }
    try post(code, false)
}

let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Hanmium.log")
func logCount(_ needle: String) -> Int {
    ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains(needle) }.count
}
func lastLog(_ needle: String) -> String {
    String(((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").last { $0.contains(needle) } ?? "")
}
/// 로그에 needle 이 든 줄이 늘 때까지 기다린다
func waitLog(_ needle: String, after count: Int, _ timeout: Double = 2.5) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if logCount(needle) > count { return true }; wait(0.05) }
    return false
}
/// 보이는 Hanmium 창(라벨·스크롤 테두리) 수. 메뉴 막대 아이콘은 뺀다.
func overlays() -> Int {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == hanmiumPID && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0.01
            && (($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0) > 200
    }.count
}
func waitOverlays(_ want: (Int) -> Bool, _ timeout: Double = 1.5) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if want(overlays()) { return true }; wait(0.05) }
    return false
}
func js(_ s: String) -> String {
    let sem = DispatchSemaphore(value: 0)
    var out = ""
    DispatchQueue.main.async {
        web.evaluateJavaScript(s) { v, _ in out = "\(v ?? "")"; sem.signal() }
    }
    _ = sem.wait(timeout: .now() + 2)
    return out
}
func tops() -> (a: Int, b: Int) {
    let p = js("a.scrollTop + ',' + b.scrollTop").split(separator: ",").compactMap { Int(Double($0) ?? -1) }
    return p.count == 2 ? (p[0], p[1]) : (-1, -1)
}
func resetTops() { _ = js("a.scrollTop = 0; b.scrollTop = 0; 1") }
func takeReceived() -> [String] { recvLock.lock(); defer { received = []; recvLock.unlock() }; return received }

var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
    if ok { pass += 1; print("✅ \(name): \(detail)") } else { fail += 1; print("❌ \(name): \(detail)") }
}
/// 모드가 열려 있으면 Esc 로 닫는다(앞 앱이 시험 창일 때만)
func closeAll() {
    for _ in 0..<3 where overlays() > 0 {
        try? tap(53)
        _ = waitOverlays({ $0 == 0 }, 0.8)
    }
}

// MARK: 시험

let J: UInt16 = 38, K: UInt16 = 40, H: UInt16 = 4, L: UInt16 = 37, F: UInt16 = 3, TAB: UInt16 = 48
let digit: [Int: UInt16] = [1: 18, 2: 19]
let labelLog = "라벨 모드 [", scrollLog = "스크롤 모드 열림 [", closeLog = "스크롤 모드 닫힘"

func run() throws {
    // 1. ⌥Space → 라벨
    var n = logCount(labelLog)
    try optSpace()
    check("⌥Space → 라벨 모드", waitLog(labelLog, after: n) && waitOverlays({ $0 > 0 }), lastLog(labelLog).components(separatedBy: "Z ").last ?? "")

    // 2. 라벨에서 j 를 누르고 있으면 스크롤 모드로 넘어가 계속 스크롤
    resetTops()
    n = logCount(scrollLog)
    try hold(J, 0.9)
    wait(0.3)
    var t = tops()
    check("라벨에서 j 꾹 → 스크롤 모드 + 계속 스크롤", waitLog(scrollLog, after: n) && t.a + t.b > 150,
          "scrollTop a \(t.a) b \(t.b)")

    // 3~6. 스크롤 모드 Shift+h l j k → 앱에 ⌘[ ⌘] ⌘⇧[ ⌘⇧] 를 넘기고 스크롤 모드를 다시 연다
    for (key, name, want) in [(H, "Shift+H → 뒤로 (⌘[)", "⌘33"), (L, "Shift+L → 앞으로 (⌘])", "⌘30"),
                              (J, "Shift+J → 앞 탭 (⌘⇧[)", "⇧⌘33"), (K, "Shift+K → 뒤 탭 (⌘⇧])", "⇧⌘30")] {
        _ = takeReceived()
        n = logCount(scrollLog)
        try shifted(key)
        let reopened = waitLog(scrollLog, after: n, 2.0)
        _ = waitOverlays({ $0 > 0 })
        let got = takeReceived()
        check("스크롤 모드 " + name, got == [want] && reopened, "시험 창이 받은 키 \(got), 다시 열림 \(reopened)")
    }

    // 7. 스크롤 모드 f → 라벨
    n = logCount(labelLog)
    try tap(F)
    check("스크롤 모드 f → 라벨", waitLog(labelLog, after: n), "")

    // 8~9. 라벨의 영역 번호 2 → 그 영역에서 스크롤 모드, 다시 열어 1 → 다른 영역
    var moved: [String] = []
    for (i, number) in [2, 1].enumerated() {
        if i > 0 {
            try optSpace()  // 스크롤 모드에서 라벨 단축키 → 모두 닫힘
            check("스크롤 모드에서 ⌥Space → 모두 닫힘", waitOverlays({ $0 == 0 }), "")
            n = logCount(labelLog)
            try optSpace()
            _ = waitLog(labelLog, after: n)
            wait(0.2)
        }
        resetTops()
        let c = logCount("라벨에서 \(number)번")
        try tap(digit[number]!)
        let chose = waitLog("라벨에서 \(number)번", after: c)
        wait(0.3)
        try hold(J, 0.5)
        wait(0.3)
        t = tops()
        let area = t.a > 50 && t.b == 0 ? "a" : t.b > 50 && t.a == 0 ? "b" : "?"
        moved.append(area)
        check("라벨에서 \(number) → 영역으로 스크롤 모드", chose && area != "?",
              "\(lastLog("라벨에서 \(number)번").components(separatedBy: "Z ").last ?? ""), 움직인 영역 \(area) (a \(t.a) b \(t.b))")
    }
    check("번호 1·2 가 서로 다른 영역", moved.count == 2 && moved[0] != moved[1] && !moved.contains("?"), "\(moved)")

    // 10. 키보드 규칙이 켜져 있으면 Tab(→ 라벨 단축키) 으로 스크롤 모드 닫기
    if UserDefaults(suiteName: "com.local.Hanmium")?.bool(forKey: "keyboardEnabled") == true {
        try tap(TAB)
        check("스크롤 모드에서 Tab → 모두 닫힘", waitOverlays({ $0 == 0 }), "")
    } else {
        print("⏭  Tab 시험 건너뜀 (키보드 규칙 꺼짐)")
        closeAll()
    }

    // 11. 라벨에서 k → 스크롤 모드, Esc → 닫힘
    n = logCount(labelLog)
    try optSpace()
    _ = waitLog(labelLog, after: n)
    _ = js("a.scrollTop = 2000; b.scrollTop = 2000; 1")
    wait(0.2)
    n = logCount(scrollLog)
    try tap(K)
    let opened = waitLog(scrollLog, after: n)
    wait(0.4)
    t = tops()
    check("라벨에서 k → 스크롤 모드 (위로)", opened && (t.a < 2000 || t.b < 2000), "a \(t.a) b \(t.b)")
    let c = logCount(closeLog)
    try tap(53)
    check("Esc → 닫힘", waitOverlays({ $0 == 0 }) && waitLog(closeLog, after: c), "")
}

DispatchQueue.global().async {
    // 창을 앞으로: 터미널에서 띄운 프로그램은 스스로 앞에 나서지 못할 수 있어 손쉬운 사용으로도 앞으로 둔다
    onMain {
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(myPID), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    let end = Date().addingTimeInterval(5)
    while Date() < end && !(onMain { loader.loaded && app.isActive && win.isKeyWindow }) { wait(0.1) }
    guard onMain({ loader.loaded && app.isActive }) else { print("시험 창을 앞으로 가져오지 못함"); exit(2) }
    wait(1.0)  // 웹 보기가 손쉬운 사용 트리를 만들 시간
    recvLock.lock(); interference = []; recvLock.unlock()
    var aborted: String?
    do { try run() } catch let e as Abort { aborted = e.why } catch { aborted = "\(error)" }
    if let aborted { print("🛑 멈춤: \(aborted)") }
    if onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier == myPID }) { closeAll() }
    print("통과 \(pass) · 실패 \(fail)" + (aborted == nil ? "" : " · 중간에 멈춤"))
    onMain { _ = previousApp?.activate() }
    wait(0.3)
    exit(fail == 0 && aborted == nil ? 0 : 1)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("시간 초과"); exit(3) }
app.run()
