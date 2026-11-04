import AppKit
import QuartzCore

/// 스크롤 영역을 골라 키보드로 스크롤한다.
///
/// h/j/k/l(설정 가능)·화살표: 누르고 있는 동안 부드럽게 스크롤, Shift 를 같이 누르면 빠르게(dash).
/// d/u: 반 페이지를 부드럽게, 누르고 있으면 빠르게 계속. gg/G: 맨 위/맨 아래.
/// 1~9: 창이 여러 개면 그 번호의 창으로(같은 번호를 다시 누르면 그 창의 다음 영역),
///      창이 하나면 그 번호의 스크롤 영역으로.
/// Tab·Shift-Tab, Ctrl-N/P: 다음/이전 스크롤 영역(창을 넘나든다). Enter: 그 영역을 눌러 포커스를 옮기고 끝내기.
/// Esc: 끝내기.
/// 휠 이벤트는 커서를 옮기지 않고 그 창에 직접 보낸다. 그럴 수 없는 곳에서만 커서를 영역으로 옮긴다.
final class ScrollMode: Mode {
    var onExit: (() -> Void)?
    private let pid: pid_t
    private let bundleID: String?
    private let windows: [Element]
    private let areas: [(area: Element, window: Int)]
    private var index = 0
    /// 휠 이벤트를 보낼 위치
    private var scrollPoint = CGPoint.zero
    /// 휠 이벤트를 직접 받을 창. nil 이면 커서를 scrollPoint 로 옮겨서 보낸다.
    private var target: Mouse.Target?
    private let overlay: Overlay
    /// 누르고 있는 키 → 목표 속도(기본 속도의 배수와 방향)
    private var held: [UInt16: CGVector] = [:]
    /// 누르고 있는 키 → 몇 번째 누름인지. 손을 뗐다 다시 누른 것과 계속 누른 것을 가른다.
    private var pressed: [UInt16: Int] = [:]
    private var pressCount = 0
    /// 지금 속도(px/ms). 목표 속도로 바로 바뀌지 않고 부드럽게 따라간다.
    private var velocity = CGVector.zero
    /// 가속·감속 시간 상수(ms)와 d/u 반 페이지 이동 시간. 설정의 애니메이션 배율을 곱한다(0 이면 즉시).
    private let accelTau = 80.0 * Config.animationScale
    private let decelTau = 60.0 * Config.animationScale
    private let glideDuration: CFTimeInterval = 0.25 * Config.animationScale
    /// d/u 를 이만큼 넘게 누르고 있으면 반 페이지에 이어 계속 스크롤한다
    private static let holdDelay = 0.12
    /// d/u 처럼 정해진 거리를 나눠 보내는 중인 스크롤. sent 는 지금까지 보낸 정수 픽셀.
    private var glide: (total: CGVector, sent: CGVector, start: CFTimeInterval)?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var carry = CGVector.zero
    private var lastG: CFTimeInterval = 0
    private var stopped = false
    /// WezTerm 은 전체 화면 앱(Claude Code, vim 등)에 휠 이벤트 하나를 크기와 상관없이 한 칸으로 넘긴다.
    /// 작은 이벤트를 자주 보내면 너무 빨라지므로 픽셀을 모았다가 설정한 줄 수(15px × N)씩 보낸다.
    private let notch: CGFloat?
    private var notchCarry = CGVector.zero
    /// 번호 라벨이 유리면, 스크롤·창 전환으로 뒤 화면이 바뀐 뒤 다시 찍는다
    private let glassLabels: Bool
    private var glassRefresh: DispatchWorkItem?
    /// 연 창과 그때의 포커스. 닫을 때 마지막 영역과 함께 기억해 둔다(ScrollMemory).
    private let windowID: CGWindowID?
    private let focusAtStart: CGRect?
    /// 고른 영역 테두리를 물방울처럼 옮기는 중인 움직임
    private var motion: DropletMotion?
    /// 고르지 않은 영역마다 그려 둔 유리판 굴절 가장자리. 그 영역을 다시 고르면 지운다.
    private var slabEdges: [Int: (image: CGImage, frame: CGRect)] = [:]
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
        // 테두리는 스크롤하는 앱의 창 바로 위에만 그려서 다른 앱 창이 덮으면 같이 가려지게 한다
        let focusedWindow = snapshot.windows.indices.contains(snapshot.focusedWindow)
            ? AX.windowID(snapshot.windows[snapshot.focusedWindow].ref) : nil
        overlay = Overlay(keyScreen: screen, stackedAbove: focusedWindow)
        glassLabels = GlassSnapshots.wanted
        focusAtStart = snapshot.focus
        windowID = focusedWindow
        // 포커스가 그대로면 마지막으로 쓰던 영역, 바뀌었으면 포커스가 있는 영역, 둘 다 없으면 가장 큰 영역에서 시작
        let remembered = focusedWindow.flatMap { ScrollMemory.entries[$0] }.flatMap { entry -> Int? in
            guard entry.focus.map({ f in snapshot.focus.map { $0.isClose(to: f, tolerance: 6) } ?? false })
                    ?? (snapshot.focus == nil) else { return nil }
            return snapshot.areas.firstIndex { $0.area.visibleFrame.isClose(to: entry.area, tolerance: 12) }
        }
        index = remembered ?? snapshot.focusedArea ?? largestArea(inWindow: snapshot.focusedWindow) ?? 0
        let r = { (f: CGRect?) in f.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "-" }
        Log.write("스크롤 모드 열림 [\(snapshot.bundleID ?? "?")] 창 \(focusedWindow.map(String.init) ?? "-") "
            + "영역 \(snapshot.areas.map { r($0.area.visibleFrame) }.joined(separator: " ")) | 포커스 \(r(snapshot.focus)) "
            + "→ 포커스 영역 \(snapshot.focusedArea.map(String.init) ?? "-"), 기억 \(remembered.map(String.init) ?? "-") "
            + "(기억된 것: \(r(focusedWindow.flatMap { ScrollMemory.entries[$0] }?.area)), "
            + "그때 포커스 \(r(focusedWindow.flatMap { ScrollMemory.entries[$0] }?.focus))) → 시작 \(index)")
    }

    func start() {
        overlay.paint = { [unowned self] rect in paint(rect) }
        overlay.onKeyDown = { [unowned self] event in keyDown(event) }
        overlay.onKeyUp = { [unowned self] event in keyUp(event) }
        overlay.show()
        // 스크롤 모드 동안 뒤 화면을 계속 받아 물방울 이동·스크롤 중에도 굴절이 바로 바뀌게 한다
        if glassLabels { GlassSnapshots.startStream(excluding: overlay.windowIDs) }
        focus(index)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let windowID, areas.indices.contains(index) {
            ScrollMemory.entries[windowID] = .init(area: current.visibleFrame, focus: focusAtStart)
            Log.write("스크롤 모드 닫힘: 창 \(windowID) 영역 \(index) 기억")
        }
        timer?.invalidate()
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
            for (i, a) in areas.enumerated() where i != index && a.window == currentWindow
                && rect.intersects(a.area.visibleFrame) {
                // 굴절 가장자리는 고르지 않은 영역이 된 때의 화면으로 한 번만 그려 두고 그대로 쓴다
                let slab = a.area.visibleFrame
                if slabEdges[i] == nil {
                    slabEdges[i] = Draw.glassAreaEdge(slab, color: color, fillOpacity: fill, bezel: Draw.slabBezel(width))
                }
                Draw.glassArea(slab, selected: current.visibleFrame, color: color, fillOpacity: fill, edge: slabEdges[i])
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
                               moving: moving)
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
        moveBorder()
        let window = windows[currentWindow]
        target = directTarget(for: window)
        if overlay.isStacked, let id = AX.windowID(window.ref) { overlay.stack(above: id) }
        let visible = visiblePoint()
        if visible == nil {
            // 다른 창에 완전히 가려져 있으면 보이도록 앞으로 올린다. 그 앱이 키 포커스를 가져가므로 되찾는다.
            AXUIElementPerformAction(window.ref, kAXRaiseAction as CFString)
            let chosen = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, !stopped, index == chosen else { return }
                overlay.reclaimKey()
                if target == nil { aim(at: visiblePoint() ?? center) }
            }
        }
        if target != nil {
            // 커서는 그대로 두고 영역 안 지점으로 보낸다. 처음 보낼 때 실제로 움직였는지 확인한다(verifyAim).
            aimIndex = Self.aimMemory[aimKey] ?? 0
            aimConfirmed = false
            checking = nil
            scrollPoint = aimPoints[aimIndex]
            findProbe()
        } else {
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
        if event.keyCode == 53 {
            stop()
            return
        }
        guard !event.isARepeat else { return }
        if event.keyCode == 36 || event.keyCode == 76 {
            clickArea()
            return
        }
        if let dir = direction(for: event) {
            held[event.keyCode] = dir
            startTimer()
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
        case "1"..."9":
            if let n = Int(String(c)) { select(number: n) }
        case "d", "u":
            let sign: CGFloat = c == "d" ? 1 : -1
            glide(CGVector(dx: 0, dy: sign * half))
            holdToContinue(event.keyCode, CGVector(dx: 0, dy: sign * Config.dashMultiplier))
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

    private func keyUp(_ event: NSEvent) {
        held.removeValue(forKey: event.keyCode)
        pressed.removeValue(forKey: event.keyCode)
    }

    /// 짧게 치면 반 페이지만, holdDelay 넘게 누르고 있으면 감속 중인 반 페이지 이동에 이어 그대로 가속한다.
    /// 시스템 키 반복을 기다리면 반 페이지 이동이 다 끝나 한 번 멈췄다 출발하게 된다.
    private func holdToContinue(_ keyCode: UInt16, _ continuous: CGVector) {
        pressCount += 1
        let press = pressCount
        pressed[keyCode] = press
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay) { [weak self] in
            guard let self, !stopped, pressed[keyCode] == press else { return }
            held[keyCode] = continuous
            startTimer()
        }
    }

    /// 정해진 거리를 glideDuration 동안 처음엔 빠르게, 끝에선 느리게 나눠 보낸다.
    /// 아직 다 가지 않았는데 또 누르면 남은 거리에 더해 다시 시작한다.
    private func glide(_ by: CGVector) {
        var total = by
        if let g = glide {
            total.dx += g.total.dx - g.sent.dx
            total.dy += g.total.dy - g.sent.dy
        }
        glide = (total, .zero, CACurrentMediaTime())
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        carry = .zero
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [unowned self] _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dtMs = (now - lastTick) * 1000
        lastTick = now

        // 누르고 있는 키들의 목표 속도. 지금 속도는 거기로 지수적으로 다가간다(멈출 때는 조금 더 빨리).
        var target = CGVector.zero
        for d in held.values {
            target.dx += d.dx
            target.dy += d.dy
        }
        let speed = Config.scrollPxPerMs * (NSEvent.modifierFlags.contains(.shift) ? Config.dashMultiplier : 1)
        target.dx *= speed
        target.dy *= speed
        let speeding = hypot(target.dx, target.dy) >= hypot(velocity.dx, velocity.dy)
        let tau = speeding ? accelTau : decelTau
        let k = tau > 0 ? 1 - exp(-dtMs / tau) : 1
        velocity.dx += (target.dx - velocity.dx) * k
        velocity.dy += (target.dy - velocity.dy) * k
        if held.isEmpty && hypot(velocity.dx, velocity.dy) < 0.02 { velocity = .zero }
        carry.dx += velocity.dx * dtMs
        carry.dy += velocity.dy * dtMs
        // 휠 이벤트는 정수 픽셀이라 소수점은 다음 틱으로 넘긴다
        var step = CGVector(dx: carry.dx.rounded(.towardZero), dy: carry.dy.rounded(.towardZero))
        carry.dx -= step.dx
        carry.dy -= step.dy

        // d/u: ease-out 곡선을 따라 이번 틱까지 가야 할 만큼
        if var g = glide {
            let p = glideDuration > 0 ? min(1, (now - g.start) / glideDuration) : 1
            let eased = 1 - pow(1 - p, 2)
            let due = CGVector(dx: (g.total.dx * eased).rounded(.towardZero),
                               dy: (g.total.dy * eased).rounded(.towardZero))
            step.dx += due.dx - g.sent.dx
            step.dy += due.dy - g.sent.dy
            g.sent = due
            glide = p < 1 ? g : nil
        }

        if step.dx != 0 || step.dy != 0 { scroll(step) }
        if held.isEmpty && glide == nil && velocity == .zero {
            timer?.invalidate()
            timer = nil
        }
    }

    private func scroll(_ by: CGVector) {
        guard let notch else { return send(by) }
        notchCarry.dx += by.dx
        notchCarry.dy += by.dy
        let nx = Int((notchCarry.dx / notch).rounded(.towardZero))
        let ny = Int((notchCarry.dy / notch).rounded(.towardZero))
        notchCarry.dx -= CGFloat(nx) * notch
        notchCarry.dy -= CGFloat(ny) * notch
        // 한 칸씩 따로 보내야 전체 화면 앱이 칸 수만큼 움직인다
        for _ in 0..<abs(ny) { send(CGVector(dx: 0, dy: ny > 0 ? notch : -notch)) }
        for _ in 0..<abs(nx) { send(CGVector(dx: nx > 0 ? notch : -notch, dy: 0)) }
    }

    private func send(_ by: CGVector) {
        retakeGlassSoon()
        if let target {
            verifyAim(by)
            if Mouse.scroll(by: by, at: scrollPoint, to: target) { return }
        }
        Mouse.scroll(by: by, at: scrollPoint)
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = ScrollProbe.find(in: area)
            DispatchQueue.main.async {
                guard let self, self.probeToken == token else { return }
                self.probe = found
            }
        }
    }

    /// 세로 스크롤을 보낼 때, 아직 확인되지 않은 지점이면 잠시 뒤 내용이 움직였는지 본다.
    /// 확인을 기다리는 동안 더 보낸 양은 모아 둔다 — 안 움직였으면 다음 지점에 그만큼 다시 보낸다.
    private func verifyAim(_ by: CGVector) {
        guard !aimConfirmed, notch == nil, by.dx == 0, by.dy != 0, let probe else { return }
        if checking != nil {
            checking!.sent.dy += by.dy
            return
        }
        checking = (sent: by, before: probe.read())
        let area = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.checkAim(area: area) }
    }

    private func checkAim(area: Int) {
        guard let c = checking else { return }
        checking = nil
        guard !stopped, area == index, let probe, let target else { return }
        let after = probe.read()
        if !ScrollProbe.moved(c.before, after) {
            let points = aimPoints
            guard aimIndex + 1 < points.count else {
                // 어느 지점도 안 움직였다: 끝에 닿았을 수 있으니 처음 지점으로 돌아가고 다음에 다시 확인한다
                Log.write("스크롤 지점: 어디서도 움직이지 않음 (끝일 수 있음) [\(aimKey)]")
                aimIndex = 0
                scrollPoint = points[0]
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
        for _ in 0..<20 { send(CGVector(dx: 0, dy: toTop ? -5000 : 5000)) }
    }
}

/// 화면에 보이는 일반(레이어 0) 창들, 앞에서 뒤 순서.
struct WindowStack {
    struct Entry {
        let pid: pid_t
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
                  let dict = w[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return Entry(pid: pid, bounds: bounds)
        })
    }

    func topmost(at p: CGPoint) -> Entry? { entries.first { $0.bounds.contains(p) } }
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

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
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
