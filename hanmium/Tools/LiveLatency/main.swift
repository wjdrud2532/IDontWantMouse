// 라벨 모드가 뜨는 시간을 실제 앱·사이트에서 잰다. Tools/live-latency.sh 로 돌린다.
// 대상마다 앞으로 가져와 ⌥Space 로 라벨 모드를 열고(Hanmium 로그로 열린 것을 확인한 뒤에만) Esc 로 닫기를 되풀이하고,
// 로그의 "대상 찾기·굴절 없이 먼저 그림·그리기 끝" 시간과 찾은 대상 수를 모은다. 끝나면 원래 앞 앱으로 돌아간다.
//   대상: app:<번들 ID>  (실행 중이 아니면 띄우고 끝나면 끈다)
//         site:<주소>     (프로필을 따로 쓰는 시험용 Chrome 에서 연다. 쓰고 있는 Chrome 은 건드리지 않는다)
//   --runs N (기본 4)
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Hanmium.log")
func lines() -> [Substring] { ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n") }
func wait(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }
let src = CGEventSource(stateID: .hidSystemState)
func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(12_000)
}
/// 지금 앞 앱. NSWorkspace.frontmostApplication 은 메인 런 루프가 돌지 않으면 바뀌지 않아서 손쉬운 사용으로 묻는다.
func front() -> NSRunningApplication? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &v) == .success,
          let v else { return NSWorkspace.shared.frontmostApplication }
    var pid: pid_t = 0
    AXUIElementGetPid(v as! AXUIElement, &pid)
    return NSRunningApplication(processIdentifier: pid)
}
func bringFront(_ app: NSRunningApplication) -> Bool {
    app.activate()
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    for _ in 0..<40 {
        if front()?.processIdentifier == app.processIdentifier { return true }
        wait(0.05)
    }
    return false
}

var runs = 4
var targets: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--runs", let n = args.first.flatMap(Int.init) { runs = n; args.removeFirst() } else { targets.append(a) }
}

// MARK: 시험용 Chrome (프로필 따로)
let chromeBinary = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
let profile = NSTemporaryDirectory() + "hanmium-latency-chrome"
var testChrome: NSRunningApplication?
func openSite(_ url: String) -> NSRunningApplication? {
    if testChrome == nil {
        try? FileManager.default.removeItem(atPath: profile)
        try? FileManager.default.createDirectory(atPath: profile + "/Default", withIntermediateDirectories: true)
        // Hanmium 이 페이지에 직접 물을 수 있게(ChromeJS) "Apple Events 의 JavaScript 허용"을 켜 둔 프로필
        try? #"{"browser":{"allow_javascript_apple_events":true,"has_seen_welcome_page":true}}"#
            .write(toFile: profile + "/Default/Preferences", atomically: true, encoding: .utf8)
        let before = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").map(\.processIdentifier))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: chromeBinary)
        p.arguments = ["--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check", "--window-size=1280,900",
                       "--window-position=120,60", url]
        try? p.run()
        for _ in 0..<100 {
            wait(0.1)
            if let new = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
                .first(where: { !before.contains($0.processIdentifier) }) { testChrome = new; break }
        }
    } else {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: chromeBinary)
        p.arguments = ["--user-data-dir=" + profile, url]
        try? p.run()
        p.waitUntilExit()
    }
    wait(4)   // 페이지가 다 뜨게
    return testChrome
}

// MARK: 재기
struct Row { var name: String; var count = "-"; var find: [Int] = []; var visible: [Int] = []; var done: [Int] = []; var note = "" }
func median(_ a: [Int]) -> Int { a.isEmpty ? -1 : a.sorted()[a.count / 2] }

let previous = front()
var rows: [Row] = []
var launched: [NSRunningApplication] = []
for t in targets {
    var app: NSRunningApplication?
    var name = t
    if t.hasPrefix("site:") {
        name = String(t.dropFirst(5))
        app = openSite(name)
    } else {
        let id = t.hasPrefix("app:") ? String(t.dropFirst(4)) : t
        app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        if app == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let config = NSWorkspace.OpenConfiguration()
            let sem = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: config) { a, _ in app = a; sem.signal() }
            _ = sem.wait(timeout: .now() + 10)
            if let app { launched.append(app) }
            wait(2.5)
        }
        name = app?.localizedName ?? id
    }
    var row = Row(name: name)
    guard let app, bringFront(app) else {
        row.note = "앞으로 가져오지 못함"
        rows.append(row)
        print("\(row.name): \(row.note)")
        continue
    }
    wait(0.8)
    for _ in 0..<runs {
        guard front()?.processIdentifier == app.processIdentifier || front()?.bundleIdentifier == "com.local.Hanmium"
        else { row.note = "앞 앱이 바뀜"; break }
        let before = lines().count
        key(58, true, [.maskAlternate]); key(49, true, [.maskAlternate]); key(49, false, [.maskAlternate]); key(58, false, [])
        var line: Substring?
        for _ in 0..<50 {
            wait(0.05)
            line = lines().dropFirst(before).last { $0.contains("라벨 모드 [") && $0.contains("그리기 끝") }
            if line != nil { break }
        }
        let opened = lines().dropFirst(before).contains { $0.contains("라벨 모드 [") }
        guard let line else {
            row.note = opened ? "그리기 끝 없음" : "라벨 모드가 열리지 않음"
            if opened { wait(0.3); key(53, true, []); key(53, false, []) }
            break
        }
        let text = String(line)
        func ms(_ pattern: String) -> Int? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
                  let r = Range(m.range(at: m.numberOfRanges - 1), in: text) else { return nil }
            return Int(text[r])
        }
        if let c = ms(#"대상 찾기\((\d+)개\)"#) { row.count = String(c) }
        if let f = ms(#"대상 찾기\(\d+개\) (\d+)ms"#) { row.find.append(f) }
        if let d = ms(#"그리기 끝\(그리기 \d+ms\) (\d+)ms"#) {
            row.done.append(d)
            row.visible.append(ms(#"굴절 없이 먼저 그림\(\d+ms\) (\d+)ms"#) ?? d)
        }
        wait(0.35)
        key(53, true, []); key(53, false, [])
        wait(0.6)
    }
    rows.append(row)
    print(String(format: "%-34@ 대상 %4@  찾기 %4dms  보임 %4dms(최대 %4d)  다 그림 %4dms(최대 %4d)  %@",
                 row.name.prefix(34) as NSString, row.count as NSString, median(row.find), median(row.visible),
                 row.visible.max() ?? -1, median(row.done), row.done.max() ?? -1, row.note as NSString))
}
if let testChrome { testChrome.terminate(); wait(1); if !testChrome.isTerminated { testChrome.forceTerminate() } }
for a in launched { a.terminate() }
if let previous { _ = bringFront(previous) }
let all = rows.flatMap(\.visible)
print("모두: 라벨 보임 중앙 \(median(all))ms, 최대 \(all.max() ?? -1)ms, 100ms 넘은 것 \(all.filter { $0 > 100 }.count)/\(all.count)")
