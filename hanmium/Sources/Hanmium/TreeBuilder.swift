import AppKit
import ApplicationServices

struct Snapshot {
    var elements: [Element] = []
    /// 앞 창의 프레임. 오버레이 키 입력을 받을 화면을 고르는 데 쓴다.
    var anchor: CGRect?
}

struct ScrollSnapshot {
    let pid: pid_t
    let bundleID: String?
    var windows: [Element] = []
    /// 스크롤 영역과 그 영역이 속한 windows 인덱스
    var areas: [(area: Element, window: Int)] = []
    var focusedWindow = 0
    /// 키보드 포커스가 있는 곳(포커스 요소, WezTerm 은 활성 패널)의 프레임
    var focus: CGRect?
    /// 포커스가 있는 영역(areas 인덱스). 모드를 열 때 여기서 시작한다.
    var focusedArea: Int?
    /// 앱이 알려준 키 창 그대로 (없으면 nil). 스크롤 모드가 키 창이 바뀌었는지 볼 때 기준으로 쓴다.
    var keyWindow: AXUIElement?
}

/// 앞 앱의 AX 트리를 훑어 클릭 대상이나 스크롤 영역을 모은다. AX 호출이 느릴 수 있어 백그라운드에서 돈다.
final class TreeBuilder {
    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXComboBox", "AXTextField", "AXTextArea", "AXSlider", "AXIncrementor", "AXDisclosureTriangle",
        "AXMenuItem", "AXMenuBarItem", "AXDockItem", "AXColorWell", "AXRow",
    ]
    /// 역할만으로는 모르니 AXPress 액션이 있는지 물어보고 판단하는 역할
    static let probeRoles: Set<String> = ["AXImage", "AXCell", "AXGroup", "AXUnknown"]
    /// 하위를 더 볼 필요가 없는 역할
    static let leafRoles: Set<String> = [
        "AXStaticText", "AXImage", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
        "AXSlider", "AXPopUpButton", "AXMenuButton", "AXButton", "AXDisclosureTriangle", "AXIncrementor",
        "AXScrollBar", "AXSplitter", "AXValueIndicator", "AXDockItem", "AXComboBox", "AXColorWell",
        "AXLink", "AXMenuBarItem",
    ]
    /// 자식이 이 영역 밖으로 나가면 안 보이는 역할
    static let clippingRoles: Set<String> = ["AXWindow", "AXScrollArea", "AXSheet", "AXDrawer"]
    /// 값까지 검색할 가치가 있는 역할 (팝업 버튼의 현재 선택 등)
    static let valueRoles: Set<String> = ["AXPopUpButton", "AXComboBox", "AXTextField", "AXMenuButton"]
    static let alwaysExtrasApps: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver"]

    private let app: AXUIElement
    private let pid: pid_t
    private let bundleID: String?
    private let screenBounds: CGRect
    private let extraPids: [pid_t]
    private let dockPid: pid_t?
    /// WezTerm 패널 배치에 쓰는 화면 배율 (메인 스레드에서 읽은 것)
    private let screenScales: WezTerm.ScreenScales

    private var targets: [Element] = []
    /// 접근성 위치가 깨진 사이트의 웹 영역은 훑지 않는다(ChromeJS 로 대신 묻는다)
    private var skipWebArea = false
    private var seenFrames = Set<FrameKey>()
    private(set) var visited = 0
    private let maxVisited = 6000

    /// NSWorkspace / NSScreen 은 메인 스레드에서 읽어 넘긴다.
    static func forFrontmost(_ running: NSRunningApplication) -> TreeBuilder {
        let apps = RunningApps.current()
        return TreeBuilder(pid: running.processIdentifier, bundleID: running.bundleIdentifier,
                           screenBounds: Screens.axUnion, extraPids: apps.extraPids,
                           dockPid: apps.dockPid, screenScales: .current())
    }

    init(pid: pid_t, bundleID: String?, screenBounds: CGRect, extraPids: [pid_t], dockPid: pid_t?,
         screenScales: WezTerm.ScreenScales = .current()) {
        self.screenScales = screenScales
        self.pid = pid
        self.bundleID = bundleID
        self.app = AXUIElementCreateApplication(pid)
        self.screenBounds = screenBounds
        self.extraPids = extraPids
        self.dockPid = dockPid
    }

    // MARK: - 클릭 대상

    func clickSnapshot() -> Snapshot {
        let profile = Profile()
        defer { profile.report("클릭 대상") }
        let wez = bundleID == WezTerm.bundleID ? WezTerm.Prefetch() : nil
        AXEnabler.enable(app: app, pid: pid, bundleID: bundleID)
        profile.mark("AX 켜기")

        // 열린 메뉴 확인과 창 밖 대상(앱 메뉴 막대·상태 아이콘·Dock)은 창 훑기와 따로 물을 수 있어서 동시에 한다.
        // 차례로 하면 기다린 시간이 모두 더해졌다(창 40ms + 상태 아이콘 30ms + …). 상태 아이콘·Dock 은 다른 프로세스다.
        let side = SideTargets()
        let group = DispatchGroup()
        let lane = DispatchQueue.global(qos: .userInteractive)
        lane.async(group: group) { side.menus = Self.openMenus(of: self.app) }
        lane.async(group: group) {
            if let bar = AX.element(AX.copy(self.app, kAXMenuBarAttribute)) {
                side.menuBar = Self.fetchAll(AX.elements(AX.copy(bar, kAXChildrenAttribute)), clip: self.screenBounds)
            }
        }
        lane.async(group: group) { side.extras = Self.fetchAll(self.menubarExtras(), clip: self.screenBounds) }
        if let dockPid {
            lane.async(group: group) {
                let dock = AXUIElementCreateApplication(dockPid)
                let items = AX.elements(AX.copy(dock, kAXChildrenAttribute)).flatMap { AX.elements(AX.copy($0, kAXChildrenAttribute)) }
                side.dock = Self.fetchAll(items, clip: self.screenBounds)
            }
        }

        var snap = Snapshot()
        if let window = focusedWindow() {
            let place = AXEnabler.webPlace(in: window, app: app, bundleID: bundleID)
            profile.mark("웹 영역 찾기")
            // 접근성 위치가 깨진 사이트이거나(ChromeJS) 웹 영역이 아직 없으면 페이지를 훑지 않고 페이지에 묻기를 처음부터 함께 돌린다
            var web: (ref: AXUIElement?, frame: CGRect, host: String?)?
            var pageTargets: Result<[ChromeJS.Target], ChromeJS.Failure>?
            let pageQuery = DispatchGroup()
            if let place, place.frame.width > 50, place.frame.height > 50 {
                let frame = place.frame
                web = (place.web, frame, place.web.flatMap(AXEnabler.host(of:)))
                if place.web == nil || web?.host.map(AXEnabler.brokenHosts.contains) == true {
                    skipWebArea = true
                    pageQuery.enter()
                    DispatchQueue.global(qos: .userInteractive).async {
                        pageTargets = ChromeJS.targets(pid: self.pid, webArea: frame)
                        pageQuery.leave()
                    }
                }
            }
            defer { skipWebArea = false }
            let w = Element.fetch(window, clip: screenBounds)
            snap.anchor = w?.frame
            walk(window, clip: screenBounds, depth: 0, owner: nil)
            profile.mark("창 훑기")
            // 키 창 위에 떠 있는 같은 앱 창(Outlook 미리 알림 같은 패널)은 키 창이 아니라서 위에서 빠진다.
            // 뒤에서 앞 순서로, 가려진 대상은 빼고 그 창을 훑는다.
            for front in windowsAbove(window) {
                targets.removeAll { front.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                walk(front.ref, clip: screenBounds, depth: 0, owner: nil)
            }
            profile.mark("위에 뜬 창 훑기")
            // Chrome 이 페이지 요소 위치를 잘못 줘서(ChromeJS 설명) 페이지 링크를 하나도 못 찾았으면 페이지에 직접 묻는다
            if let web, let w, !targets.contains(where: { $0.role == "AXLink" }) {
                if skipWebArea {
                    pageQuery.wait()
                } else {
                    pageTargets = ChromeJS.targets(pid: pid, webArea: web.frame)
                }
                switch pageTargets ?? .failure(.failed("묻지 않음")) {
                case .success(let found):
                    let webFrame = web.frame
                    targets.removeAll { webFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                    targets += found.map { Element.region($0.rect, in: w, role: $0.role, title: $0.title) }
                    if !skipWebArea, let host = web.host, found.contains(where: { $0.role == "AXLink" }) {
                        AXEnabler.brokenHosts.insert(host)
                        Log.write("Chrome: \(host) 는 접근성 위치가 깨져 페이지에 직접 물음 → 대상 \(found.count)개 (다음부터 바로 묻는다)")
                    }
                case .failure(.disabled):
                    Log.write("Chrome: 페이지에 직접 물으려면 Chrome 의 '보기 › 개발자 정보 › Apple Events 의 JavaScript 허용'을 켜야 합니다")
                case .failure(.failed(let why)):
                    Log.write("Chrome: 페이지에 직접 묻지 못함: \(why.prefix(200))")
                }
                profile.mark("Chrome 페이지에 묻기")
            }
            // WezTerm 은 분할 패널을 AX 로 알려주지 않아서 wezterm cli 의 배치로 패널마다 라벨을 단다
            if bundleID == WezTerm.bundleID, let w {
                let cli = wez?.wait() ?? (panes: WezTerm.panes(), focused: nil)
                let tab = WezTerm.visibleTabs(for: [w], in: cli.panes, focused: .some(cli.focused), scales: screenScales)[0]
                targets += WezTerm.paneElements(for: w, tab: tab, scales: screenScales)
                profile.mark("WezTerm 패널")
            }
        }
group.wait()
        if let bundleID, AXEnabler.chromiumBrowsers.contains(bundleID),
           !targets.contains(where: { $0.role == "AXLink" }), let window = focusedWindow() {
            Log.write("Chrome: 페이지 링크를 하나도 찾지 못함 (대상 \(targets.count)개) " + AXEnabler.describeWeb(window))
        }
        profile.mark("메뉴 막대·상태 아이콘·Dock 기다림")
        // 메뉴가 열려 있으면 메뉴 항목만 대상으로 한다 (드물어서 창은 미리 훑어 두고 버린다)
        if !side.menus.isEmpty {
            targets = []
            seenFrames = []
            for menu in side.menus { walk(menu, clip: screenBounds, depth: 0, owner: nil) }
            return Snapshot(elements: targets, anchor: nil)
        }
        for e in side.menuBar + side.extras + side.dock where isTarget(e, insideTarget: true) { add(e) }
        Self.locateTextStarts(targets)
        profile.mark("여러 줄 링크")
        snap.elements = targets
        return snap
    }

    /// 창 훑기와 동시에 모으는 창 밖 대상. 각 칸은 한 갈래만 쓰고, 읽는 건 group.wait() 뒤다.
    private final class SideTargets {
        var menus: [AXUIElement] = []
        var menuBar: [Element] = []
        var extras: [Element] = []
        var dock: [Element] = []
    }

    /// 요소 여러 개의 속성을 몇 갈래로 나눠 동시에 묻는다. 하나씩 물으면 왕복 시간이 쌓인다
    /// (웹 화면 요소 100개: 차례로 11–20ms → 4갈래 5–6ms). 순서는 그대로 둔다.
    static func fetchAll(_ refs: [AXUIElement], clip: CGRect) -> [Element] {
        guard refs.count > 12 else { return refs.compactMap { Element.fetch($0, clip: clip) } }
        let lanes = 4
        var out = [Element?](repeating: nil, count: refs.count)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                var i = lane
                while i < refs.count {
                    buf[i] = Element.fetch(refs[i], clip: clip)
                    i += lanes
                }
            }
        }
        return out.compactMap { $0 }
    }

    /// 키 큰 링크마다 여러 줄로 접혔는지 보고 첫 글자 자리를 찾는다(Element.locateTextStart). 몇 갈래로 나눠 동시에.
    static func locateTextStarts(_ elements: [Element]) {
        let links = elements.filter { $0.role == "AXLink" && $0.frame.height >= 26 }
        guard !links.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: min(4, links.count)) { lane in
            var i = lane
            while i < links.count {
                links[i].locateTextStart()
                i += 4
            }
        }
    }

    private func walk(_ ref: AXUIElement, clip: CGRect, depth: Int, owner: Element?) {
        guard depth < 64, visited < maxVisited else { return }
        visited += 1
        guard let e = Element.fetch(ref, clip: clip) else { return }
        let role = e.role
        if role == "AXScrollBar" || role == "AXValueIndicator" { return }
        let hasFrame = e.frame.width > 0 && e.frame.height > 0
        if hasFrame && !e.frame.intersects(clip) { return }

        // 정적 텍스트는 대상이 아니지만, 감싸고 있는 대상(행·셀 등)의 검색어로 쓴다
        if role == "AXStaticText" {
            if let owner, owner.extraText.count < 3,
               let text = e.title ?? AX.string(AX.copy(ref, kAXValueAttribute)) {
                owner.extraText.append(text)
            }
            return
        }

        var nextOwner = owner
        if isTarget(e, insideTarget: owner != nil), add(e) { nextOwner = e }
        if Self.leafRoles.contains(role) { return }

        var childClip = clip
        if hasFrame && Self.clippingRoles.contains(role) { childClip = clip.intersection(e.frame) }

        if role == "AXWebArea", skipWebArea { return }
        if role == "AXWebArea", Config.useSearchPredicate, let found = searchWebArea(ref) {
            for w in Self.fetchAll(found, clip: childClip) where w.enabled && w.isVisible && !Self.isWebContainer(w) {
                add(w)
            }
            return
        }
        for child in children(ref, role: role) {
            walk(child, clip: childClip, depth: depth + 1, owner: nextOwner)
        }
    }

    private func isTarget(_ e: Element, insideTarget: Bool) -> Bool {
        guard e.enabled, e.isVisible else { return false }
        if Self.clickableRoles.contains(e.role) { return true }
        if !insideTarget, Self.probeRoles.contains(e.role) { return AX.actions(e.ref).contains("AXPress") }
        return false
    }

    /// 키보드 포커스 검색 키가 사이드바·목록 전체 같은 큰 컨테이너도 돌려주는데, 클릭 대상으로는 쓸모없다.
    private static func isWebContainer(_ e: Element) -> Bool {
        let containers: Set<String> = [
            "AXOutline", "AXToolbar", "AXList", "AXTable", "AXWebArea", "AXScrollArea", "AXTabGroup",
            "AXSplitGroup",
        ]
        if containers.contains(e.role) { return true }
        return e.role == "AXGroup" && e.visibleFrame.width * e.visibleFrame.height > 120_000
    }

    /// 거의 같은 자리에 이미 대상이 있으면(링크 안의 이미지 등) 버린다.
    @discardableResult
    private func add(_ e: Element) -> Bool {
        guard seenFrames.insert(FrameKey(e.visibleFrame)).inserted else { return false }
        if Self.valueRoles.contains(e.role), let value = AX.string(AX.copy(e.ref, kAXValueAttribute)) {
            e.extraText.append(String(value.prefix(200)))
        }
        targets.append(e)
        return true
    }

    private func children(_ ref: AXUIElement, role: String) -> [AXUIElement] {
        // 표·목록은 전체 행 대신 보이는 행만 받아야 수천 개를 훑지 않는다
        let visibleAttr: String? = switch role {
        case "AXTable", "AXOutline": kAXVisibleRowsAttribute
        case "AXList", "AXGrid": kAXVisibleChildrenAttribute
        default: nil
        }
        if let visibleAttr {
            let visible = AX.elements(AX.copy(ref, visibleAttr))
            if !visible.isEmpty { return visible }
        }
        return AX.elements(AX.copy(ref, kAXChildrenAttribute))
    }

    /// VoiceOver 가 쓰는 검색 API. 웹 페이지를 노드 하나하나 훑는 것보다 훨씬 빠르다.
    private func searchWebArea(_ web: AXUIElement) -> [AXUIElement]? {
        let query: [String: Any] = [
            "AXSearchKey": [
                "AXLinkSearchKey", "AXButtonSearchKey", "AXControlSearchKey", "AXTextFieldSearchKey",
                "AXCheckBoxSearchKey", "AXRadioGroupSearchKey", "AXKeyboardFocusableSearchKey",
            ],
            "AXResultsLimit": 2000,
            "AXDirection": "AXDirectionNext",
            "AXVisibleOnly": true,
            "AXImmediateDescendantsOnly": false,
        ]
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            web, "AXUIElementsForSearchPredicate" as CFString, query as CFDictionary, &out)
        guard err == .success else { return nil }
        let found = AX.elements(out)
        return found.isEmpty ? nil : found
    }

    /// 앱에 지금 열려 있는 메뉴들
    static func openMenus(of app: AXUIElement) -> [AXUIElement] {
        var menus: [AXUIElement] = []
        // 컨텍스트 메뉴는 앱 바로 아래 AXMenu 로 붙는다
        for child in AX.elements(AX.copy(app, kAXChildrenAttribute))
        where AX.string(AX.copy(child, kAXRoleAttribute)) == "AXMenu" {
            menus.append(child)
        }
        // 메뉴 막대에서 열린 메뉴
        if let bar = AX.element(AX.copy(app, kAXMenuBarAttribute)) {
            for item in AX.elements(AX.copy(bar, kAXChildrenAttribute))
            where AX.bool(AX.copy(item, kAXSelectedAttribute)) == true {
                menus += AX.elements(AX.copy(item, kAXChildrenAttribute))
            }
        }
        return menus
    }

    private func menubarExtras() -> [AXUIElement] {
        // 상태 아이콘이 있다고 알려진 앱 + 아직 물어보지 않은 앱(새로 실행된 앱)에만 묻는다
        let pids = ExtrasCache.candidates(among: extraPids)
        return Self.queryExtras(pids).items
    }

    /// 앱마다 메뉴 막대 상태 아이콘을 동시에 묻는다. 아이콘이 있던 앱도 돌려준다.
    static func queryExtras(_ pids: [pid_t]) -> (items: [AXUIElement], owners: Set<pid_t>) {
        let lock = NSLock()
        var items: [AXUIElement] = []
        var owners = Set<pid_t>()
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let a = AXUIElementCreateApplication(pids[i])
            AXUIElementSetMessagingTimeout(a, 0.15)
            guard let bar = AX.element(AX.copy(a, "AXExtrasMenuBar")) else { return }
            let kids = AX.elements(AX.copy(bar, kAXChildrenAttribute))
            lock.lock()
            items += kids
            if !kids.isEmpty { owners.insert(pids[i]) }
            lock.unlock()
        }
        ExtrasCache.learn(asked: pids, owners: owners)
        return (items, owners)
    }

    /// 화면에서 키 창보다 앞에 보이는 같은 앱 창들, 뒤에서 앞 순서. 떠 있는 패널(레이어 3 등)은 키 창이 아니어도
    /// 늘 일반 창 위에 있다. 메뉴·상태 아이콘 층(24~)은 따로 다루므로 뺀다.
    private func windowsAbove(_ focused: AXUIElement) -> [(ref: AXUIElement, frame: CGRect)] {
        guard let focusedID = AX.windowID(focused) else { return [] }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var above: [CGWindowID] = []
        var reachedFocused = false
        for w in info {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            if id == focusedID {
                reachedFocused = true
                break
            }
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let layer = w[kCGWindowLayer as String] as? Int, (0..<24).contains(layer),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            above.append(id)
        }
        guard reachedFocused, !above.isEmpty else { return [] }
        var byID: [CGWindowID: AXUIElement] = [:]
        for ref in AX.elements(AX.copy(app, kAXWindowsAttribute)) {
            if let id = AX.windowID(ref) { byID[id] = ref }
        }
        return above.reversed().compactMap { id in
            guard let ref = byID[id], let e = Element.fetch(ref, clip: screenBounds),
                  e.frame.width > 0, e.frame.height > 0 else { return nil }
            return (ref, e.frame)
        }
    }

    private func focusedWindow() -> AXUIElement? {
        AX.element(AX.copy(app, kAXFocusedWindowAttribute))
            ?? AX.element(AX.copy(app, kAXMainWindowAttribute))
            ?? AX.elements(AX.copy(app, kAXWindowsAttribute)).first
    }

    // MARK: - 스크롤 영역

    /// 앞 앱의 모든 창과 그 안의 스크롤 영역.
    func scrollSnapshot() -> ScrollSnapshot {
        let profile = Profile()
        defer { profile.report("스크롤 영역") }
        let wez = bundleID == WezTerm.bundleID ? WezTerm.Prefetch() : nil
        let justEnabled = AXEnabler.enable(app: app, pid: pid, bundleID: bundleID)
        profile.mark("AX 켜기")
        var snap = ScrollSnapshot(pid: pid, bundleID: bundleID)
        snap.keyWindow = AX.element(AX.copy(app, kAXFocusedWindowAttribute))
        let focused = snap.keyWindow ?? focusedWindow()
        if let focused { _ = AXEnabler.webPlace(in: focused, app: app, bundleID: bundleID) }
        var refs = AX.elements(AX.copy(app, kAXWindowsAttribute))
        if refs.isEmpty, let focused { refs = [focused] }

        for ref in refs where AX.bool(AX.copy(ref, kAXMinimizedAttribute)) != true {
            // Finder 바탕화면은 창 목록에 AXScrollArea 로 끼어 있다
            guard let w = Element.fetch(ref, clip: screenBounds), w.role == kAXWindowRole,
                  w.visibleFrame.width >= 100, w.visibleFrame.height >= 80 else { continue }
            snap.windows.append(w)
        }
        // 화면에서 왼쪽→오른쪽, 위→아래 순서로 번호를 붙인다
        snap.windows.sort { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        profile.mark("창 \(snap.windows.count)개")

        let cli = wez?.wait() ?? (panes: [], focused: nil)
        if wez != nil { profile.mark("WezTerm 패널") }
        let wezPanes = cli.panes
        let wezTabs = WezTerm.visibleTabs(for: snap.windows, in: wezPanes, focused: .some(cli.focused),
                                          scales: screenScales)
        for (i, w) in snap.windows.enumerated() {
            var areas = WezTerm.paneElements(for: w, tab: wezTabs[i], scales: screenScales)
            if areas.isEmpty { areas = scrollAreas(in: w.ref) }
            // Electron 앱은 AX 를 처음 켠 직후엔 웹 내용 트리가 비어 있다 (Claude 앱을 띄우고 처음 열면 창 전체 하나만 잡혔다).
            // 이 앱에서 처음 열 때만 잠깐씩 기다리며 다시 찾는다.
            var waited = 0
            while justEnabled, areas.isEmpty, waited < 5 {
                usleep(100_000)
                waited += 1
                areas = scrollAreas(in: w.ref)
            }
            // 스크롤 영역을 못 찾는 앱도 창 가운데에 휠 이벤트를 보내면 대개 스크롤된다
            if areas.isEmpty { areas = [w] }
            // 창 안의 영역 번호도 왼쪽→오른쪽, 위→아래
            areas.sort { ($0.visibleFrame.minX, $0.visibleFrame.minY) < ($1.visibleFrame.minX, $1.visibleFrame.minY) }
            snap.areas += areas.map { (area: $0, window: i) }
            profile.mark("창\(i + 1) 영역 \(areas.count)개")
        }
        if let focused, let i = snap.windows.firstIndex(where: { CFEqual($0.ref, focused) }) {
            snap.focusedWindow = i
        }
        findFocus(in: &snap, wezPanes: wezPanes)
        profile.mark("포커스")
        return snap
    }

    /// 포커스가 어느 영역에 있는지: WezTerm 은 활성 패널, 다른 앱은 포커스 요소를 품은(없으면 가장 가까운) 영역.
    /// 창 대부분을 덮는 요소(웹 페이지 전체 등)에 포커스가 있으면 알 수 없는 것으로 본다.
    private func findFocus(in snap: inout ScrollSnapshot, wezPanes: [WezTerm.Pane]) {
        guard snap.windows.indices.contains(snap.focusedWindow) else { return }
        let window = snap.windows[snap.focusedWindow].frame
        let mine = snap.areas.indices.filter { snap.areas[$0].window == snap.focusedWindow }
        let active = Set(wezPanes.filter(\.is_active).map(\.pane_id))
        if let i = mine.first(where: { snap.areas[$0].area.wezTermPane.map(active.contains) ?? false }) {
            snap.focusedArea = i
            snap.focus = snap.areas[i].area.visibleFrame
            return
        }
        guard let ref = AX.element(AX.copy(app, kAXFocusedUIElementAttribute)),
              let f = Element.fetch(ref, clip: screenBounds)?.visibleFrame, !f.isNull,
              f.width * f.height < window.width * window.height * 0.5 else { return }
        let c = CGPoint(x: f.midX, y: f.midY)
        guard window.contains(c) else { return }
        snap.focus = f
        func distance(_ r: CGRect) -> CGFloat {
            hypot(max(r.minX - c.x, 0, c.x - r.maxX), max(r.minY - c.y, 0, c.y - r.maxY))
        }
        // 품은 영역 중 가장 작은 것, 없으면 가장 가까운 것
        let frames = snap.areas.map(\.area.visibleFrame)
        let size = { (i: Int) in frames[i].width * frames[i].height }
        snap.focusedArea = mine.filter { frames[$0].contains(c) }.min { size($0) < size($1) }
            ?? mine.min { distance(frames[$0]) < distance(frames[$1]) }
    }

    private func scrollAreas(in window: AXUIElement) -> [Element] {
        var areas: [Element] = []
        var webFrames: [CGRect] = []
        // AXBrowser(Finder 컬럼 보기)는 열마다 스크롤 영역이 있어서 내려가 본다
        let stopRoles: Set<String> = ["AXWebArea", "AXTable", "AXOutline", "AXList", "AXTextArea"]

        func visit(_ ref: AXUIElement, clip: CGRect, depth: Int) {
            guard depth < 40, visited < maxVisited else { return }
            visited += 1
            // 훑는 동안은 역할·위치·크기만 묻고, 영역으로 쓸 것만 나머지 속성까지 받는다. Mail 처럼 제목·설명을
            // 만드는 데 시간이 드는 앱은 노드마다 속성 10개를 다 물으면 노드 56개에 70ms 가 걸렸다.
            let v = AX.multi(ref, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute])
            guard let role = AX.string(v[0]) else { return }
            var frame = CGRect.zero
            if let origin = AX.point(v[1]), let size = AX.size(v[2]) { frame = CGRect(origin: origin, size: size) }
            let visible = frame.intersection(clip)
            let hasFrame = frame.width > 0 && frame.height > 0
            if hasFrame && !frame.intersects(clip) { return }
            if Self.leafRoles.contains(role) { return }
            if role == "AXScrollArea", visible.width >= 40, visible.height >= 40, let e = Element.fetch(ref, clip: clip) {
                areas.append(e)
            }
            if role == "AXWebArea" {
                webFrames.append(visible)
                // 두 훑기는 서로 상관없어서 동시에 묻는다. 차례로 하면 두 시간이 더해졌다(Slack 35 + 27ms).
                var panes: [Element] = []
                let group = DispatchGroup()
                DispatchQueue.global(qos: .userInteractive).async(group: group) { panes = self.splitPanes(in: ref, clip: clip) }
                let scrollers = webScrollers(in: ref, clip: clip)
                group.wait()
                areas += panes + scrollers
                return
            }
            if stopRoles.contains(role) { return }
            let childClip = hasFrame && Self.clippingRoles.contains(role) ? clip.intersection(frame) : clip
            for child in children(ref, role: role) { visit(child, clip: childClip, depth: depth + 1) }
        }
        visit(window, clip: screenBounds, depth: 0)

        // 거의 같은 자리의 후보는 하나만
        var unique: [Element] = []
        for a in areas where !unique.contains(where: { $0.visibleFrame.isClose(to: a.visibleFrame, tolerance: 8) }) {
            unique.append(a)
        }

        // 다른 후보 안에 들어 있고 그 70% 넘게 덮는 후보는 뺀다 (패널과 그 안의 목록처럼 같은 곳이 두 번 잡히지 않게).
        // 휠은 가까운 스크롤 가능한 조상으로 가므로 바깥 것만 남겨도 같은 곳이 스크롤된다.
        let size = { (r: CGRect) in r.width * r.height }
        unique = unique.filter { inner in
            !unique.contains { outer in
                outer !== inner && outer.visibleFrame.insetBy(dx: -4, dy: -4).contains(inner.visibleFrame)
                    && size(inner.visibleFrame) >= size(outer.visibleFrame) * 0.7
                    && !outer.visibleFrame.isClose(to: inner.visibleFrame, tolerance: 8)
            }
        }
        // 브라우저는 페이지 전체가 가장 중요한 스크롤 영역이라 늘 남긴다
        if let bundleID, Self.browsers.contains(bundleID) { return unique }
        // 웹 앱 바깥 틀(Slack 의 창 전체처럼 스크롤 막대가 없는 AXScrollArea)은 안쪽 후보들이 대부분 덮으면 뺀다.
        // 안 그러면 스크롤되지 않는 틀이 가장 큰 영역이라 먼저 골라진다.
        return unique.filter { outer in
            guard outer.role == "AXScrollArea", AX.copy(outer.ref, kAXVerticalScrollBarAttribute) == nil,
                  webFrames.contains(where: { outer.visibleFrame.insetBy(dx: -4, dy: -4).contains($0) })
            else { return true }
            let inner = unique.filter { $0 !== outer && outer.visibleFrame.insetBy(dx: -4, dy: -4).contains($0.visibleFrame) }
            return Self.coverage(of: outer.visibleFrame, by: inner.map(\.visibleFrame)) < 0.6
        }
    }

    /// 웹 브라우저 (페이지 전체 스크롤을 늘 남긴다)
    static let browsers: Set<String> = AXEnabler.chromiumBrowsers.union([
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.operasoftware.Opera", "app.zen-browser.zen",
    ])

    /// DOM 클래스·id 하나가 스크롤 상자를 가리키는지: 'scroll' 이 들었거나(c-scrollbar__hider, [scrollbar-gutter:stable] 등)
    /// Tailwind 의 overflow-auto·overflow-y-auto 처럼 넘치면 스크롤하라는 클래스. 대괄호 밖에 ':' 가 있는 조건부 클래스
    /// (`hover:…`, `…:has-[[data-…-scrolls-with-chat]]:relative`)는 이 요소가 스크롤 상자라는 뜻이 아니고(Claude 앱
    /// 입력창이 이것 때문에 잡혔다), scroll-mt-4·scroll-pt-1 같은 scroll-margin·padding 은 스크롤될 대상에 붙으므로 치지 않는다.
    static func marksScroller(_ name: String) -> Bool {
        var depth = 0
        for c in name {
            switch c {
            case "[": depth += 1
            case "]": depth -= 1
            case ":" where depth == 0: return false
            default: break
            }
        }
        if ["overflow-auto", "overflow-y-auto", "overflow-scroll", "overflow-y-scroll"].contains(name) { return true }
        guard name.range(of: "scroll", options: .caseInsensitive) != nil else { return false }
        if name.range(of: #"^-?scroll-[mp][trblxyse]?-"#, options: .regularExpression) != nil { return false }
        // 스크롤 상자가 아니라 상태·동작을 뜻하는 이름: 스크롤된 머리글(is-scrolled), 스크롤 잠금(no-scroll), 스크롤 따라가기
        // (scrollspy), 부드러운 스크롤, 맨 위·아래로 단추, 스크롤 표시. 시험 페이지 Tools/ScrollFixtures/pages/names.html
        return name.range(of: #"no-?scroll|scroll-?lock|lock-?scroll|scrolled|scroll-?spy|smooth-?scroll|scroll-?smooth|"#
                          + #"scroll-?behavio|scroll-?to-?(top|bottom)|scroll-?top|scroll-?(margin|padding)|scroll-?snap-?(align|stop)|"#
                          + #"scroll-?(indicator|hint|progress|down|button|arrow)"#,
                          options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// DOM 클래스·id 들이 세로 스크롤 상자를 가리키는지. 스크롤 이름(marksScroller)이 있어도 가로로만 스크롤되는 것을 뜻하는
    /// 이름(가로 탭 줄·캐러셀·표 감싸개·overflow-x-auto)이 있고 세로를 콕 집은 이름이 없으면 아니다.
    /// 시험 페이지 Tools/ScrollFixtures/pages/horizontal.html
    static func marksVerticalScroller(_ names: [String]) -> Bool {
        guard names.contains(where: marksScroller) else { return false }
        func has(_ pattern: String) -> Bool {
            names.contains { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        let horizontal = has(#"overflow-x-(auto|scroll)|scroll-?x\b|x-?scroll|h-?scroll\b|horizontal|snap-x|carousel|"#
                             + #"scroll.*\b(tabs|tab-?bar|tab-?list|table)\b|\b(tabs|tab-?bar|tab-?list|table)\b.*scroll"#)
        let vertical = has(#"overflow-y-(auto|scroll)|^overflow-(auto|scroll)$|scroll-?y\b|y-?scroll|vertical"#)
        return !horizontal || vertical
    }

    /// 내용 크기대로 늘어나는 블록이면 그 안의 줄들: 코드 블록(자신이나 바로 아래 자식이 <code>, AXCodeStyleGroup)은
    /// 코드 줄, 표를 감싼 블록은 표의 줄. 이런 블록은 긴 줄 때문에 가로로 넘쳐 scroll 이름을 달아도 세로로는 스크롤되지 않는다.
    private static func contentLines(_ ref: AXUIElement, children: [AXUIElement]) -> [AXUIElement]? {
        if AX.string(AX.copy(ref, kAXSubroleAttribute)) == "AXCodeStyleGroup" { return children }
        guard children.count <= 3 else { return nil }
        for child in children {
            let v = AX.multi(child, [kAXRoleAttribute, kAXSubroleAttribute])
            if AX.string(v[1]) == "AXCodeStyleGroup" { return AX.elements(AX.copy(child, kAXChildrenAttribute)) }
            if AX.string(v[0]) == "AXTable" { return AX.elements(AX.copy(child, kAXRowsAttribute)) }
        }
        return nil
    }

    /// 안쪽 항목(표·트리는 줄)이 영역 밖(위·아래)까지 이어지는지: 그래야 스크롤되는 영역이다. 앞뒤 몇 개만 본다.
    private static func overflows(_ children: [AXUIElement], frame: CGRect) -> Bool {
        let sample = children.count <= 8 ? children : Array(children.prefix(4) + children.suffix(4))
        for child in sample {
            let v = AX.multi(child, [kAXPositionAttribute, kAXSizeAttribute])
            // 가운데가 밖이어야 넘친 것 (머리글처럼 몇 px 삐져나온 것은 아니다)
            guard let o = AX.point(v[0]), let s = AX.size(v[1]), s.height >= 8 else { continue }
            if o.y + s.height / 2 < frame.minY || o.y + s.height / 2 > frame.maxY { return true }
        }
        return false
    }

    /// rect 가 rects 로 덮인 비율(격자 표본으로 어림)
    private static func coverage(of rect: CGRect, by rects: [CGRect]) -> CGFloat {
        guard !rects.isEmpty, rect.width > 0, rect.height > 0 else { return 0 }
        let n = 20
        var hit = 0
        for gy in 0..<n {
            for gx in 0..<n {
                let p = CGPoint(x: rect.minX + rect.width * (CGFloat(gx) + 0.5) / CGFloat(n),
                                y: rect.minY + rect.height * (CGFloat(gy) + 0.5) / CGFloat(n))
                if rects.contains(where: { $0.contains(p) }) { hit += 1 }
            }
        }
        return CGFloat(hit) / CGFloat(n * n)
    }

    /// 웹 영역(Chromium·Electron·Safari) 안의 스크롤 영역. 웹은 AX 에 스크롤 여부를 알려주지 않아서 앱마다
    /// 규칙을 두지 않고 공통 단서로 찾는다: 스크롤 막대가 있거나, 목록·표 역할이거나, DOM 클래스·id 가 스크롤 상자를
    /// 가리키는 것(marksScroller).
    /// 휠은 그 자리에서 가장 가까운 스크롤 가능한 조상으로 가므로 단서가 조금 빗나가도 알맞은 곳이 스크롤된다.
    private func webScrollers(in web: AXUIElement, clip: CGRect) -> [Element] {
        let listRoles: Set<String> = ["AXList", "AXOutline", "AXTable", "AXGrid"]
        let skipRoles = Self.leafRoles.union(["AXRow", "AXCell", "AXWebArea"])
        var found: [Element] = []
        var budget = 3000

        var page = CGRect.null

        // bounds: 웹 영역 바로 아래부터 조상들의 틀이 겹친 곳. 목록이 여기를 벗어나면 어느 조상 안에서 스크롤된다.
        func visit(_ ref: AXUIElement, depth: Int, bounds: CGRect?) {
            guard depth < 60, budget > 0 else { return }
            budget -= 1
            let v = AX.multi(ref, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, "AXDOMClassList",
                                   "AXDOMIdentifier", kAXVerticalScrollBarAttribute, kAXChildrenAttribute])
            let role = AX.string(v[0]) ?? ""
            // 작은 요소 안에는 쓸 만한 스크롤 영역이 없다고 보고 내려가지 않는다
            guard let origin = AX.point(v[1]), let size = AX.size(v[2]) else {
                for child in AX.elements(v[6]) { visit(child, depth: depth + 1, bounds: bounds) }
                return
            }
            let whole = CGRect(origin: origin, size: size)
            let frame = whole.intersection(clip)
            guard !frame.isNull, frame.width >= 140, frame.height >= 100 else { return }
            if depth == 0 { page = whole }
            if depth > 0 {
                let names = ((v[3] as? [String]) ?? []) + [AX.string(v[4]) ?? ""]
                var scrolly = Self.marksVerticalScroller(names)
                // 이름도 스크롤 막대도 없는 목록·표는 내용이 실제로 넘칠 때만 (다 보이는 표는 스크롤되지 않는다):
                // 줄이 목록 밖으로 나가거나(목록 자체가 스크롤) 목록이 조상 틀 밖으로 나갈 때(감싼 상자가 스크롤).
                // 이름에 scroll 이 든 것은 그대로 둔다: 보이는 줄만 그리는 가상 목록(Slack)은 줄이 넘치지 않는다.
                func overflowing() -> Bool {
                    if let bounds, whole.minY < bounds.minY - 8 || whole.maxY > bounds.maxY + 8 { return true }
                    let items = role == "AXList" ? AX.elements(v[6]) : AX.elements(AX.copy(ref, kAXRowsAttribute))
                    // Chrome 은 화면(웹 영역) 끝에 걸린 표의 틀을 화면 끝에서 잘라 알려주면서 줄은 자르지 않는다.
                    // 그쪽으로 넘친 줄은 페이지가 스크롤할 몫이라 치지 않는다 (GitHub 문서의 긴 표가 영역으로 잡혔다).
                    let top = whole.minY <= page.minY + 2 ? -1e9 : whole.minY
                    let bottom = whole.maxY >= page.maxY - 2 ? 1e9 : whole.maxY
                    return Self.overflows(items, frame: CGRect(x: whole.minX, y: top, width: whole.width, height: bottom - top))
                }
                // 코드 블록·표 감싸개는 긴 줄이 가로로 넘쳐서 thin-scrollbar 같은 이름을 달지만 세로로는 스크롤되지 않는다.
                // 줄이 블록 밖으로 세로로 넘칠 때만 영역으로 친다(max.modular.com 문서의 코드 블록이 영역으로 잡혀 유리판이 덮였다).
                // 시험 페이지 Tools/ScrollFixtures/pages/code-blocks.html
                if scrolly, v[5] == nil, let lines = Self.contentLines(ref, children: AX.elements(v[6])) {
                    let top = whole.minY <= page.minY + 2 ? -1e9 : whole.minY
                    let bottom = whole.maxY >= page.maxY - 2 ? 1e9 : whole.maxY
                    scrolly = Self.overflows(lines, frame: CGRect(x: whole.minX, y: top, width: whole.width, height: bottom - top))
                }
                if scrolly || v[5] != nil || listRoles.contains(role) && overflowing(),
                   let e = Element.fetch(ref, clip: clip) {
                    found.append(e)
                }
                if skipRoles.contains(role) { return }
            }
            // 페이지 전체 크기의 틀(body 등)은 페이지가 스크롤하므로 경계로 치지 않는다
            let inner = depth == 0 || whole.isClose(to: page, tolerance: 8) ? bounds : (bounds?.intersection(whole) ?? whole)
            for child in AX.elements(v[6]) { visit(child, depth: depth + 1, bounds: inner) }
        }
        visit(web, depth: 0, bounds: nil)
        return found
    }

    /// VS Code 같은 Electron 앱은 스크롤 영역이 AX 에 드러나지 않는다. 대신 화면 분할 단위인
    /// DOM 클래스 split-view-view 중 다른 분할을 품지 않은 가장 안쪽 것들을 패널로 쓴다.
    private func splitPanes(in web: AXUIElement, clip: CGRect) -> [Element] {
        let pruneClasses: Set<String> = [
            "monaco-editor", "monaco-list", "monaco-tree", "monaco-scrollable-element", "xterm",
        ]
        let skipRoles = Self.leafRoles.union(["AXRow", "AXCell", "AXList", "AXTable", "AXOutline", "AXWebArea"])
        var views: [Element] = []
        var budget = 2000
        var seen = 0

        func visit(_ ref: AXUIElement, depth: Int) {
            guard depth < 40, budget > 0 else { return }
            budget -= 1
            seen += 1
            // 앞쪽 300 개 노드 안에 분할 뷰가 없으면 VS Code 계열이 아니라고 보고 그만둔다
            if views.isEmpty && seen > 300 {
                budget = 0
                return
            }
            let v = AX.multi(ref, [kAXRoleAttribute, "AXDOMClassList", kAXChildrenAttribute])
            let role = AX.string(v[0]) ?? ""
            let classes = (v[1] as? [String]) ?? []
            if classes.contains("split-view-view"), let e = Element.fetch(ref, clip: clip),
               e.visibleFrame.width >= 100, e.visibleFrame.height >= 100 {
                views.append(e)
            }
            // 안에 들어 있는 웹뷰(확장 패널 등)나 목록·에디터 내용까지 내려갈 필요는 없다
            if depth > 0 && skipRoles.contains(role) { return }
            if classes.contains(where: pruneClasses.contains) { return }
            for child in AX.elements(v[2]) { visit(child, depth: depth + 1) }
        }
        visit(web, depth: 0)

        var panes: [Element] = []
        for outer in views {
            let hasInner = views.contains { inner in
                inner !== outer && outer.visibleFrame.contains(inner.visibleFrame)
                    && !inner.visibleFrame.isClose(to: outer.visibleFrame)
            }
            if !hasInner && !panes.contains(where: { $0.visibleFrame.isClose(to: outer.visibleFrame) }) {
                panes.append(outer)
            }
        }
        return panes
    }
}

private struct FrameKey: Hashable {
    let x, y, w, h: Int
    init(_ r: CGRect) {
        x = Int((r.minX / 4).rounded())
        y = Int((r.minY / 4).rounded())
        w = Int((r.width / 4).rounded())
        h = Int((r.height / 4).rounded())
    }
}

/// Chromium·Electron 앱은 보조 기술이 켜졌다고 알려야 AX 트리를 만든다.
enum AXEnabler {
    private static var enabled = Set<pid_t>()
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary", "com.vivaldi.Vivaldi",
    ]

    /// TreeBuilder 의 직렬 큐에서만 부른다. 이번에 처음 켰으면 true.
    @discardableResult
    static func enable(app: AXUIElement, pid: pid_t, bundleID: String?) -> Bool {
        let first = enabled.insert(pid).inserted
        if let bundleID, chromiumBrowsers.contains(bundleID) {
            // 막 켠 Chrome 은 처음 켜 달라는 것을 무시하고, 다시 켜면(재시작) 꺼져 있다. 매번 보고 꺼져 있으면 다시 켠다.
            if AX.bool(AX.copy(app, "AXEnhancedUserInterface")) != true { turnOn(app) }
            return first
        }
        guard first else { return false }
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // AXEnhancedUserInterface 는 창 관리자 애니메이션을 느리게 하므로 꼭 필요할 때만 켠다
        if manual != .success, let bundleID, chromiumBrowsers.contains(bundleID) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        return true
    }

    /// Chrome 이 버린 웹 페이지 트리를 다시 만들 때까지 잠깐 기다린다. 다시 켜 달라고 한 직후에는 웹 영역이 아직 없다
    /// (처음 물으면 탭·툴바만 나오고 0.1~0.5초 뒤에 페이지가 생긴다). 웹 영역이 있으면 바로 돌아온다.
    /// 브라우저가 앞으로 왔을 때(라벨을 열기 전): 접근성을 켜 두고, 위치가 깨진 사이트면 Chrome 과 Apple Event 연결도 미리 맺는다.
    /// TreeBuilder 의 직렬 큐에서 부른다.
    static func warmUp(pid: pid_t, bundleID: String) {
        let app = AXUIElementCreateApplication(pid)
        enable(app: app, pid: pid, bundleID: bundleID)
        guard let window = AX.element(AX.copy(app, kAXFocusedWindowAttribute)),
              let place = webPlace(in: window, app: app, bundleID: bundleID),
              place.web == nil || place.web.flatMap(host(of:)).map(brokenHosts.contains) == true else { return }
        _ = ChromeJS.run(pid: pid, javascript: "0")
    }

    /// Chrome 접근성 켜기. Chrome 157 은 AXManualAccessibility 를 지원하지 않아 AXEnhancedUserInterface 로 켠다.
    static func turnOn(_ app: AXUIElement) {
        if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Chrome 은 한동안 접근성 요청이 없으면 웹 페이지 트리를 버린다(Chrome 157, 2026-11-12: 라벨이 탭·툴바에만 떴다).
    /// 웹 영역이 없으면 다시 켜 달라고 하고 생길 때까지 기다린다(보통 0.1~0.5초). 있으면 바로 돌아온다(위치가 깨진 페이지도
    /// 기다리지 않는다: 기다려도 오지 않고, 뒤에서 페이지에 직접 묻는다 — ChromeJS).
    /// 페이지가 놓인 자리. 웹 영역이 있으면 그것, 없으면(Chrome 이 버렸거나 막 켜서 아직 — 다시 만드는 데 0.1~3초) 다시 켜 달라고
    /// 하고 페이지를 담는 틀(ContentsContainerView, 웹 영역과 같은 자리)을 돌려준다. 기다리지 않는다: 페이지 대상은 그 틀 위치로
    /// 페이지에 직접 묻는다(ChromeJS).
    static func webPlace(in window: AXUIElement, app: AXUIElement, bundleID: String?) -> (web: AXUIElement?, frame: CGRect)? {
        guard let bundleID, chromiumBrowsers.contains(bundleID) else { return nil }
        // Chrome 은 늘 페이지 틀(ContentsContainerView) › 스크롤 영역 › 웹 영역이라 틀부터 찾고 두 단계만 내려간다(2~5ms)
        if let box = findContentsContainer(window), let frame = AX.frame(box) {
            if let web = webArea(under: box) { return (web, AX.frame(web) ?? frame) }
            turnOn(app)
            Log.write("Chrome: 웹 페이지 접근성 트리가 없어 다시 켜고, 페이지에 직접 물음")
            return (nil, frame)
        }
        // 틀이 없는 크로미엄 계열(구조가 다른 브라우저)
        if let web = findWebArea(window, app: app), let frame = AX.frame(web) { return (web, frame) }
        turnOn(app)
        return nil
    }

    /// 틀 아래 두 단계 안의 내용이 든 웹 영역
    private static func webArea(under box: AXUIElement) -> AXUIElement? {
        var level = AX.elements(AX.copy(box, kAXChildrenAttribute))
        for _ in 0..<3 {
            var next: [AXUIElement] = []
            for ref in level {
                let v = AX.multi(ref, [kAXRoleAttribute, kAXChildrenAttribute])
                let kids = AX.elements(v[1])
                if AX.string(v[0]) == "AXWebArea" { return kids.isEmpty ? nil : ref }
                next += kids
            }
            level = next
        }
        return nil
    }

    /// 창마다 찾아 둔 페이지 틀. 탭을 바꿔도 같은 틀이다.
    private static var lastContainer: (window: AXUIElement, box: AXUIElement)?

    /// 페이지를 담는 틀: DOM 클래스가 ContentsContainerView 인 묶음. 창 넓이의 1/5 넘는 큰 요소 쪽으로만 내려간다.
    static func findContentsContainer(_ window: AXUIElement) -> AXUIElement? {
        if let last = lastContainer, CFEqual(last.window, window), let f = AX.frame(last.box), f.width > 50 { return last.box }
        let windowArea = AX.frame(window).map { $0.width * $0.height } ?? 0
        var stack = [(window, 0)]
        var seen = 0
        while let (ref, depth) = stack.popLast(), seen < 80 {
            seen += 1
            let v = AX.multi(ref, ["AXDOMClassList", kAXChildrenAttribute])
            if ((v[0] as? [String]) ?? []).contains("ContentsContainerView") {
                lastContainer = (window, ref)
                return ref
            }
            guard depth < 10 else { continue }
            for c in AX.elements(v[1]) {
                if let f = AX.frame(c), f.width * f.height >= windowArea * 0.2 { stack.append((c, depth + 1)) }
            }
        }
        return nil
    }

    /// 접근성 위치가 깨진 사이트(호스트). 다음부터는 페이지를 접근성으로 훑지 않고 처음부터 페이지에 직접 묻는다.
    /// 설정에 남겨 Hanmium 을 다시 띄워도 첫 번째부터 빠르게.
    static var brokenHosts = Set(Config.defaults.stringArray(forKey: "chromeBrokenHosts") ?? []) {
        didSet { Config.defaults.set(Array(brokenHosts).sorted(), forKey: "chromeBrokenHosts") }
    }

    static func host(of web: AXUIElement) -> String? {
        (AX.copy(web, "AXURL") as? URL)?.host ?? (AX.copy(web, "AXURL") as? NSURL)?.host
    }

    /// 창 안의 웹 영역(내용이 든 것). 탭·툴바·북마크 줄을 다 훑으면 40ms 가 들어서, 창 넓이의 1/5 넘는 큰 요소 쪽으로만
    /// 내려간다(웹 영역은 창 대부분을 차지한다).
    /// 창마다 지난번에 찾은 웹 영역. 탭을 바꾸면 다른 웹 영역이 되므로 아직 이 창에 붙어 있고 내용이 있는지 보고 쓴다.
    private static var lastWebArea: (window: AXUIElement, web: AXUIElement)?

    static func findWebArea(_ window: AXUIElement, app: AXUIElement? = nil) -> AXUIElement? {
        if let last = lastWebArea, CFEqual(last.window, window), stillShown(last.web, in: window) { return last.web }
        let found = searchWebArea(window, app: app)
        if let found { lastWebArea = (window, found) }
        return found
    }

    /// 웹 영역이 아직 이 창 안에 보이는지: 부모를 따라 올라가 이 창에 닿고, 내용이 있다. 뒤로 간 탭의 웹 영역은 창에서 떨어진다.
    private static func stillShown(_ web: AXUIElement, in window: AXUIElement) -> Bool {
        let v = AX.multi(web, [kAXChildrenAttribute, kAXParentAttribute])
        guard !AX.elements(v[0]).isEmpty else { return false }
        var node = AX.element(v[1])
        for _ in 0..<20 {
            guard let n = node else { return false }
            if CFEqual(n, window) { return true }
            node = AX.element(AX.copy(n, kAXParentAttribute))
        }
        return false
    }

    private static func searchWebArea(_ window: AXUIElement, app: AXUIElement?) -> AXUIElement? {
        // 키보드 포커스는 대개 페이지 안에 있어서 부모를 몇 번 따라 올라가면 웹 영역이다(AX 몇 번, 1~3ms)
        if let app, var node = AX.element(AX.copy(app, kAXFocusedUIElementAttribute)) {
            for _ in 0..<40 {
                let v = AX.multi(node, [kAXRoleAttribute, kAXParentAttribute, kAXChildrenAttribute])
                if AX.string(v[0]) == "AXWebArea" {
                    // 페이지 안의 iframe 웹 영역일 수 있어 맨 바깥 것까지 올라간다
                    var top = node
                    var up = AX.element(v[1])
                    while let u = up {
                        let uv = AX.multi(u, [kAXRoleAttribute, kAXParentAttribute])
                        if AX.string(uv[0]) == "AXWebArea" { top = u }
                        if AX.string(uv[0]) == "AXWindow" { break }
                        up = AX.element(uv[1])
                    }
                    return AX.elements(AX.copy(top, kAXChildrenAttribute)).isEmpty ? nil : top
                }
                if AX.string(v[0]) == "AXWindow" { break }
                guard let parent = AX.element(v[1]) else { break }
                node = parent
            }
        }
        let wv = AX.multi(window, [kAXSizeAttribute])
        let windowArea = AX.size(wv[0]).map { $0.width * $0.height } ?? 0
        var stack = [(window, 0)]
        var seen = 0
        while let (ref, depth) = stack.popLast(), seen < 200 {
            seen += 1
            let v = AX.multi(ref, [kAXRoleAttribute, kAXChildrenAttribute])
            let children = AX.elements(v[1])
            if AX.string(v[0]) == "AXWebArea" { return children.isEmpty ? nil : ref }
            guard depth < 16 else { continue }
            var big: [(AXUIElement, CGFloat)] = []
            for c in children {
                let sz = AX.size(AX.multi(c, [kAXSizeAttribute])[0])
                let area = sz.map { $0.width * $0.height } ?? 0
                if area >= windowArea * 0.2 { big.append((c, area)) }
            }
            // 큰 것부터 보도록 작은 것을 먼저 쌓는다
            for (c, _) in big.sorted(by: { $0.1 < $1.1 }) { stack.append((c, depth + 1)) }
        }
        return nil
    }

    /// 페이지 링크를 못 찾았을 때 로그에 남길 것: 창 제목, 웹 영역, 링크 수, 높이 1 이하인 링크 수, 몇 개의 위치
    static func describeWeb(_ window: AXUIElement) -> String {
        let title = AX.string(AX.copy(window, kAXTitleAttribute)) ?? "?"
        guard let web = findWebArea(window) else { return "[\(title)] 웹 영역 없음" }
        let wv = AX.multi(web, [kAXPositionAttribute, kAXSizeAttribute])
        var links = 0, flat = 0, samples: [String] = []
        var queue = [web]
        var seen = 0
        while !queue.isEmpty, seen < 3000 {
            let ref = queue.removeFirst()
            seen += 1
            let a = AX.multi(ref, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute])
            if AX.string(a[0]) == "AXLink", let p = AX.point(a[1]), let s = AX.size(a[2]) {
                links += 1
                if s.height <= 1 { flat += 1 }
                if samples.count < 4 { samples.append("(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))") }
            }
            queue += AX.elements(a[3])
        }
        let area = AX.point(wv[0]).flatMap { o in AX.size(wv[1]).map { "(\(Int(o.x)),\(Int(o.y)) \(Int($0.width))x\(Int($0.height)))" } } ?? "?"
        return "[\(title.prefix(40))] 웹 영역 \(area), 링크 \(links)개 중 높이 1 이하 \(flat)개, 예 \(samples.joined(separator: " "))"
    }
}

enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// NSScreen(좌하단 원점) 프레임을 AX 좌표계로
    static func axFrame(_ s: NSScreen) -> CGRect {
        CGRect(x: s.frame.minX, y: primaryHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
    }

    static var axUnion: CGRect { NSScreen.screens.map(axFrame).reduce(CGRect.null) { $0.union($1) } }

    static func screen(for axRect: CGRect?) -> NSScreen {
        let screens = NSScreen.screens
        if let r = axRect, let s = screens.first(where: { axFrame($0).contains(CGPoint(x: r.midX, y: r.midY)) }) {
            return s
        }
        return NSScreen.main ?? screens[0]
    }
}

/// HANMIUM_PROFILE=1 로 실행하거나 `defaults write com.local.Hanmium profile -bool true` 면 단계별 걸린 시간을
/// 출력하고 로그(~/Library/Logs/Hanmium.log)에도 남긴다 (최적화할 곳을 찾을 때)
final class Profile {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["HANMIUM_PROFILE"] != nil || Config.defaults.bool(forKey: "profile")
    }
    private var last = CACurrentMediaTime()
    private var marks: [(String, Double)] = []

    func mark(_ name: String) {
        guard Self.enabled else { return }
        let now = CACurrentMediaTime()
        marks.append((name, (now - last) * 1000))
        last = now
    }

    func report(_ title: String) {
        guard Self.enabled else { return }
        let line = "[측정] \(title): " + marks.map { "\($0.0) \(Int($0.1))ms" }.joined(separator: " · ")
        print(line)
        DispatchQueue.main.async { Log.write(line) }
    }
}

/// 메뉴 막대 상태 아이콘이 있는 앱. 실행 중인 앱 50개 안팎에 매번 다 물으면 앱마다 30~60ms 씩 걸려
/// 200ms 넘게 들었는데(라벨 찾기 시간의 70~80%), 아이콘이 있는 앱은 10개 안팎이라 그 앱들만 기억해 두고 묻는다.
/// 아직 물어보지 않은 앱(새로 실행된 앱)은 함께 묻고, 전체 목록은 뒤에서 1분에 한 번 새로 고친다.
enum ExtrasCache {
    private static let lock = NSLock()
    private static var owners = Set<pid_t>()
    private static var asked = Set<pid_t>()
    private static var lastFullScan: CFTimeInterval = 0
    private static let queue = DispatchQueue(label: "Hanmium.extras", qos: .utility)

    static func candidates(among pids: [pid_t]) -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return pids.filter { owners.contains($0) || !asked.contains($0) }
    }

    static func learn(asked pids: [pid_t], owners found: Set<pid_t>) {
        lock.lock()
        for pid in pids {
            asked.insert(pid)
            if found.contains(pid) { owners.insert(pid) } else { owners.remove(pid) }
        }
        lock.unlock()
    }

    /// 실행 중인 모든 앱에 다시 물어 목록을 새로 고친다(뒤에서). 1분 안에 했으면 건너뛴다.
    static func refreshIfStale(force: Bool = false) {
        let now = CACurrentMediaTime()
        lock.lock()
        let stale = force || now - lastFullScan > 60
        if stale { lastFullScan = now }
        lock.unlock()
        guard stale else { return }
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited || TreeBuilder.alwaysExtrasApps.contains($0.bundleIdentifier ?? "") }
            .map(\.processIdentifier)
        queue.async {
            lock.lock()
            asked.removeAll()
            lock.unlock()
            _ = TreeBuilder.queryExtras(pids)
        }
    }
}

/// 상태 아이콘을 물어볼 앱들과 Dock. 모드를 열 때마다 실행 중인 앱을 모두 훑고 Dock 설정을 읽으면 14~17ms 가 들어서
/// (라벨이 늦게 떴다) 앱이 켜지거나 꺼질 때만 다시 만들고, Dock 자동 숨김은 10초마다만 다시 읽는다. 메인 스레드에서만 쓴다.
enum RunningApps {
    private static var cached: (extraPids: [pid_t], dockPid: pid_t?)?
    private static var dockHidden = false
    private static var dockReadAt: CFTimeInterval = -100
    private static var observing = false

    static func current() -> (extraPids: [pid_t], dockPid: pid_t?) {
        observe()
        let now = CACurrentMediaTime()
        if now - dockReadAt > 10 {
            dockReadAt = now
            dockHidden = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        }
        if cached == nil {
            let apps = NSWorkspace.shared.runningApplications
            let extra = apps
                .filter { $0.activationPolicy != .prohibited || TreeBuilder.alwaysExtrasApps.contains($0.bundleIdentifier ?? "") }
                .map(\.processIdentifier)
            cached = (extra, apps.first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier)
        }
        return (cached!.extraPids, dockHidden ? nil : cached!.dockPid)
    }

    private static func observe() {
        guard !observing else { return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in cached = nil }
        }
    }
}
