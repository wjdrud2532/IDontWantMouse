import AppKit
import QuartzCore

/// 스크롤 영역을 골라 키보드로 스크롤한다.
///
/// h/j/k/l(설정 가능)·화살표: 누르고 있는 동안 부드럽게 스크롤, Shift 를 같이 누르면 빠르게(dash).
/// d/u: 반 페이지를 부드럽게, 누르고 있으면 빠르게 계속. gg/G: 맨 위/맨 아래.
/// 1~9: 창이 여러 개면 그 번호의 창으로(같은 번호를 다시 누르면 그 창의 다음 영역),
///      창이 하나면 그 번호의 스크롤 영역으로.
/// Tab·Shift-Tab, Ctrl-N/P: 다음/이전 스크롤 영역(창을 넘나든다). Enter: 그 영역을 눌러 포커스를 옮기고 끝내기.
/// f: 라벨 띄우기(onLabels). 그 밖의 ⌘·⌃ 단축키(탭 바꾸기 등)는 앱으로 넘긴다(onPassThrough). Esc: 끝내기.
/// 휠 이벤트는 커서를 옮기지 않고 그 창에 직접 보낸다. 그럴 수 없는 곳에서만 커서를 영역으로 옮긴다.
/// 페이지를 옮겨 가서 고른 영역의 AX 요소가 사라지거나 앱의 키 창이 바뀌면 onStale 로 알린다(그 자리에 새로 열어야 한다).
final class ScrollMode: Mode {
    var onExit: (() -> Void)?
    /// f 를 눌렀을 때 (라벨 모드로 넘어가기)
    var onLabels: (() -> Void)?
    /// 스크롤 모드가 쓰지 않는 ⌘·⌃ 단축키를 눌렀을 때 (앱으로 넘겨야 한다)
    var onPassThrough: ((NSEvent) -> Void)?
    /// 고른 영역이 사라졌거나 키 창이 바뀌었을 때. 웹 페이지는 문서가 바뀌면(같은 사이트 안에서 옮겨 가도)
    /// 스크롤 영역 요소를 새로 만든다. 누른 것이 새 창을 열면 키 창이 바뀐다.
    var onStale: (() -> Void)?
    private var staleTimer: Timer?
    /// 앱의 키 창. 열 때 값에서 바뀌면 새로 연다.
    private var keyWindow: AXUIElement?
    /// 이때까지는 키 창이 바뀌어도 새로 열지 않고 그 창을 기준으로 삼는다 (가려진 창을 스스로 앞으로 올렸을 때)
    private var adoptKeyWindowUntil: CFTimeInterval = 0
    private let pid: pid_t
    private let bundleID: String?
    /// 지난 영역으로 먼저 띄웠으면 새로 찾은 같은 자리의 요소로 바뀐다(adopt)
    private var windows: [Element]
    private var areas: [(area: Element, window: Int)]
    private var index = 0
    /// 휠 이벤트를 보낼 위치
    private var scrollPoint = CGPoint.zero { didSet { driver.setAim(.init(target: target, point: scrollPoint)) } }
    /// 휠 이벤트를 직접 받을 창. nil 이면 커서를 scrollPoint 로 옮겨서 보낸다.
    private var target: Mouse.Target? { didSet { driver.setAim(.init(target: target, point: scrollPoint)) } }
    private let overlay: Overlay
    /// 누르고 있는 키대로 화면 새로 고침마다 휠 이벤트를 보낸다
    private let driver: ScrollDriver
    private var lastG: CFTimeInterval = 0
    private var stopped = false
    /// WezTerm 은 휠 이벤트 하나를 한 칸으로 넘기므로 픽셀을 모았다가 설정한 줄 수(15px × N)씩 보낸다(ScrollDriver)
    private let notch: CGFloat?
    /// 번호 라벨이 유리면, 스크롤·창 전환으로 뒤 화면이 바뀐 뒤 다시 찍는다
    private let glassLabels: Bool
    private var glassRefresh: DispatchWorkItem?
    /// 연 창과 그때의 포커스. 닫을 때 마지막 영역과 함께 기억해 둔다(ScrollMemory).
    private let windowID: CGWindowID?
    private var focusAtStart: CGRect?
    /// 키를 하나라도 눌렀는지. 지난 영역으로 먼저 띄운 뒤 새로 찾은 결과로 시작 영역을 고칠지 볼 때 쓴다(adopt).
    private var touched = false
    /// 고른 영역 테두리를 물방울처럼 옮기는 중인 움직임
    private var motion: DropletMotion?
    /// 고르지 않은 영역마다 그려 둔 유리판 굴절 가장자리. 그 영역을 다시 고르면 지운다.
    private var slabEdges: [Int: (image: CGImage, frame: CGRect)] = [:]
    /// 멈춰 있는 테두리 둘레를 판 유리(가까운 영역 유리판·배경). 테두리가 다시 움직이거나 새 화면이 오면 지운다.
    private var restGlass: [String: [(frame: CGRect, image: CGImage)]] = [:]
    /// 유리판 가장자리 띠는 사진으로 그려 두어서, 띠 밑 내용(다른 분할 창의 출력)이 바뀌면 띠만 멈춰 보인다.
    /// 1초마다 새 화면을 한 장 받아 다시 그린다(화면이 그대로면 새 장이 오지 않는다).
    private var slabRefreshTimer: Timer?
    private var slabObserver: NSObjectProtocol?
    private var slabsDrawnAt: CFTimeInterval = 0
    private var motionTimer: Timer?
    /// 휠을 보낼 지점 후보 중 지금 쓰는 것(aimPoints). 보낸 뒤 내용이 움직였는지 확인될 때까지 aimConfirmed 는 false.
    private var aimIndex = 0
    private var aimConfirmed = false
    /// 영역이 움직였는지 알아볼 표지와, 확인을 기다리는 동안 보낸 양·보내기 전 표지 값
    private var probe: ScrollProbe?
    private var probeToken = 0
    private var checking: (sent: CGVector, before: [CGFloat?])?
    /// 앱·영역 종류마다 실제로 스크롤된 지점 후보 번호 (다음에 열 때 그것부터 쓴다)
    private static var aimMemory: [String: Int] = [:]

    init(snapshot: ScrollSnapshot, screen: NSScreen) {
        pid = snapshot.pid
        bundleID = snapshot.bundleID
        windows = snapshot.windows
        areas = snapshot.areas
        notch = snapshot.bundleID == WezTerm.bundleID ? CGFloat(Config.terminalNotchLines * 15) : nil
        driver = ScrollDriver(screen: screen, notch: notch)
        // 테두리는 스크롤하는 앱의 창 바로 위에만 그려서 다른 앱 창이 덮으면 같이 가려지게 한다
        let focusedWindow = snapshot.windows.indices.contains(snapshot.focusedWindow)
            ? AX.windowID(snapshot.windows[snapshot.focusedWindow].ref) : nil
        // 닫힐 때 서서히 사라지는 효과(설정, 기본 꺼짐). 켜면 앱을 바꿀 때 지난 테두리가 0.2초쯤 남는다.
        overlay = Overlay(keyScreen: screen, stackedAbove: focusedWindow, fades: Config.scrollAnimation)
        glassLabels = GlassSnapshots.wanted
        focusAtStart = snapshot.focus
        keyWindow = snapshot.keyWindow
        windowID = focusedWindow
        let (start, remembered) = Self.startIndex(for: snapshot, window: focusedWindow)
        index = start
        let r = { (f: CGRect?) in f.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "-" }
        Log.write("스크롤 모드 열림 [\(snapshot.bundleID ?? "?")] 창 \(focusedWindow.map(String.init) ?? "-") "
            + "영역 \(snapshot.areas.map { r($0.area.visibleFrame) }.joined(separator: " ")) | 포커스 \(r(snapshot.focus)) "
            + "→ 포커스 영역 \(snapshot.focusedArea.map(String.init) ?? "-"), 기억 \(remembered.map(String.init) ?? "-") "
            + "(기억된 것: \(r(focusedWindow.flatMap { ScrollMemory.entries[$0] }?.area)), "
            + "그때 포커스 \(r(focusedWindow.flatMap { ScrollMemory.entries[$0] }?.focus))) → 시작 \(index)")
    }

    /// 포커스가 그대로면 마지막으로 쓰던 영역, 바뀌었으면 포커스가 있는 영역, 둘 다 없으면 가장 큰 영역에서 시작
    private static func startIndex(for snapshot: ScrollSnapshot, window: CGWindowID?) -> (index: Int, remembered: Int?) {
        let remembered = window.flatMap { ScrollMemory.entries[$0] }.flatMap { entry -> Int? in
            guard entry.focus.map({ f in snapshot.focus.map { $0.isClose(to: f, tolerance: 6) } ?? false })
                    ?? (snapshot.focus == nil) else { return nil }
            return snapshot.areas.firstIndex { $0.area.visibleFrame.isClose(to: entry.area, tolerance: 12) }
        }
        let size = { (e: Element) in e.visibleFrame.width * e.visibleFrame.height }
        let largest = snapshot.areas.indices.filter { snapshot.areas[$0].window == snapshot.focusedWindow }
            .max { size(snapshot.areas[$0].area) < size(snapshot.areas[$1].area) }
        return (remembered ?? snapshot.focusedArea ?? largest ?? 0, remembered)
    }

    /// 지난 영역으로 먼저 띄운 뒤 새로 찾은 결과가 같은 자리일 때(AppDelegate): 닫았다 열지 않고(깜빡인다) 새 요소로
    /// 바꿔 끼운다(탭을 바꾸면 자리는 같고 요소만 다르다). 포커스도 새 것으로 두고, 아직 키를 누르지 않았으면
    /// 새 포커스로 정한 시작 영역으로 옮긴다(그사이 앱에서 포커스를 옮겼을 때).
    func adopt(_ snapshot: ScrollSnapshot) {
        guard !stopped else { return }
        let changed = !CFEqual(current.ref, snapshot.areas[index].area.ref)
        windows = snapshot.windows
        areas = snapshot.areas
        focusAtStart = snapshot.focus
        keyWindow = snapshot.keyWindow
        if changed, target != nil {
            // 휠을 보낼 지점이 맞는지 볼 표지는 새 요소에서 다시 찾는다
            aimConfirmed = false
            checking = nil
            findProbe()
        }
        guard !touched else { return }
        let start = Self.startIndex(for: snapshot, window: windowID).index
        if start != index {
            Log.write("새로 찾은 포커스로 시작 영역 \(index) → \(start)")
            focus(start)
        }
    }

    func start() {
        overlay.paint = { [unowned self] rect in paint(rect) }
        overlay.onKeyDown = { [unowned self] event in keyDown(event) }
        overlay.onKeyUp = { [unowned self] event in driver.release(event.keyCode) }
        driver.onSend = { [weak self] by, before in self?.didSend(by, before: before) }
        overlay.show()
        // 스크롤 모드 동안 뒤 화면을 계속 받아 물방울 이동·스크롤 중에도 굴절이 바로 바뀌게 한다
        if glassLabels { GlassSnapshots.startStream(excluding: overlay.windowIDs) }
        focus(index)
        watchStale()
        // 영역이 하나뿐이어도 배경 굴절(테두리 둘레)은 그려 두므로 새 화면으로 다시 그린다
        if glassLabels, Config.inactiveAreaShown, Config.inactiveAreaStyle == .glass,
           areas.count > 1 || Config.backgroundRefraction {
            slabObserver = NotificationCenter.default.addObserver(forName: GlassSnapshots.didChange, object: nil,
                                                                  queue: .main) { [weak self] _ in
                // 스크롤하는 동안에는 화면이 초당 수십 장 와서 1초에 한 번만
                guard let self, !stopped, CACurrentMediaTime() - slabsDrawnAt >= 0.9 else { return }
                slabsDrawnAt = CACurrentMediaTime()
                slabEdges.removeAll()
                restGlass.removeAll()
                overlay.redraw()
            }
            slabRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                _ = GlassSnapshots.wantLive(for: 0.05)
            }
        }
    }

    /// 고른 영역 요소가 아직 있는지, 앱의 키 창이 그대로인지 0.25초마다 본다. 사라진 요소로는 표지를 읽지 못해서,
    /// 휠이 안 먹은 줄 알고 다른 지점에 같은 양을 다시 보내 크게 튄다(checkAim). 라벨을 누른 뒤 바로 다시 열어서
    /// 페이지가 늦게 바뀌거나 새 창이 늦게 뜨는 것도 여기서 잡는다. 앱이 느려도 키 입력이 막히지 않게 AX 는 뒤에서 묻는다.
    private func watchStale() {
        let app = AXUIElementCreateApplication(pid)
        staleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, !stopped else { return }
            let ref = current.ref
            DispatchQueue.global(qos: .utility).async {
                var value: CFTypeRef?
                let gone = AXUIElementCopyAttributeValue(ref, kAXRoleAttribute as CFString, &value) == .invalidUIElement
                let key = AX.element(AX.copy(app, kAXFocusedWindowAttribute))
                DispatchQueue.main.async { [weak self] in
                    guard let self, !stopped, CFEqual(current.ref, ref), staleTimer != nil else { return }
                    var reason: String?
                    if gone {
                        reason = "스크롤 영역이 사라짐(페이지 바뀜)"
                    } else if let key, !(keyWindow.map { CFEqual($0, key) } ?? false) {
                        if CACurrentMediaTime() < adoptKeyWindowUntil { keyWindow = key } else { reason = "키 창이 바뀜" }
                    }
                    guard let reason else { return }
                    staleTimer?.invalidate()
                    staleTimer = nil
                    Log.write("\(reason) → 새로 열기 [\(bundleID ?? "?")]")
                    onStale?()
                }
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let windowID, areas.indices.contains(index) {
            ScrollMemory.entries[windowID] = .init(area: current.visibleFrame, focus: focusAtStart)
            Log.write("스크롤 모드 닫힘: 창 \(windowID) 영역 \(index) 기억")
        }
        driver.stop()
        staleTimer?.invalidate()
        slabRefreshTimer?.invalidate()
        if let slabObserver { NotificationCenter.default.removeObserver(slabObserver) }
        motionTimer?.invalidate()
        glassRefresh?.cancel()
        GlassSnapshots.stopStream()
        overlay.close()
        onExit?()
    }

    private var current: Element { areas[index].area }
    private var currentWindow: Int { areas[index].window }
    private var center: CGPoint { CGPoint(x: current.visibleFrame.midX, y: current.visibleFrame.midY) }
    private var multiWindow: Bool { windows.count > 1 }

    private func largestArea(inWindow w: Int) -> Int? {
        let size = { (e: Element) in e.visibleFrame.width * e.visibleFrame.height }
        return areas.indices.filter { areas[$0].window == w }.max { size(areas[$0].area) < size(areas[$1].area) }
    }

    private func paint(_ rect: CGRect) {
        let width = Config.scrollBorderWidth
        let moving = motion.map { !$0.isSettled } ?? false
        let blob = motion?.rect ?? current.visibleFrame
        if Config.inactiveAreaShown, Config.inactiveAreaStyle == .glass {
            let color = Config.inactiveAreaColor, fill = Config.inactiveFillOpacity
            // 유리판 = 영역 − 테두리(유리 막대 바깥까지). 갈 영역에도 유리판이 남아 있다가 테두리 모양대로 파이고,
            // 떠난 영역은 테두리가 빠져나가는 모양대로 차오른다. 멈춘 뒤에도 테두리 둘레는 휜 채로 남는다.
            let hole: (rect: CGRect, radius: CGFloat) = Config.scrollBorderShown && Config.scrollBorderStyle == .glass
                ? Draw.ringOuter(blob, band: Draw.ringBand(width), stretch: motion?.stretch ?? 0, lens: motion?.lens ?? 0)
                : (blob, Draw.blobRadius(blob, stretch: motion?.stretch ?? 0, lens: motion?.lens ?? 0))
            // 움직이는 동안은 매 장면 새로 그리고, 멈추면 한 번 그려 두고 쓴다(1초마다 새 화면으로 다시 그림).
            // 라벨 자리만 모으는 빈 그리기(Draw.collecting)나 화면 사진이 오기 전에는 아무것도 그려지지 않으니 남겨 두지 않는다.
            let glass = { [self] (key: String, make: () -> [(frame: CGRect, image: CGImage)]) in
                if moving || Draw.collecting != nil || Draw.glassSource == nil { return make() }
                let key = "\(key) \(rect.origin)"
                if let kept = restGlass[key] { return kept }
                let made = make()
                restGlass[key] = made
                return made
            }
            if Config.backgroundRefraction {
                // 유리판이 없는 곳(창의 나머지, 다른 창, 배경화면)도 테두리 둘레가 휜다. 영역 유리판은 그 위에 그린다.
                Draw.draw(glass("배경") {
                    Draw.carvedBackground(rect, hole: hole.rect, holeRadius: hole.radius,
                                          excluding: areas.filter { $0.window == currentWindow }.map(\.area.visibleFrame))
                })
            }
            for (i, a) in areas.enumerated() where a.window == currentWindow && rect.intersects(a.area.visibleFrame) {
                let slab = a.area.visibleFrame
                if hole.rect.contains(slab) { continue }
                // 테두리가 닿는(굴절 띠 안에 들어오는) 영역은 테두리 모양을 뺀 유리판으로
                if hole.rect.insetBy(dx: -Draw.slabBezel(for: slab), dy: -Draw.slabBezel(for: slab)).intersects(slab) {
                    let carved = glass("영역 \(i)") {
                        Draw.carvedGlassArea(slab, hole: hole.rect, holeRadius: hole.radius, color: color,
                                             fillOpacity: fill).map { [$0] } ?? []
                    }
                    if !carved.isEmpty || Draw.collecting != nil {
                        Draw.draw(carved)
                        continue
                    }
                    if i == index { continue }  // GPU 를 못 쓰면 예전처럼 고른 영역은 비운다
                }
                // 굴절 가장자리는 한 번 그려 두고 그대로 쓴다(1초마다 새 화면으로 다시 그림)
                if slabEdges[i] == nil {
                    slabEdges[i] = Draw.glassAreaEdge(slab, color: color, fillOpacity: fill)
                }
                Draw.glassArea(slab, selected: moving ? .zero : current.visibleFrame, color: color, fillOpacity: fill,
                               edge: slabEdges[i])
            }
        } else if Config.inactiveAreaShown {
            // 같은 창의 다른 스크롤 영역(숫자·Tab 으로 옮겨갈 곳)은 점선 + 옅은 칠. 다른 창 영역은 그리지 않는다:
            // 패널이 고른 창 바로 위에 있어서 뒤에 깔린 창의 영역이 고른 창을 덮고 그려진다.
            let color = Config.inactiveAreaColor
            let line = Config.inactiveLineOpacity, fill = Config.inactiveFillOpacity
            for (i, a) in areas.enumerated() where i != index && a.window == currentWindow
                && rect.intersects(a.area.visibleFrame) {
                Draw.inactiveArea(a.area.visibleFrame, selected: current.visibleFrame, color: color,
                                  width: max(1, width * 0.75), lineOpacity: line, fillOpacity: fill)
            }
        }
        let stretch = motion?.stretch ?? 0, lens = motion?.lens ?? 0
        if Config.scrollBorderShown, Config.scrollBorderStyle == .glass {
            // 유리 막대는 영역 바깥에 얇게 두른다
            let band = Draw.ringBand(width)
            if rect.intersects(blob.insetBy(dx: -band * 2, dy: -band * 2)) {
                Draw.glassRing(blob, color: Config.scrollBorderColor, band: band, stretch: stretch, lens: lens,
                               moving: moving, shadow: motion?.activity ?? 0)
            }
        } else if Config.scrollBorderShown, rect.intersects(blob) {
            let color = Config.scrollBorderColor
            if lens > 0 { Draw.faded(lens * 0.35) { color.setFill(); NSBezierPath(ovalIn: blob).fill() } }
            Draw.box(blob, color: color, width: width, radius: max(2, Draw.blobRadius(blob, stretch: stretch, lens: lens) - 6))
        }
        if multiWindow {
            // 숫자는 창을 고른다: 각 창 위쪽 가운데에 번호
            for (i, w) in windows.prefix(9).enumerated() {
                let p = CGPoint(x: w.visibleFrame.midX, y: w.visibleFrame.minY + 14)
                if rect.contains(p) { Draw.pill("\(i + 1)", typedCount: i == currentWindow ? 0 : 1, center: p, within: rect) }
            }
        } else if areas.count > 1 {
            for (i, a) in areas.prefix(9).enumerated() {
                let corner = CGPoint(x: a.area.visibleFrame.minX + 14, y: a.area.visibleFrame.minY + 12)
                if rect.contains(corner) { Draw.pill("\(i + 1)", center: corner, within: rect) }
            }
        }
    }

    /// 영역이 rect 에 덮인 비율(0~1)
    private func coverage(of area: CGRect, by rect: CGRect) -> CGFloat {
        let o = area.intersection(rect)
        guard !o.isNull, area.width > 0, area.height > 0 else { return 0 }
        return (o.width * o.height) / (area.width * area.height)
    }

    /// 처음 고를 때는 바로 그 자리에, 그 뒤로는 물방울처럼 옮겨간다
    private func moveBorder() {
        let rect = current.visibleFrame
        guard let motion else {
            motion = DropletMotion(rect: rect, style: Config.focusMotion, timeScale: 1 / Config.focusMotionSpeed)
            return
        }
        motion.move(to: rect)
        guard motionTimer == nil, !motion.isSettled else { return }
        if glassLabels, !GlassSnapshots.wantLive(for: 0.3) {
            // 연속 캡처를 못 쓰면 한 장씩 찍기를 되풀이한다
            GlassSnapshots.follow(excluding: overlay.windowIDs) { [weak self] in
                guard let self else { return false }
                return !stopped && motionTimer != nil
            }
        }
        motionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, let motion = self.motion else { return timer.invalidate() }
            motion.step(1.0 / 60)
            if glassLabels { GlassSnapshots.wantLive(for: 0.3) }
            overlay.redraw()
            if motion.isSettled {
                timer.invalidate()
                motionTimer = nil
            }
        }
    }

    private func focus(_ i: Int) {
        index = (i + areas.count) % areas.count
        slabEdges[index] = nil
        restGlass.removeAll()
        moveBorder()
        let window = windows[currentWindow]
        target = directTarget(for: window)
        if overlay.isStacked, let id = AX.windowID(window.ref) { overlay.stack(above: id) }
        let visible = visiblePoint()
        if visible == nil {
            // 다른 창에 완전히 가려져 있으면 보이도록 앞으로 올린다. 그 앱이 키 포커스를 가져가므로 되찾는다.
            adoptKeyWindowUntil = CACurrentMediaTime() + 0.5
            AXUIElementPerformAction(window.ref, kAXRaiseAction as CFString)
            let chosen = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, !stopped, index == chosen else { return }
                overlay.reclaimKey()
                if target == nil { aim(at: visiblePoint() ?? center) }
            }
        }
        if target != nil {
            // 커서는 그대로 두고 영역 안 지점으로 보낸다. 처음 보낼 때 실제로 움직였는지 확인한다(armAimCheck).
            aimIndex = Self.aimMemory[aimKey] ?? 0
            aimConfirmed = false
            checking = nil
            scrollPoint = aimPoints[aimIndex]
            findProbe()
        } else {
            probeToken += 1
            probe = nil
            armAimCheck()
            aim(at: visible ?? center)
        }
        overlay.redraw()
        retakeGlassSoon()
    }

    /// 움직임이 멎고 조금 뒤에 한 번만 찍는다
    private func retakeGlassSoon() {
        guard glassLabels else { return }
        // 연속 캡처 중이면 앞으로 0.5초 동안 들어오는 프레임을 쓰면 된다
        if GlassSnapshots.wantLive(for: 0.5) { return }
        glassRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !stopped else { return }
            GlassSnapshots.refresh(excluding: overlay.windowIDs)
        }
        glassRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func directTarget(for window: Element) -> Mouse.Target? {
        guard Mouse.canTargetWindows, let id = AX.windowID(window.ref) else { return nil }
        // 시스템 설정처럼 내용을 다른 프로세스가 그리는 영역은 직접 보내도 받지 못한다
        if let owner = AX.pid(current.ref), owner != pid { return nil }
        return Mouse.Target(pid: pid, window: id, windowOrigin: window.frame.origin)
    }

    /// 직접 보낼 수 없을 때: 휠 이벤트는 커서 아래 창으로 가므로 커서를 그 지점으로 옮긴다
    private func aim(at p: CGPoint) {
        scrollPoint = p
        CGWarpMouseCursorPosition(p)
    }

    /// 현재 영역 안에서 실제로 그 창이 맨 위에 보이는 지점. 가운데부터 보고, 가려졌으면 격자로 찾는다.
    private func visiblePoint() -> CGPoint? {
        let area = current.visibleFrame
        let window = windows[currentWindow].frame
        let stack = WindowStack.current()
        func reaches(_ p: CGPoint) -> Bool {
            guard let top = stack.topmost(at: p) else { return false }
            return top.pid == pid && top.bounds.isClose(to: window)
        }
        if reaches(center) { return center }
        for gy in 1...5 {
            for gx in 1...5 {
                let p = CGPoint(x: area.minX + area.width * CGFloat(gx) / 6,
                                y: area.minY + area.height * CGFloat(gy) / 6)
                if reaches(p) { return p }
            }
        }
        return nil
    }

    /// Enter: 고른 영역을 눌러 그 창(패널)으로 포커스를 옮기고 스크롤 모드를 닫는다.
    /// 링크·버튼을 잘못 누르지 않게 그런 것이 없는 자리를 골라 누른다.
    private func clickArea() {
        let area = current
        let window = windows[currentWindow]
        Log.write("Enter: 영역 \(index) 누르기 (WezTerm 패널 \(area.wezTermPane.map(String.init) ?? "-"))")
        stop()
        // WezTerm 은 클릭이 Claude Code·vim 같은 프로그램으로 가므로 누르지 않고 창·패널만 옮긴다
        if bundleID == WezTerm.bundleID {
            AXUIElementPerformAction(window.ref, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: pid)?.activate()
            if let pane = area.wezTermPane { WezTerm.activate(pane: pane) }
            return
        }
        if let p = safeClickPoint(in: area.visibleFrame, window: window.frame) {
            // 오버레이가 사라진 뒤에 눌러야 포커스가 꼬이지 않는다
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Mouse.click(at: p) }
            return
        }
        // 다른 창에 가려 누를 자리가 없으면 앞으로 올린 뒤 다시 찾는다
        AXUIElementPerformAction(window.ref, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            if let p = safeClickPoint(in: area.visibleFrame, window: window.frame) { Mouse.click(at: p) }
        }
    }

    /// 영역 가운데부터 바깥으로 훑으며, 그 창이 맨 위에 보이고 링크·버튼이 아닌 자리
    private func safeClickPoint(in area: CGRect, window: CGRect) -> CGPoint? {
        let stack = WindowStack.current()
        let app = AXUIElementCreateApplication(pid)
        let unsafe = TreeBuilder.clickableRoles.subtracting(["AXTextField", "AXTextArea"])
        func safe(_ p: CGPoint) -> Bool {
            guard let top = stack.topmost(at: p), top.pid == pid, top.bounds.isClose(to: window) else { return false }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, var el = hit
            else { return true }
            // 글자를 품은 링크처럼 위쪽에 누를 수 있는 것이 있으면 피한다
            for _ in 0..<4 {
                if let role = AX.string(AX.copy(el, kAXRoleAttribute)), unsafe.contains(role) { return false }
                guard let parent = AX.element(AX.copy(el, kAXParentAttribute)) else { break }
                el = parent
            }
            return true
        }
        let inner = area.insetBy(dx: min(24, area.width / 4), dy: min(24, area.height / 4))
        var candidates = [CGPoint(x: inner.midX, y: inner.midY)]
        for ring in 1...3 {
            for gy in -ring...ring {
                for gx in -ring...ring where max(abs(gx), abs(gy)) == ring {
                    candidates.append(CGPoint(x: inner.midX + inner.width / 8 * CGFloat(gx),
                                              y: inner.midY + inner.height / 8 * CGFloat(gy)))
                }
            }
        }
        return candidates.first(where: safe)
    }

    private func select(number n: Int) {
        guard multiWindow else {
            if n <= areas.count { focus(n - 1) }
            return
        }
        guard n <= windows.count else { return }
        if currentWindow == n - 1 {
            // 이미 그 창이면 창 안의 다음 영역으로
            let inWindow = areas.indices.filter { areas[$0].window == n - 1 }
            if let pos = inWindow.firstIndex(of: index) { focus(inWindow[(pos + 1) % inWindow.count]) }
        } else if let i = largestArea(inWindow: n - 1) {
            focus(i)
        }
    }

    private func direction(for event: NSEvent) -> CGVector? {
        switch event.keyCode {
        case 123: return CGVector(dx: -1, dy: 0)
        case 124: return CGVector(dx: 1, dy: 0)
        case 125: return CGVector(dx: 0, dy: 1)
        case 126: return CGVector(dx: 0, dy: -1)
        default: break
        }
        guard let c = KeyTranslator.character(for: event.keyCode) else { return nil }
        let keys = Config.scrollKeys
        switch c {
        case keys[0]: return CGVector(dx: -1, dy: 0)
        case keys[1]: return CGVector(dx: 0, dy: 1)
        case keys[2]: return CGVector(dx: 0, dy: -1)
        case keys[3]: return CGVector(dx: 1, dy: 0)
        default: return nil
        }
    }

    private func keyDown(_ event: NSEvent) {
        touched = true
        if event.keyCode == 53 {
            stop()
            return
        }
        guard !event.isARepeat else { return }
        if event.keyCode == 36 || event.keyCode == 76 {
            clickArea()
            return
        }
        // 키 포커스가 Hanmium 에 있어서 ⌘·⌃ 단축키(⌃Tab, ⌘1, ⌘← 등)가 앱에 가지 않으므로 넘긴다. ⌃N/⌃P 는 영역 이동.
        let character = KeyTranslator.character(for: event.keyCode)
        if let onPassThrough, event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.control) && character != "n" && character != "p" {
            onPassThrough(event)
            return
        }
        if let dir = direction(for: event) {
            driver.hold(event.keyCode, dir)
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        let control = event.modifierFlags.contains(.control)
        if event.keyCode == 48 {
            focus(index + (shift ? -1 : 1))
            return
        }
        guard let c = KeyTranslator.character(for: event.keyCode) else { return }
        let half = current.visibleFrame.height / 2
        let now = CACurrentMediaTime()
        switch c {
        case "n" where control: focus(index + 1)
        case "p" where control: focus(index - 1)
        case "f": onLabels?()
        case "1"..."9":
            if let n = Int(String(c)) { select(number: n) }
        case "d", "u":
            let sign: CGFloat = c == "d" ? 1 : -1
            driver.page(event.keyCode, by: CGVector(dx: 0, dy: sign * half),
                        continuous: CGVector(dx: 0, dy: sign * Config.dashMultiplier))
        case "g" where shift: jump(toTop: false)
        case "g":
            if now - lastG < 0.5 {
                jump(toTop: true)
                lastG = 0
            } else {
                lastG = now
            }
        default: break
        }
    }

    // MARK: - 휠 보낼 지점 확인

    /// 휠을 보낼 지점 후보. 오른쪽 가장자리(보통 스크롤 막대 자리)가 먼저다: 본문 가운데의 표·코드 블록·임베드가
    /// 휠을 가로채지 않게. 그런데 Slack 처럼 가장자리가 스크롤 상자 바깥(감싼 틀이나 자체 스크롤 막대)이면
    /// 거기서는 스크롤되지 않으므로 오른쪽 1/4, 가운데 순서로 넘어간다.
    private var aimPoints: [CGPoint] {
        let f = current.visibleFrame
        return [CGPoint(x: f.maxX - 12, y: f.midY), CGPoint(x: f.maxX - f.width / 4, y: f.midY), CGPoint(x: f.midX, y: f.midY)]
    }

    private var aimKey: String {
        let classes = (AX.copy(current.ref, "AXDOMClassList") as? [String]) ?? []
        return "\(bundleID ?? "")|\(current.role)|\(classes.joined(separator: " "))"
    }

    /// 표지는 AX 를 여러 번 불러 찾으므로 뒤에서 찾는다
    private func findProbe() {
        probe = nil
        probeToken += 1
        let token = probeToken, area = current
        driver.check(nil, tag: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = ScrollProbe.find(in: area)
            DispatchQueue.main.async {
                guard let self, self.probeToken == token else { return }
                self.probe = found
                self.armAimCheck()
            }
        }
    }

    /// 아직 확인되지 않은 지점이면 다음 세로 스크롤을 보내기 직전에 표지를 읽게 해 둔다(ScrollDriver.check).
    private func armAimCheck() {
        guard !aimConfirmed, checking == nil, notch == nil, target != nil, let probe else {
            return driver.check(nil, tag: 0)
        }
        driver.check(probe, tag: probeToken)
    }

    /// 보낸 양을 받는다. before 가 있으면 그 직전에 읽은 표지 값이다: 잠시 뒤 내용이 움직였는지 본다.
    /// 확인을 기다리는 동안 더 보낸 양은 모아 둔다 — 안 움직였으면 다음 지점에 그만큼 다시 보낸다.
    private func didSend(_ by: CGVector, before: (values: [CGFloat?], tag: Int)?) {
        retakeGlassSoon()
        guard !stopped else { return }
        if let before {
            guard before.tag == probeToken else { return }
            checking = (sent: by, before: before.values)
            let area = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.checkAim(area: area) }
        } else if checking != nil, by.dx == 0 {
            checking!.sent.dy += by.dy
        }
    }

    private func checkAim(area: Int) {
        guard let c = checking else { return }
        checking = nil
        guard !stopped, area == index, let probe, let target else { return }
        let after = probe.read()
        // 표지를 하나도 못 읽으면(요소가 사라짐) 움직였는지 알 수 없다. 다른 지점에 다시 보내면 크게 튀므로 그만 본다.
        if (c.before + after).allSatisfy({ $0 == nil }) { return }
        if !ScrollProbe.moved(c.before, after) {
            let points = aimPoints
            guard aimIndex + 1 < points.count else {
                // 어느 지점도 안 움직였다: 끝에 닿았을 수 있으니 처음 지점으로 돌아가고 다음에 다시 확인한다
                Log.write("스크롤 지점: 어디서도 움직이지 않음 (끝일 수 있음) [\(aimKey)]")
                aimIndex = 0
                scrollPoint = points[0]
                armAimCheck()
                return
            }
            aimIndex += 1
            scrollPoint = points[aimIndex]
            Log.write("스크롤 지점: 안 움직여서 \(aimIndex)번 후보로 [\(aimKey)]")
            _ = Mouse.scroll(by: c.sent, at: scrollPoint, to: target)
            checking = (sent: c.sent, before: after)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.checkAim(area: area) }
            return
        }
        aimConfirmed = true
        Self.aimMemory[aimKey] = aimIndex
    }

    /// 세로 스크롤 막대 값을 0/1 로 직접 바꾸고, 안 되면 큰 휠 이벤트를 여러 번 보낸다.
    private func jump(toTop: Bool) {
        if let bar = AX.element(AX.copy(current.ref, kAXVerticalScrollBarAttribute)),
           AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString,
                                        NSNumber(value: toTop ? 0.0 : 1.0)) == .success {
            return
        }
        for _ in 0..<20 { driver.post(CGVector(dx: 0, dy: toTop ? -5000 : 5000)) }
    }
}

/// 화면에 보이는 일반(레이어 0) 창들, 앞에서 뒤 순서.
struct WindowStack {
    struct Entry {
        let pid: pid_t
        let id: CGWindowID
        let bounds: CGRect
    }

    let entries: [Entry]

    static func current() -> WindowStack {
        let own = getpid()
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return WindowStack(entries: info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let dict = w[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return Entry(pid: pid, id: id, bounds: bounds)
        })
    }

    func topmost(at p: CGPoint) -> Entry? { entries.first { $0.bounds.contains(p) } }
}

/// 앱마다 마지막으로 찾은 스크롤 영역. 다시 열 때(창을 바꿨다 돌아오기, 라벨을 누른 뒤, 단축키) 창 배치가 그대로이고
/// 영역 요소가 아직 있으면, 찾기(50~230ms)를 기다리지 않고 이것으로 먼저 띄운다. 찾기는 뒤에서 그대로 하고
/// 결과가 다르면 바꾼다(AppDelegate.open).
enum ScrollCache {
    private static let lock = NSLock()
    private static var entries: [pid_t: (snapshot: ScrollSnapshot, at: CFTimeInterval)] = [:]

    static func store(_ snapshot: ScrollSnapshot) {
        lock.lock()
        if snapshot.areas.isEmpty {
            entries[snapshot.pid] = nil
        } else {
            entries[snapshot.pid] = (snapshot, CACurrentMediaTime())
        }
        lock.unlock()
    }

    /// 지금도 맞으면 돌려준다. 앱의 요소를 물어서 백그라운드에서 부른다. 1분이 지났거나, 앱의 맨 앞 창이 다르거나,
    /// 창 위치·크기가 바뀌었거나, 영역 요소가 사라졌으면(웹 페이지를 옮기면 새로 만든다) nil.
    static func reusable(for pid: pid_t) -> ScrollSnapshot? {
        lock.lock()
        let entry = entries[pid]
        lock.unlock()
        guard let entry, CACurrentMediaTime() - entry.at < 60 else { return nil }
        let snap = entry.snapshot
        guard snap.windows.indices.contains(snap.focusedWindow) else { return nil }
        // 창 배치는 창 서버 목록으로 본다(앱에 묻지 않아 빠르다). 앞에서부터 차례라 그 앱의 첫 창이 맨 앞 창이다.
        let shown = WindowStack.current().entries.filter { $0.pid == pid }
        guard let front = shown.first,
              AX.windowID(snap.windows[snap.focusedWindow].ref) == front.id else { return nil }
        for w in snap.windows {
            guard let id = AX.windowID(w.ref), let e = shown.first(where: { $0.id == id }),
                  e.bounds.isClose(to: w.frame, tolerance: 1) else { return nil }
        }
        for a in snap.areas {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(a.area.ref, kAXRoleAttribute as CFString, &value) == .invalidUIElement {
                return nil
            }
        }
        return snap
    }
}

extension ScrollSnapshot {
    /// 같은 창·영역 자리인지(요소는 달라도 된다). 지난 영역으로 먼저 띄운 것을 그대로 두고 요소만 바꿔 끼울지 볼 때 쓴다.
    func sameLayout(as other: ScrollSnapshot) -> Bool {
        let close = { (a: CGRect, b: CGRect) in a.isClose(to: b, tolerance: 2) }
        return pid == other.pid && focusedWindow == other.focusedWindow
            && windows.count == other.windows.count && areas.count == other.areas.count
            && zip(windows, other.windows).allSatisfy {
                AX.windowID($0.ref) == AX.windowID($1.ref) && close($0.frame, $1.frame)
            }
            && zip(areas, other.areas).allSatisfy {
                $0.window == $1.window && close($0.area.visibleFrame, $1.area.visibleFrame)
                    && $0.area.wezTermPane == $1.area.wezTermPane
            }
    }
}

/// 창마다 마지막으로 고른 스크롤 영역과 그때의 키보드 포커스. 다음에 열 때 포커스가 그대로면 그 영역에서 이어 간다.
enum ScrollMemory {
    struct Entry {
        let area: CGRect
        let focus: CGRect?
    }

    static var entries: [CGWindowID: Entry] = [:]
}

/// 동작 기록: ~/Library/Logs/Hanmium.log (문제를 재현해서 원인을 찾을 때 본다)
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Hanmium.log")
    /// 파일 쓰기(한 줄 1~2ms)는 뒤에서 차례로. 모드를 여는 동안 메인 스레드를 막지 않는다.
    private static let queue = DispatchQueue(label: "Hanmium.log", qos: .utility)
    private static let stamp = ISO8601DateFormatter()

    static func write(_ line: String) {
        let date = Date()
        queue.async {
            guard let data = "\(stamp.string(from: date)) \(line)\n".data(using: .utf8) else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size < 1_000_000, let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// 영역이 스크롤됐는지 알아보는 표지: 세로 스크롤 막대 값, 없으면 영역 안 작은 요소 몇 개의 위치.
/// 위아래에 붙어 있는 머리글·입력창은 스크롤돼도 제자리라 영역 높이의 25~85% 사이에서, 높이를 나눠 하나씩 고른다.
/// 그중 하나라도 움직이면 스크롤된 것이다 (제자리에 떠 있는 요소 하나만 보고 잘못 판단하지 않게).
struct ScrollProbe {
    let bar: AXUIElement?
    let items: [AXUIElement]

    /// 표지 값. 요소가 사라지면(가상 목록이 줄을 바꿔 끼움) 그 자리는 nil.
    func read() -> [CGFloat?] {
        if let bar { return [(AX.copy(bar, kAXValueAttribute) as? NSNumber).map { CGFloat($0.doubleValue) * 10000 }] }
        return items.map { AX.point(AX.copy($0, kAXPositionAttribute))?.y }
    }

    static func moved(_ a: [CGFloat?], _ b: [CGFloat?]) -> Bool {
        zip(a, b).contains { x, y in
            guard let x, let y else { return x != nil || y != nil }
            return abs(x - y) >= 0.5
        }
    }

    static func find(in area: Element) -> ScrollProbe? {
        if let bar = AX.element(AX.copy(area.ref, kAXVerticalScrollBarAttribute)) { return ScrollProbe(bar: bar, items: []) }
        let f = area.visibleFrame
        let bands: [ClosedRange<CGFloat>] = [0.25...0.45, 0.45...0.65, 0.65...0.85].map {
            (f.minY + f.height * $0.lowerBound)...(f.minY + f.height * $0.upperBound)
        }
        var picked: [Int: AXUIElement] = [:]
        var queue = AX.elements(AX.copy(area.ref, kAXChildrenAttribute))
        var seen = 0
        while !queue.isEmpty, seen < 600, picked.count < bands.count {
            let e = queue.removeFirst()
            seen += 1
            let v = AX.multi(e, [kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute])
            if let o = AX.point(v[0]), let s = AX.size(v[1]), s.height >= 8, s.height < f.height * 0.2,
               o.x >= f.minX - 1, o.x < f.maxX,
               let band = bands.firstIndex(where: { $0.contains(o.y) && $0.contains(o.y + s.height) }), picked[band] == nil {
                picked[band] = e
            }
            queue += AX.elements(v[2])
        }
        return picked.isEmpty ? nil : ScrollProbe(bar: nil, items: picked.sorted { $0.key < $1.key }.map(\.value))
    }
}
