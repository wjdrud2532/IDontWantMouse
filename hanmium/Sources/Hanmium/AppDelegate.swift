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
    /// 띄우려고 찾는 중인 openToken. 그 결과가 오면(버리게 되더라도) 비운다. 찾는 중에 그만둬서 openToken 이 바뀌어도
    /// 그 결과가 비우므로 '찾는 중'에 갇히지 않는다.
    private var buildingToken: Int?
    private var building: Bool { buildingToken != nil }
    /// 스크롤 모드를 연 뒤로 이어지는 흐름. f 로 라벨을 띄웠다가 Esc 로 돌아오고, 라벨을 눌러 옮겨 가거나 앱·창·탭·데스크톱을
    /// 바꿔도 옮겨 간 곳에 스크롤 모드를 다시 연다. 스크롤 모드의 Esc·Enter, 마우스 클릭, 스크롤 단축키, 입력칸으로 가면 끝난다.
    private var scrollSession = false
    /// 다른 모드로 바꾸거나 다시 열려고 닫는 중. 이렇게 닫힌 것으로는 흐름을 끝내거나 이어 가지 않는다.
    private var replacing = false
    private var reopenWork: DispatchWorkItem?
    /// 띄우려고 찾는 중에 그만두면 늘려서, 늦게 도착한 결과를 버린다
    private var openToken = 0
    /// 지난 영역(ScrollCache)으로 먼저 띄운 스크롤 모드와 그 영역. 새로 찾은 결과가 오면 그대로 둘지 바꿀지 정한다.
    private var provisional: (mode: ScrollMode, snapshot: ScrollSnapshot)?
    /// 라벨 모드가 떠 있는 동안 뒤에서 미리 찾아 둔 스크롤 영역(라벨에서 j 로 바로 띄우려고).
    /// token 은 그 라벨 모드를 연 openToken, windowID 는 찾을 때 그 앱의 맨 앞 창.
    private var prewarmed: (token: Int, windowID: CGWindowID?, snapshot: ScrollSnapshot)?
    private let prewarmQueue = DispatchQueue(label: "Hanmium.prewarm", qos: .userInitiated)
    /// 미리 찾은 영역이 없을 때 j·k 로 넘어가는 동안, 스크롤 모드가 뜰 때까지 숨겨 두고 키 포커스를 쥐고 있는 라벨 모드
    private var handoff: ClickMode?
    /// 라벨에서 스크롤 모드로 넘어간 j·k. 스크롤 모드가 뜰 때 아직 누르고 있으면 이어서 스크롤한다.
    private var heldKey: NSEvent?
    /// 라벨을 누르거나 단축키를 넘기기 직전 앞 앱의 키 포커스. 그 뒤 '새' 입력칸으로 갔는지 볼 때 쓴다(typing).
    private var focusBefore: AXUIElement?
    /// 누른 것이 연 메뉴가 닫히기를 기다리는 동안 마우스 누름을 지켜보는 것 (waitForPopup)
    private var popupWait: Any?
    /// 흐름 중 다시 열었는데 스크롤 영역이 없어서(페이지를 그리는 중) 다시 찾아본 횟수
    private var emptyRetries = 0
    private var statusItem: StatusItem?
    private lazy var settings = SettingsWindowController(
        onHotkeysChanged: { [weak self] in self?.reloadHotkeys() },
        onRecording: { [weak self] recording in
            if recording { HotKeys.shared.unregisterAll() } else { self?.reloadHotkeys() }
        },
        onCheckApp: { [weak self] app in self?.check(app) })

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
        // 오버레이(패널·흐림 뷰)를 한 번 만들어 둔다. 앱을 켜고 처음 만들 때만 100ms 넘게 걸렸다(띄우지는 않는다).
        DispatchQueue.main.async {
            if let screen = NSScreen.main { Overlay(keyScreen: screen, stackedAbove: 1, fades: false).close() }
        }
        // 유리 라벨의 굴절은 뒤 화면을 찍어서 계산한다. 시스템은 처음 한 번만 묻는다.
        if GlassSnapshots.usesGlass, !GlassSnapshots.captureAllowed { CGRequestScreenCaptureAccess() }

        let status = StatusItem()
        status.onOpenSettings = { [weak self] in self?.settings.show() }
        statusItem = status
        // 키보드 규칙(Karabiner 형식): {"hanmium": …} 는 단축키처럼 모드를 연다
        KeyboardTap.shared.onHanmium = { [weak self] action in
            self?.toggle(action == "search" ? .search : action == "scroll" ? .scroll : .labels)
        }
        KeyboardStore.shared.load()
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

    /// 같은 모드 단축키를 다시 누르면 닫고, 다른 모드면 바꿔 띄운다. 단, 스크롤 모드에서 누른 라벨 단축키는 닫기다:
    /// 스크롤 모드에서 라벨은 f 로 띄우고, 라벨 단축키를 Tab 같은 키에 걸어 쓰면 그 키가 어느 모드에서나 '닫기'가 된다.
    /// 닫을 때는 스크롤 이어 쓰기도 끝낸다. f 로 띄운 라벨에서 눌러도 스크롤 모드로 돌아가지 않는다.
    func toggle(_ kind: ModeKind) {
        heldKey = nil
        // j·k 로 스크롤 모드를 여는 중: 스크롤 단축키면 그대로 기다리고, 다른 단축키면 둘 다 그만둔다(onExit)
        if handoff != nil {
            if kind != .scroll {
                scrollSession = false
                current?.stop()
            }
            return
        }
        if let mode = current {
            if currentKind == kind || kind == .labels && currentKind == .scroll {
                scrollSession = false
                mode.stop()
                return
            }
            replace(mode)
        } else if kind == .scroll && scrollSession {
            if popupWait == nil {
                // 흐름 중 다시 여는 사이에 누르면 끝낸다
                scrollSession = false
                openToken += 1
                return
            }
            // 메뉴가 닫히기를 기다리는 중(아무것도 떠 있지 않다): 지금 바로 연다
            reopenWork?.cancel()
            endPopupWait()
        }
        open(kind)
    }

    /// 이어 갈 모드를 띄우려고 지금 모드를 닫는다
    private func replace(_ mode: Mode?) {
        replacing = true
        mode?.stop()
        replacing = false
    }

    /// timed: 단축키로 열 때 여기서 시간 재기를 시작한다. 다시 열 때는 다시 열기를 부른 때부터 잰다(reopenScroll).
    /// ready: 라벨 모드에서 미리 찾아 둔 스크롤 영역. 찾기를 기다리지 않고 바로 띄우고, 새로 찾기는 뒤에서 한다.
    private func open(_ kind: ModeKind, timed: Bool = true, ready: ScrollSnapshot? = nil) {
        guard !building else { return }
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        if kind == .labels { Timing.begin("라벨 모드 [\(front.localizedName ?? "?")]") }
        if kind == .scroll && timed { Timing.begin("스크롤 모드 [\(front.localizedName ?? "?")]") }
        // 라벨을 찾는 동안 유리 라벨이 굴절시킬 화면을 찍어둔다 (오버레이가 뜨기 전).
        // 라벨에서 바로 넘어갈 때는 라벨이 아직 떠 있어서 찍지 않고, 라벨을 열 때 찍은 것을 그대로 쓴다.
        if kind != .search && ready == nil && handoff == nil { GlassSnapshots.retake() }
        openToken += 1
        provisional = nil
        prewarmed = nil
        let token = openToken
        buildingToken = token
        let builder = TreeBuilder.forFrontmost(front)
        let scrollBuilder = kind == .labels ? TreeBuilder.forFrontmost(front) : nil
        let pid = front.processIdentifier
        if let ready {
            Timing.mark("미리 찾은 영역으로 [\(ready.bundleID ?? "?")] (\(ready.areas.count)개)")
            buildingToken = nil
            presentScroll(ready, cached: true)
            if let mode = current as? ScrollMode { provisional = (mode, ready) }
        }
        axQueue.async {
            switch kind {
            case .scroll:
                if ready == nil, let cached = ScrollCache.reusable(for: pid) {
                    DispatchQueue.main.async {
                        guard token == self.openToken else { return }
                        Timing.mark("지난 영역으로 먼저 [\(cached.bundleID ?? "?")] (\(cached.areas.count)개)")
                        // 띄운 뒤로는 다른 모드를 열 수 있다(그러면 openToken 이 바뀌어 새로 찾은 결과는 버린다)
                        if self.buildingToken == token { self.buildingToken = nil }
                        self.presentScroll(cached, cached: true)
                        if let mode = self.current as? ScrollMode { self.provisional = (mode, cached) }
                    }
                }
                let snapshot = builder.scrollSnapshot()
                ScrollCache.store(snapshot)
                DispatchQueue.main.async {
                    if self.buildingToken == token { self.buildingToken = nil }
                    guard token == self.openToken else { return }
                    if let shown = self.provisional {
                        self.provisional = nil
                        // 그사이 닫았거나 다른 모드로 바꿨으면 그대로 둔다
                        guard self.current === shown.mode else { return }
                        if shown.snapshot.sameLayout(as: snapshot) {
                            shown.mode.adopt(snapshot)
                            return
                        }
                        Log.write("새로 찾은 스크롤 영역이 지난 것과 달라서 바꿈")
                        self.replace(shown.mode)
                    }
                    self.presentScroll(snapshot)
                }
            case .labels, .search:
                let snapshot = builder.clickSnapshot()
                DispatchQueue.main.async {
                    Timing.mark("대상 찾기(\(snapshot.elements.count)개)")
                    if self.buildingToken == token { self.buildingToken = nil }
                    guard token == self.openToken else { return }
                    self.presentClick(kind, snapshot)
                    ExtrasCache.refreshIfStale()
                    if let scrollBuilder, self.currentKind == .labels { self.prewarmScroll(scrollBuilder, token: token) }
                }
            }
        }
    }

    private func presentClick(_ kind: ModeKind, _ snapshot: Snapshot) {
        guard !snapshot.elements.isEmpty else {
            NSSound.beep()
            if scrollSession { reopenScroll(after: 0) }
            return
        }
        let screen = Screens.screen(for: snapshot.anchor)
        let mode = ClickMode(targets: snapshot.elements, kind: kind == .search ? .search : .labels, screen: screen)
        mode.onScroll = { [weak self, weak mode] event in
            guard let self, let mode else { return }
            Timing.begin("스크롤 모드 [\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")] (라벨에서 \(event.charactersIgnoringModifiers ?? "?"))")
            heldKey = event
            if let ready = readyScroll() {
                // 스크롤 창이 먼저 떠서 키 포커스를 넘겨받은 뒤 라벨 창을 닫는다
                open(.scroll, timed: false, ready: ready)
                replace(mode)
            } else {
                // 찾는 동안 라벨은 숨기고 키 포커스는 쥐고 있다가, 스크롤 모드가 뜨면 닫는다(presentScroll)
                mode.hideForHandoff()
                handoff = mode
                open(.scroll, timed: false)
                if !building { endHandoff() }  // 열지 못했다
            }
        }
        mode.onScrollNumber = { [weak self, weak mode] n in
            // 번호는 미리 찾은 영역이 있을 때만 그려지므로 그것으로 띄우고, 그 번호로 옮긴다
            guard let self, let mode, let ready = readyScroll() else { return NSSound.beep() }
            Timing.begin("스크롤 모드 [\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")] (라벨에서 \(n)번)")
            heldKey = nil
            open(.scroll, timed: false, ready: ready)
            (current as? ScrollMode)?.choose(number: n)
            replace(mode)
        }
        install(mode, kind)
    }

    /// 라벨이 뜬 뒤 뒤에서 스크롤 영역을 미리 찾아 둔다. 라벨에서 j 를 누를 때 찾으면 느리다: 라벨 창을 닫으면 키 포커스가
    /// 앱으로 돌아갔다가 곧 스크롤 창으로 다시 오는데, 그 사이 앱이 포커스를 받고 잃느라 바빠서 묻는 것마다 늦게 답한다
    /// (WezTerm 은 Claude Code 같은 프로그램이 다시 그려서 0.3~1.5초). 미리 찾아 두면 스크롤 창을 먼저 띄운 뒤
    /// 라벨 창을 닫아서 키 포커스가 앱으로 돌아가지도 않는다.
    private func prewarmScroll(_ builder: TreeBuilder, token: Int) {
        prewarmQueue.async {
            let snapshot = builder.scrollSnapshot()
            let windowID = snapshot.windows.indices.contains(snapshot.focusedWindow)
                ? AX.windowID(snapshot.windows[snapshot.focusedWindow].ref) : nil
            ScrollCache.store(snapshot)
            DispatchQueue.main.async {
                guard token == self.openToken, self.currentKind == .labels, !snapshot.areas.isEmpty else { return }
                self.prewarmed = (token, windowID, snapshot)
                // 스크롤 영역에 번호를 붙여 라벨에서 바로 고르게 한다(스크롤 모드의 숫자와 같은 번호)
                (self.current as? ClickMode)?.showScrollNumbers(
                    ScrollMode.numberSpots(windows: snapshot.windows, areas: snapshot.areas))
            }
        }
    }

    /// 숨겨 두고 기다리던 라벨 모드를 닫는다(스크롤 모드가 떴거나 열지 못했을 때)
    private func endHandoff() {
        guard let mode = handoff else { return }
        handoff = nil
        replace(mode)
    }

    /// 미리 찾아 둔 스크롤 영역을 지금 쓸 수 있는지: 떠 있는 라벨 모드에서 찾은 것이고, 그 앱의 맨 앞 창이 그대로다.
    /// 앱에 묻지 않고 창 서버 목록만 본다. 영역 요소가 바뀌었으면 뒤에서 새로 찾은 결과로 바꾼다(open).
    private func readyScroll() -> ScrollSnapshot? {
        guard let p = prewarmed, p.token == openToken, let id = p.windowID,
              WindowStack.current().entries.first(where: { $0.pid == p.snapshot.pid })?.id == id else { return nil }
        return p.snapshot
    }

    /// cached: 지난 영역(ScrollCache)으로 먼저 띄우는 것
    private func presentScroll(_ snapshot: ScrollSnapshot, cached: Bool = false) {
        guard !snapshot.areas.isEmpty else {
            endHandoff()
            // 흐름 중이면 옮겨 간 페이지를 아직 그리는 중일 수 있어서 조금 더 기다려 본다
            if scrollSession, emptyRetries < 3 {
                emptyRetries += 1
                reopenScroll(after: 0.3, retry: true)
                return
            }
            emptyRetries = 0
            NSSound.beep()
            scrollSession = false
            return
        }
        emptyRetries = 0
        if !cached { Timing.mark("영역 찾기 [\(snapshot.bundleID ?? "?")] (\(snapshot.areas.count)개)") }
        let anchor = snapshot.windows.indices.contains(snapshot.focusedWindow)
            ? snapshot.windows[snapshot.focusedWindow].frame : nil
        let mode = ScrollMode(snapshot: snapshot, screen: Screens.screen(for: anchor))
        mode.onLabels = { [weak self, weak mode] in
            guard let self else { return }
            replace(mode)
            open(.labels)
        }
        mode.onPassThrough = { [weak self] event in self?.passThrough(event) }
        mode.onHistory = { [weak self] back in self?.goHistory(back: back) }
        mode.onTab = { [weak self] previous in
            // 앞·뒤 탭: ⌘⇧[ ⌘⇧] (브라우저·VS Code·Finder·터미널 대부분이 받는다). 옮긴 탭에 스크롤 모드를 다시 연다.
            Log.write("\(previous ? "앞" : "뒤") 탭 [\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")]")
            self?.passThrough(key: previous ? 33 : 30, flags: [.maskCommand, .maskShift])
        }
        mode.onStale = { [weak self] in self?.reopenScroll(after: 0.05) }
        scrollSession = true
        install(mode, .scroll)
        endHandoff()
        // 라벨에서 j·k 를 누른 채 넘어왔으면 이어서 스크롤한다
        if let held = heldKey {
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(held.keyCode)) {
                mode.continuePress(held)
            } else {
                // 짧게 눌러 스크롤 모드가 뜨기 전에 뗐으면 스크롤 모드에서 한 번 누른 것처럼 조금만 옮긴다
                mode.tapPress(held)
                heldKey = nil
            }
        }
    }

    /// 스크롤 모드에서 누른 ⌘·⌃ 단축키(탭 바꾸기 등): 스크롤 모드를 닫아 키 포커스를 앱에 돌려준 뒤 같은 키를 보내고,
    /// 조금 뒤 그 자리에 스크롤 모드를 다시 연다. ⌘T·⌘L 처럼 입력칸으로 갔으면 글을 쓰려는 것이라 끝낸다.
    private func passThrough(_ event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue))
        passThrough(key: event.keyCode, flags: flags)
    }

    /// 스크롤 모드의 Shift+h·l: 앱의 뒤로·앞으로 단축키를 넘기고 바뀐 화면에 스크롤 모드를 다시 연다
    private func goHistory(back: Bool) {
        let app = NSWorkspace.shared.frontmostApplication
        guard let keys = HistoryKeys.keys(for: app?.bundleIdentifier) else {
            NSSound.beep()  // 터미널처럼 뒤로·앞으로가 없는 앱
            return
        }
        Log.write("\(back ? "뒤로" : "앞으로") [\(app?.bundleIdentifier ?? "?")]")
        let key = back ? keys.back : keys.forward
        passThrough(key: key.code, flags: key.flags, afterShiftUp: true)
    }

    /// afterShiftUp: 누른 Shift 를 뗀 뒤에 보낸다(Shift+h·l). 아직 누르고 있으면 앱이 ⌘[ 를 ⌘⇧[(앞 탭)처럼,
    /// ⌃- 를 ⌃⇧-(앞으로)처럼 받을 수 있다. 0.6초 넘게 누르고 있으면 그냥 보낸다.
    private func passThrough(key: UInt16, flags: CGEventFlags, afterShiftUp: Bool = false) {
        focusBefore = Self.focusedElement()
        replace(current)
        func post(_ waited: Int) {
            if afterShiftUp, waited < 30, CGEventSource.flagsState(.hidSystemState).contains(.maskShift) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { post(waited + 1) }
                return
            }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                e?.flags = flags
                e?.post(tap: .cghidEventTap)
            }
            // 탭을 바꾸는 단축키(⌃Tab)·뒤로 가기는 화면이 바뀌는 데 시간이 조금 걸린다
            reopenScroll(after: 0.15, unlessTyping: true)
        }
        // 스크롤 모드를 닫아 키 포커스가 앱으로 돌아간 뒤에 보낸다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { post(0) }
    }

    /// 흐름 중이면 delay 뒤 앞 앱에 스크롤 모드를 다시 연다. 여러 번 불리면 마지막 것만.
    /// retry: 안에서 다시 부른 것(찾는 중이라 미룸, 메뉴 기다림, 빈 결과)이라 시간 재기를 새로 시작하지 않는다.
    private func reopenScroll(after delay: Double, unlessTyping: Bool = false, retry: Bool = false) {
        reopenWork?.cancel()
        if !retry { Timing.begin("스크롤 모드 다시 열기") }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard scrollSession else { return endPopupWait() }
            if building {
                reopenScroll(after: 0.1, unlessTyping: unlessTyping, retry: true)
                return
            }
            if Self.popupOpen() {
                // 누른 것이 메뉴를 열었다. 스크롤 모드가 키 포커스를 가져가면 VS Code 처럼 웹으로 그린 메뉴는 창이 포커스를
                // 잃자마자 닫혀서 고를 수가 없다. 닫힐 때까지(항목을 고르거나 Esc) 기다렸다가 연다.
                // 고른 항목이 입력칸을 열었으면(새 파일 이름 등) 글을 쓰려는 것이라 끝낸다.
                replace(current)
                waitForPopup()
                reopenScroll(after: 0.25, unlessTyping: true, retry: true)
                return
            }
            endPopupWait()
            if frontmostBlocked || unlessTyping && Self.typing(except: focusBefore) {
                scrollSession = false
                replace(current)
                return
            }
            replace(current)
            Timing.mark("기다림·확인")
            open(.scroll, timed: false)
        }
        reopenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// 앞 앱의 키 포커스가 입력칸에 있는지. before 와 같은 요소면 아니라고 본다: VS Code 편집기처럼 원래 있던
    /// 입력칸으로 포커스가 돌아온 것은 새로 글을 쓰려는 것이 아니다.
    private static func typing(except before: AXUIElement? = nil) -> Bool {
        guard let focused = focusedElement(), let role = AX.string(AX.copy(focused, kAXRoleAttribute)),
              textInputRoles.contains(role) else { return false }
        return before.map { !CFEqual($0, focused) } ?? true
    }

    private static func focusedElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return AX.element(AX.copy(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute))
    }

    /// 웹으로 그린 메뉴(role="menu")도 AXMenu 다
    private static let popupRoles: Set<String> = ["AXMenu", "AXPopover"]

    /// 앞 앱에 메뉴가 열려 있는지: 앱 메뉴(컨텍스트 메뉴·메뉴 막대), 또는 키 포커스가 메뉴·팝오버 안에 있다
    private static func popupOpen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        if !TreeBuilder.openMenus(of: app).isEmpty { return true }
        var element = AX.element(AX.copy(app, kAXFocusedUIElementAttribute))
        for _ in 0..<5 {
            guard let e = element else { break }
            if let role = AX.string(AX.copy(e, kAXRoleAttribute)), popupRoles.contains(role) { return true }
            element = AX.element(AX.copy(e, kAXParentAttribute))
        }
        return false
    }

    /// 메뉴가 닫히기를 기다리는 동안에는 떠 있는 모드가 없어 addCancelWatchers 도 없다. 마우스로 누르면 흐름을 끝낸다.
    private func waitForPopup() {
        guard popupWait == nil else { return }
        Log.write("메뉴가 열려 있어 닫힐 때까지 스크롤 모드를 미룸")
        popupWait = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            self?.scrollSession = false
            self?.endPopupWait()
        }
    }

    private func endPopupWait() {
        if let popupWait { NSEvent.removeMonitor(popupWait) }
        popupWait = nil
    }

    /// 모드가 스스로 닫혔을 때(Esc, 누름 등). 흐름 중이면 이어 갈지 정한다.
    private func modeEnded(_ mode: Mode, _ kind: ModeKind) {
        guard scrollSession else { return }
        switch kind {
        case .scroll:
            // 스크롤 모드의 Esc·Enter
            scrollSession = false
        case .labels, .search:
            guard let clicked = (mode as? ClickMode)?.clicked else {
                reopenScroll(after: 0)  // Esc: 스크롤 모드로 돌아가기
                return
            }
            if Self.textInputRoles.contains(clicked.role) {
                scrollSession = false  // 입력칸을 눌렀다: 글을 쓰려는 것
            } else {
                // 누르기 직전(클릭은 이 뒤에 보낸다)
                focusBefore = Self.focusedElement()
                // 클릭은 0.04초 뒤에 간다. 메뉴는 그사이 열리고, 늦게 바뀌는 페이지·늦게 뜨는 새 창은
                // 다시 연 스크롤 모드가 알아차리고 새로 연다(ScrollMode.onStale).
                reopenScroll(after: 0.15)
            }
        }
    }

    private func install(_ mode: Mode, _ kind: ModeKind) {
        // 기다리던 다시 열기·메뉴 기다리기보다 지금 띄운 것이 먼저다
        reopenWork?.cancel()
        endPopupWait()
        mode.onExit = { [weak self, weak mode] in
            guard let self, let mode, self.current === mode else { return }
            if let handoff, handoff === mode {
                // 스크롤 모드가 뜨기 전에 그만뒀다(마우스 누름, 앱 바뀜, 단축키): 찾던 것은 버린다
                self.handoff = nil
                openToken += 1
            }
            self.current = nil
            self.currentKind = nil
            removeCancelWatchers()
            if !replacing { modeEnded(mode, kind) }
        }
        current = mode
        currentKind = kind
        mode.start()
        addCancelWatchers()
    }

    private var mouseWatcher: Any?
    private var appWatcher: NSObjectProtocol?
    private var spaceWatcher: NSObjectProtocol?

    /// 마우스를 누르면 떠 있는 모드를 닫는다. 다른 앱·데스크톱으로 넘어가면, 스크롤 흐름 중이면 그곳에 스크롤 모드를
    /// 다시 열고 아니면 닫는다. 테두리·라벨이 다른 곳에 남지 않게.
    /// (휠은 지켜보지 않는다: 커서를 옮기는 스크롤 방식에서 Hanmium 이 보낸 휠까지 걸리기 때문)
    private func addCancelWatchers() {
        removeCancelWatchers()
        mouseWatcher = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            self?.scrollSession = false
            self?.current?.stop()
        }
        let moved: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            // 앱이 바뀐 알림이 올 때는 창 순서·키 창이 이미 바뀌어 있다. 데스크톱을 옮기면 알림 두 개가 거의 같이 와서 하나로 모은다.
            if scrollSession { reopenScroll(after: 0.03) } else { current?.stop() }
        }
        let center = NSWorkspace.shared.notificationCenter
        appWatcher = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main,
                                        using: moved)
        spaceWatcher = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main,
                                          using: moved)
    }

    private func removeCancelWatchers() {
        if let mouseWatcher { NSEvent.removeMonitor(mouseWatcher) }
        for watcher in [appWatcher, spaceWatcher].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(watcher)
        }
        mouseWatcher = nil
        appWatcher = nil
        spaceWatcher = nil
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
