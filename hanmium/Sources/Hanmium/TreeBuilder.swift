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

    private var targets: [Element] = []
    private var seenFrames = Set<FrameKey>()
    private(set) var visited = 0
    private let maxVisited = 6000

    /// NSWorkspace / NSScreen 은 메인 스레드에서 읽어 넘긴다.
    static func forFrontmost(_ running: NSRunningApplication) -> TreeBuilder {
        let apps = NSWorkspace.shared.runningApplications
        let extraPids = apps
            .filter { $0.activationPolicy != .prohibited || alwaysExtrasApps.contains($0.bundleIdentifier ?? "") }
            .map(\.processIdentifier)
        let dockHidden = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        let dockPid = apps.first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier
        return TreeBuilder(pid: running.processIdentifier, bundleID: running.bundleIdentifier,
                           screenBounds: Screens.axUnion, extraPids: extraPids,
                           dockPid: dockHidden ? nil : dockPid)
    }

    init(pid: pid_t, bundleID: String?, screenBounds: CGRect, extraPids: [pid_t], dockPid: pid_t?) {
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

        // 메뉴가 열려 있으면 메뉴 항목만 대상으로 한다
        let menus = openMenus()
        profile.mark("열린 메뉴 확인")
        if !menus.isEmpty {
            for menu in menus { walk(menu, clip: screenBounds, depth: 0, owner: nil) }
            return Snapshot(elements: targets, anchor: nil)
        }

        var snap = Snapshot()
        if let window = focusedWindow() {
            let w = Element.fetch(window, clip: screenBounds)
            snap.anchor = w?.frame
            walk(window, clip: screenBounds, depth: 0, owner: nil)
            profile.mark("창 훑기")
            // WezTerm 은 분할 패널을 AX 로 알려주지 않아서 wezterm cli 의 배치로 패널마다 라벨을 단다
            if bundleID == WezTerm.bundleID, let w {
                let cli = wez?.wait() ?? (panes: WezTerm.panes(), focused: nil)
                targets += WezTerm.paneElements(for: w, tab: WezTerm.visibleTabs(for: [w], in: cli.panes,
                                                                                  focused: .some(cli.focused))[0])
                profile.mark("WezTerm 패널")
            }
        }
        if let bar = AX.element(AX.copy(app, kAXMenuBarAttribute)) {
            addFlat(AX.elements(AX.copy(bar, kAXChildrenAttribute)))
        }
        profile.mark("앱 메뉴 막대")
        addFlat(menubarExtras())
        profile.mark("상태 아이콘(\(extraPids.count)개 앱)")
        if let dockPid {
            let dock = AXUIElementCreateApplication(dockPid)
            for list in AX.elements(AX.copy(dock, kAXChildrenAttribute)) {
                addFlat(AX.elements(AX.copy(list, kAXChildrenAttribute)))
            }
        }
        profile.mark("Dock")
        snap.elements = targets
        return snap
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

        if role == "AXWebArea", Config.useSearchPredicate, let found = searchWebArea(ref) {
            for r in found {
                if let w = Element.fetch(r, clip: childClip), w.enabled, w.isVisible, !Self.isWebContainer(w) {
                    add(w)
                }
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

    private func addFlat(_ refs: [AXUIElement]) {
        for ref in refs {
            if let e = Element.fetch(ref, clip: screenBounds), isTarget(e, insideTarget: true) { add(e) }
        }
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

    private func openMenus() -> [AXUIElement] {
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

    private func focusedWindow() -> AXUIElement? {
        AX.element(AX.copy(app, kAXFocusedWindowAttribute))
            ?? AX.element(AX.copy(app, kAXMainWindowAttribute))
            ?? AX.elements(AX.copy(app, kAXWindowsAttribute)).first
    }

    // MARK: - 스크롤 영역

    /// 앞 앱의 모든 창과 그 안의 스크롤 영역.
    func scrollSnapshot() -> ScrollSnapshot {
        let wez = bundleID == WezTerm.bundleID ? WezTerm.Prefetch() : nil
        AXEnabler.enable(app: app, pid: pid, bundleID: bundleID)
        var snap = ScrollSnapshot(pid: pid, bundleID: bundleID)
        let focused = focusedWindow()
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

        let cli = wez?.wait() ?? (panes: [], focused: nil)
        let wezPanes = cli.panes
        let wezTabs = WezTerm.visibleTabs(for: snap.windows, in: wezPanes, focused: .some(cli.focused))
        for (i, w) in snap.windows.enumerated() {
            var areas = WezTerm.paneElements(for: w, tab: wezTabs[i])
            if areas.isEmpty { areas = scrollAreas(in: w.ref) }
            // 스크롤 영역을 못 찾는 앱도 창 가운데에 휠 이벤트를 보내면 대개 스크롤된다
            if areas.isEmpty { areas = [w] }
            // 창 안의 영역 번호도 왼쪽→오른쪽, 위→아래
            areas.sort { ($0.visibleFrame.minX, $0.visibleFrame.minY) < ($1.visibleFrame.minX, $1.visibleFrame.minY) }
            snap.areas += areas.map { (area: $0, window: i) }
        }
        if let focused, let i = snap.windows.firstIndex(where: { CFEqual($0.ref, focused) }) {
            snap.focusedWindow = i
        }
        findFocus(in: &snap, wezPanes: wezPanes)
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
            guard let e = Element.fetch(ref, clip: clip) else { return }
            let hasFrame = e.frame.width > 0 && e.frame.height > 0
            if hasFrame && !e.frame.intersects(clip) { return }
            if Self.leafRoles.contains(e.role) { return }
            if e.role == "AXScrollArea", e.visibleFrame.width >= 40, e.visibleFrame.height >= 40 {
                areas.append(e)
            }
            if e.role == "AXWebArea" {
                webFrames.append(e.visibleFrame)
                areas += splitPanes(in: ref, clip: clip) + webScrollers(in: ref, clip: clip)
                return
            }
            if stopRoles.contains(e.role) { return }
            let childClip = hasFrame && Self.clippingRoles.contains(e.role) ? clip.intersection(e.frame) : clip
            for child in children(ref, role: e.role) { visit(child, clip: childClip, depth: depth + 1) }
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
    /// 규칙을 두지 않고 공통 단서로 찾는다: 스크롤 막대가 있거나, 목록·표 역할이거나, DOM 클래스·id 에 'scroll' 이 든 것.
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
                let scrolly = names.contains { $0.range(of: "scroll", options: .caseInsensitive) != nil }
                // 이름도 스크롤 막대도 없는 목록·표는 내용이 실제로 넘칠 때만 (다 보이는 표는 스크롤되지 않는다):
                // 줄이 목록 밖으로 나가거나(목록 자체가 스크롤) 목록이 조상 틀 밖으로 나갈 때(감싼 상자가 스크롤).
                // 이름에 scroll 이 든 것은 그대로 둔다: 보이는 줄만 그리는 가상 목록(Slack)은 줄이 넘치지 않는다.
                func overflowing() -> Bool {
                    if let bounds, whole.minY < bounds.minY - 8 || whole.maxY > bounds.maxY + 8 { return true }
                    let items = role == "AXList" ? AX.elements(v[6]) : AX.elements(AX.copy(ref, kAXRowsAttribute))
                    return Self.overflows(items, frame: whole)
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

    /// TreeBuilder 의 직렬 큐에서만 부른다.
    static func enable(app: AXUIElement, pid: pid_t, bundleID: String?) {
        guard enabled.insert(pid).inserted else { return }
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // AXEnhancedUserInterface 는 창 관리자 애니메이션을 느리게 하므로 꼭 필요할 때만 켠다
        if manual != .success, let bundleID, chromiumBrowsers.contains(bundleID) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
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
