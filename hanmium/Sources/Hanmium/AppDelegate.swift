import AppKit
import ApplicationServices
import QuartzCore

protocol Mode: AnyObject {
    var onExit: (() -> Void)? { get set }
    func start()
    func stop()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let axQueue = DispatchQueue(label: "Hanmium.ax", qos: .userInteractive)
    private let launchMode: ModeKind?
    private var current: Mode?
    private var currentKind: ModeKind?
    private var building = false
    private var statusItem: StatusItem?
    private lazy var settings = SettingsWindowController(
        onHotkeysChanged: { [weak self] in self?.reloadHotkeys() },
        onRecording: { [weak self] recording in
            if recording { HotKeys.shared.unregisterAll() } else { self?.reloadHotkeys() }
        })

    private let openSettings: Bool

    init(launchMode: ModeKind?, openSettings: Bool) {
        self.launchMode = launchMode
        self.openSettings = openSettings
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        replaceOtherInstances()
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(prompt) {
            print("접근성 권한이 필요합니다: 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용")
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        // 처음 단축키를 누를 때 기다리지 않게 미리: GPU 셰이더 컴파일, 상태 아이콘이 있는 앱 목록
        DispatchQueue.global(qos: .utility).async { _ = GlassGPU.shared }
        ExtrasCache.refreshIfStale(force: true)
        // 유리 라벨의 굴절은 뒤 화면을 찍어서 계산한다. 시스템은 처음 한 번만 묻는다.
        if GlassSnapshots.usesGlass, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        let status = StatusItem()
        status.onToggleEnabled = { [weak self] in
            Config.enabled.toggle()
            self?.reloadHotkeys()
        }
        status.onOpenSettings = { [weak self] in self?.settings.show() }
        status.onToggleListed = { [weak self] bundleID in
            var apps = Config.appList
            if let i = apps.firstIndex(of: bundleID) { apps.remove(at: i) } else { apps.append(bundleID) }
            Config.appList = apps
            self?.reloadHotkeys()
        }
        status.onCheckApp = { [weak self] app in self?.check(app) }
        statusItem = status
        reloadHotkeys()
        if openSettings { settings.show() }
        watchTrustUntilGranted()

        // 앞 앱이 바뀌어 사용 여부가 달라지면 단축키를 놓거나 다시 잡는다
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, frontmostBlocked != blockedActive else { return }
            reloadHotkeys()
        }

        if let launchMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle(launchMode) }
        }
    }

    /// 메뉴 막대 › "앱 점검": 그 앱에서 Hanmium 이 찾아야 할 것을 찾는지 보고 결과를 창으로 보여준다(로그에도 남김)
    private func check(_ target: NSRunningApplication) {
        let click = TreeBuilder.forFrontmost(target), scroll = TreeBuilder.forFrontmost(target)
        axQueue.async {
            let report = Diagnostics.check(target, builder: click, scrollBuilder: scroll)
            DispatchQueue.main.async {
                Log.write("점검 " + report.text.replacingOccurrences(of: "\n", with: " / "))
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = report.hasWarnings ? "\(report.app): 확인이 필요한 부분이 있습니다" : "\(report.app): 문제없음"
                alert.informativeText = report.findings.map { "\($0.level.rawValue) \($0.text)" }.joined(separator: "\n")
                alert.addButton(withTitle: "닫기")
                alert.addButton(withTitle: "결과 복사")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                }
            }
        }
    }

    /// 권한이 없으면 2초마다 다시 확인해서, 시스템 설정에서 허용하는 즉시 메뉴 막대 아이콘에 반영한다.
    private func watchTrustUntilGranted() {
        guard !AXIsProcessTrusted() else { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            print("접근성 권한 허용됨")
            self?.statusItem?.refreshButton()
        }
    }

    /// 먼저 떠 있던 Hanmium(앱 번들이든 빌드한 실행 파일이든)은 끈다. 둘이 뜨면 메뉴 막대 아이콘도 둘이고
    /// 같은 단축키를 둘 다 잡아서 한 번 누르면 두 번 반응한다. 나중에 실행한 쪽이 최신이라고 보고 남긴다.
    private func replaceOtherInstances() {
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != getpid() && $0.executableURL?.lastPathComponent == "Hanmium"
        }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
    }

    /// 지금 앞에 있는 앱에서 Hanmium 을 쓰지 않도록 되어 있는지 (앱별 사용 설정)
    private var frontmostBlocked: Bool { !Config.isAllowed(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    /// 마지막으로 단축키를 잡을 때 그런 앱이 앞에 있었는지
    private var blockedActive = false

    /// 설정이 바뀌거나 쓰지 않는 앱을 오갈 때마다 단축키를 모두 놓고 다시 잡는다.
    private func reloadHotkeys() {
        HotKeys.shared.unregisterAll()
        blockedActive = frontmostBlocked
        statusItem?.hotkeys = ModeKind.allCases.map { kind in
            let spec = Config.hotkey(for: kind)
            guard let combo = KeyCombo(spec) else {
                print("단축키를 해석하지 못했습니다: \(spec)")
                return StatusItem.Hotkey(kind: kind, display: spec, state: .failed)
            }
            // 쓰지 않는 앱이 앞에 있으면 단축키를 잡지 않아서 키가 그 앱으로 간다
            guard Config.enabled, Config.isEnabled(kind), !blockedActive else {
                return StatusItem.Hotkey(kind: kind, display: combo.display, state: .off)
            }
            let ok = HotKeys.shared.register(combo) { [weak self] in self?.toggle(kind) }
            print(ok ? "\(kind): \(spec)" : "단축키 등록 실패 (다른 앱이 쓰는 중일 수 있음): \(spec)")
            return StatusItem.Hotkey(kind: kind, display: combo.display, state: ok ? .registered : .failed)
        }
        statusItem?.refreshButton()
    }

    /// 같은 모드 단축키를 다시 누르면 닫고, 다른 모드면 바꿔 띄운다.
    func toggle(_ kind: ModeKind) {
        if let mode = current {
            let same = currentKind == kind
            mode.stop()
            if same { return }
        }
        guard !building else { return }
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        if kind == .labels { Timing.begin("라벨 모드 [\(front.localizedName ?? "?")]") }
        // 라벨을 찾는 동안 유리 라벨이 굴절시킬 화면을 찍어둔다 (오버레이가 뜨기 전)
        if kind != .search { GlassSnapshots.retake() }
        building = true
        let builder = TreeBuilder.forFrontmost(front)
        axQueue.async {
            switch kind {
            case .scroll:
                let snapshot = builder.scrollSnapshot()
                DispatchQueue.main.async {
                    self.building = false
                    self.presentScroll(snapshot)
                }
            case .labels, .search:
                let snapshot = builder.clickSnapshot()
                DispatchQueue.main.async {
                    Timing.mark("대상 찾기(\(snapshot.elements.count)개)")
                    self.building = false
                    self.presentClick(kind, snapshot)
                    ExtrasCache.refreshIfStale()
                }
            }
        }
    }

    private func presentClick(_ kind: ModeKind, _ snapshot: Snapshot) {
        guard !snapshot.elements.isEmpty else {
            NSSound.beep()
            return
        }
        let screen = Screens.screen(for: snapshot.anchor)
        install(ClickMode(targets: snapshot.elements, kind: kind == .search ? .search : .labels, screen: screen), kind)
    }

    private func presentScroll(_ snapshot: ScrollSnapshot) {
        guard !snapshot.areas.isEmpty else {
            NSSound.beep()
            return
        }
        let anchor = snapshot.windows.indices.contains(snapshot.focusedWindow)
            ? snapshot.windows[snapshot.focusedWindow].frame : nil
        install(ScrollMode(snapshot: snapshot, screen: Screens.screen(for: anchor)), .scroll)
    }

    private func install(_ mode: Mode, _ kind: ModeKind) {
        mode.onExit = { [weak self, weak mode] in
            guard let self, self.current === mode else { return }
            self.current = nil
            self.currentKind = nil
            removeCancelWatchers()
        }
        current = mode
        currentKind = kind
        mode.start()
        addCancelWatchers()
    }

    private var mouseWatcher: Any?
    private var appWatcher: NSObjectProtocol?

    /// 마우스를 누르거나 다른 앱으로 넘어가면 떠 있는 모드를 닫는다. 테두리·라벨이 다른 곳에 남지 않게.
    /// (휠은 지켜보지 않는다: 커서를 옮기는 스크롤 방식에서 Hanmium 이 보낸 휠까지 걸리기 때문)
    private func addCancelWatchers() {
        removeCancelWatchers()
        mouseWatcher = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in self?.current?.stop()
        }
        appWatcher = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.current?.stop() }
    }

    private func removeCancelWatchers() {
        if let mouseWatcher { NSEvent.removeMonitor(mouseWatcher) }
        if let appWatcher { NSWorkspace.shared.notificationCenter.removeObserver(appWatcher) }
        mouseWatcher = nil
        appWatcher = nil
    }
}

/// --dump: 오버레이 없이 찾은 대상만 출력한다. 트리 탐색이 제대로 되는지 볼 때 쓴다.
enum Dump {
    static func run(bundleID: String?) {
        guard AXIsProcessTrusted() else {
            print("접근성 권한이 없습니다. 이 프로그램을 실행한 터미널 앱에 손쉬운 사용 권한을 주세요.")
            return
        }
        let running = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            ?? NSWorkspace.shared.frontmostApplication
        guard let running else {
            print("앱을 찾지 못했습니다.")
            return
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        let name = running.localizedName ?? running.bundleIdentifier ?? "?"

        let builder = TreeBuilder.forFrontmost(running)
        let t0 = CACurrentMediaTime()
        let click = builder.clickSnapshot()
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        let labels = LabelMaker.make(count: click.elements.count, alphabet: Config.labelAlphabet)
        print("[\(name)] 클릭 대상 \(click.elements.count)개 · AX 노드 \(builder.visited)개 · \(ms)ms")
        for (label, e) in zip(labels, click.elements) {
            let f = e.visibleFrame
            let role = e.role.padding(toLength: 16, withPad: " ", startingAt: 0)
            print("  \(label.uppercased())  \(role) (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))  \(e.summary)")
        }

        let scroll = TreeBuilder.forFrontmost(running).scrollSnapshot()
        print("[\(name)] 창 \(scroll.windows.count)개 · 스크롤 영역 \(scroll.areas.count)개")
        for (i, w) in scroll.windows.enumerated() {
            let f = w.frame
            let mark = i == scroll.focusedWindow ? " (포커스)" : ""
            print("  창 \(i + 1)\(mark)  (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))  \(w.title ?? "")")
            for (n, (area, window)) in scroll.areas.enumerated() where window == i {
                let a = area.visibleFrame
                let focus = n == scroll.focusedArea ? "  ← 포커스" : ""
                print("      \(area.role) (\(Int(a.minX)),\(Int(a.minY)) \(Int(a.width))x\(Int(a.height)))\(focus)")
            }
        }
    }
}

/// 단축키를 누른 때부터 단계별로 걸린 시간을 로그에 남긴다 (최적화할 때 실제 체감 시간을 보려고)
enum Timing {
    private static var title = ""
    private static var start: CFTimeInterval?
    private static var marks: [String] = []

    static func begin(_ name: String) {
        title = name
        start = CACurrentMediaTime()
        marks = []
    }

    static var running: Bool { start != nil }

    static func mark(_ name: String) {
        guard let start else { return }
        marks.append("\(name) \(Int((CACurrentMediaTime() - start) * 1000))ms")
    }

    static func finish(_ name: String) {
        guard start != nil else { return }
        mark(name)
        Log.write("\(title): " + marks.joined(separator: " · "))
        start = nil
    }
}
