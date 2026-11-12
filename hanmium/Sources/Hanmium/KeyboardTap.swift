import AppKit
import Carbon

/// 키보드 규칙을 실제 키 입력에 적용한다. 시스템 이벤트 탭(HID 단계, 맨 앞)에서 키를 받아 KeyboardEngine 에 묻고,
/// 바꾼 키·마우스 버튼·포인터 이동·휠을 보낸다. 탭은 따로 스레드에서 돌아서 Hanmium 이 바빠도 키 입력이 막히지 않는다.
/// 손쉬운 사용 권한이 있어야 하고, 비밀번호 입력처럼 보안 입력이 켜진 동안에는 시스템이 키를 보여 주지 않아 바뀌지 않는다.
final class KeyboardTap {
    static let shared = KeyboardTap()

    /// {"hanmium": …} 를 받았을 때(메인 스레드)
    var onHanmium: ((String) -> Void)?
    /// 지금 키를 바꾸고 있는지
    private(set) var running = false

    private let engine = KeyboardEngine()
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let mouse = MouseKeys()
    private var front: String?
    /// front 전용. 엔진은 lock 을 쥔 채로 front 를 읽으므로 따로 둔다.
    private let frontLock = NSLock()
    /// 이 표시가 붙은 이벤트는 Hanmium 이 보낸 것이라 다시 바꾸지 않는다
    static let marker: Int64 = 0x484E_4D4B  // 'HNMK'
    private let source = CGEventSource(stateID: .privateState)

    private init() {
        engine.frontmost = { [unowned self] in frontmostID }
        engine.hanmiumAvailable = { action in
            guard Config.enabled, AXIsProcessTrusted() else { return false }
            let kind: ModeKind = action == "search" ? .search : action == "scroll" ? .scroll : .labels
            guard Config.isEnabled(kind) else { return false }
            return Config.isAllowed(KeyboardTap.shared.frontmostID)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.setFront(app?.bundleIdentifier)
        }
        setFront(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func setFront(_ id: String?) {
        frontLock.lock()
        front = id
        frontLock.unlock()
    }

    var frontmostID: String? {
        frontLock.lock()
        defer { frontLock.unlock() }
        return front
    }

    /// 규칙이 바뀌거나 켜고 끌 때(메인 스레드)
    func update(rules: [KeyRule], simple: [SimpleModification], parameters: KeyParameters, enabled: Bool) {
        var compiled = KeyboardEngine.Rules()
        compiled.manipulators = rules.flatMap { $0.manipulators.compactMap { $0 } }
        for s in simple {
            if let from = KeyNames.code(s.from), let to = KeyNames.code(s.to) { compiled.simple[from] = to }
        }
        compiled.aloneTimeout = Double(parameters.aloneTimeout) / 1000
        lock.lock()
        engine.rules = compiled
        lock.unlock()
        mouse.pointerScale = Double(parameters.pointerScale) / 100
        mouse.wheelScale = Double(parameters.wheelScale) / 100
        if enabled { start() } else { stop() }
    }

    // MARK: 탭

    private func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<KeyboardTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.write("키보드 규칙: 키 입력을 받지 못함 (손쉬운 사용 권한을 확인하세요)")
            running = false
            return
        }
        tap = port
        let thread = Thread { [weak self] in
            guard let self, let port = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Hanmium.keyboard"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        running = true
        Log.write("키보드 규칙 켬: 조작 \(engine.rules.manipulators.count)개, 단순 바꾸기 \(engine.rules.simple.count)개")
    }

    private func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
        running = false
        lock.lock()
        engine.reset()
        lock.unlock()
        mouse.stopAll()
        Log.write("키보드 규칙 끔")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 시스템이 탭을 껐다(콜백이 늦었거나 보안 입력). 그사이 놓친 키가 있을 수 있어 누르던 상태를 비운다.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            lock.lock()
            engine.reset()
            lock.unlock()
            mouse.stopAll()
            Log.write("키보드 규칙: 시스템이 탭을 꺼서 다시 켬 (\(type == .tapDisabledByTimeout ? "시간 초과" : "사용자 입력"))")
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let time = Double(event.timestamp) / 1_000_000_000
        let outputs: [KeyboardEngine.Output]
        lock.lock()
        switch type {
        case .keyDown:
            outputs = engine.keyDown(code, flags: event.flags,
                                     isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, time: time)
        case .keyUp:
            outputs = engine.keyUp(code, flags: event.flags, time: time)
        case .flagsChanged:
            outputs = engine.flagsChanged(event.flags)
        default:
            engine.interrupt()
            outputs = [.pass]
        }
        lock.unlock()
        if outputs == [.pass] { return Unmanaged.passUnretained(event) }
        perform(outputs)
        return nil
    }

    private func perform(_ outputs: [KeyboardEngine.Output]) {
        for o in outputs {
            switch o {
            case .pass:
                break
            case let .key(code, down, flags, isRepeat):
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
                e.flags = flags
                if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
                post(e)
            case let .button(n, down, flags):
                mouse.button(n, down: down, flags: flags)
            case let .motionStart(id, vector, flags):
                mouse.start(id, vector, flags: flags)
            case let .motionStop(id):
                mouse.stop(id)
            case let .hanmium(action):
                DispatchQueue.main.async { [weak self] in self?.onHanmium?(action) }
            }
        }
    }

    fileprivate func post(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - 마우스 키 (mouse_key·pointing_button)

/// mouse_key 를 누르고 있는 동안 포인터를 옮기고 휠을 돌린다. Karabiner 의 x·y 1536 을 기본 속도(초당 1000pt)로,
/// 휠 48 을 초당 1000pt 로 본다(설정의 포인터·휠 속도 %로 바꾼다). 처음 0.15초는 천천히 출발해서 조금씩 옮기기 쉽게 한다.
final class MouseKeys {
    var pointerScale = 1.0
    var wheelScale = 1.0

    private let queue = DispatchQueue(label: "Hanmium.mousekeys", qos: .userInteractive)
    private var vectors: [Int: (vector: MouseKeyVector, since: Double, flags: CGEventFlags)] = [:]
    private var timer: DispatchSourceTimer?
    private var buttonsDown = Set<Int>()
    private var wheelRemainder = CGVector.zero
    private var lastTick: Double = 0
    private var lastClick: (button: Int, time: Double, at: CGPoint, count: Int)?

    func start(_ id: Int, _ v: MouseKeyVector, flags: CGEventFlags) {
        queue.async { [self] in
            vectors[id] = (v, CACurrentMediaTime(), flags)
            if timer == nil {
                lastTick = CACurrentMediaTime()
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
        }
    }

    func stop(_ id: Int) {
        queue.async { [self] in
            vectors.removeValue(forKey: id)
            if vectors.isEmpty { halt() }
        }
    }

    func stopAll() {
        queue.async { [self] in
            vectors.removeAll()
            halt()
            for n in buttonsDown { post(button: n, down: false, flags: []) }
            buttonsDown.removeAll()
        }
    }

    private func halt() {
        timer?.cancel()
        timer = nil
        wheelRemainder = .zero
    }

    func button(_ n: Int, down: Bool, flags: CGEventFlags) {
        queue.async { [self] in
            if down { buttonsDown.insert(n) } else { buttonsDown.remove(n) }
            post(button: n, down: down, flags: flags)
        }
    }

    private static func location() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func post(button n: Int, down: Bool, flags: CGEventFlags) {
        let p = Self.location()
        let type: CGEventType = switch n {
        case 1: down ? .leftMouseDown : .leftMouseUp
        case 2: down ? .rightMouseDown : .rightMouseUp
        default: down ? .otherMouseDown : .otherMouseUp
        }
        let cgButton = CGMouseButton(rawValue: UInt32(n - 1)) ?? .center
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton)
        else { return }
        // 빨리 다시 누르면 더블클릭(시스템 설정의 간격·같은 자리)
        let now = CACurrentMediaTime()
        if down {
            var count = 1
            if let c = lastClick, c.button == n, now - c.time < NSEvent.doubleClickInterval,
               hypot(c.at.x - p.x, c.at.y - p.y) < 5 { count = c.count + 1 }
            lastClick = (n, now, p, count)
        }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(lastClick?.count ?? 1))
        e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(n - 1))
        e.flags = flags
        KeyboardTap.shared.post(e)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 0), 0.05)
        lastTick = now
        var move = CGVector.zero, wheel = CGVector.zero
        var flags: CGEventFlags = []
        for (_, item) in vectors {
            let v = item.vector
            let k = v.speedMultiplier ?? 1
            // 처음 0.15초는 35% 에서 100% 까지 올린다
            let ramp = min(1, 0.35 + 0.65 * (now - item.since) / 0.15)
            move.dx += (v.x ?? 0) / 1536 * 1000 * pointerScale * k * ramp
            move.dy += (v.y ?? 0) / 1536 * 1000 * pointerScale * k * ramp
            wheel.dy += (v.verticalWheel ?? 0) / 48 * 1000 * wheelScale * k
            wheel.dx += (v.horizontalWheel ?? 0) / 48 * 1000 * wheelScale * k
            flags = item.flags
        }
        if move != .zero { moveCursor(by: CGVector(dx: move.dx * dt, dy: move.dy * dt), flags: flags) }
        if wheel != .zero {
            wheelRemainder.dx += wheel.dx * dt
            wheelRemainder.dy += wheel.dy * dt
            let step = CGVector(dx: wheelRemainder.dx.rounded(.towardZero), dy: wheelRemainder.dy.rounded(.towardZero))
            if step != .zero {
                wheelRemainder.dx -= step.dx
                wheelRemainder.dy -= step.dy
                // vertical_wheel 이 양수면 아래(Mouse.scroll 과 같은 방향)
                if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(-step.dy), wheel2: Int32(-step.dx), wheel3: 0) {
                    e.location = Self.location()
                    KeyboardTap.shared.post(e)
                }
            }
        }
    }

    private var cursorRemainder = CGVector.zero

    private func moveCursor(by d: CGVector, flags: CGEventFlags) {
        cursorRemainder.dx += d.dx
        cursorRemainder.dy += d.dy
        let step = CGVector(dx: cursorRemainder.dx.rounded(.towardZero), dy: cursorRemainder.dy.rounded(.towardZero))
        guard step != .zero else { return }
        cursorRemainder.dx -= step.dx
        cursorRemainder.dy -= step.dy
        var p = Self.location()
        p.x += step.dx
        p.y += step.dy
        p = Self.clamp(p)
        // 버튼을 누르고 있으면 끌기
        let (type, button): (CGEventType, CGMouseButton) =
            buttonsDown.contains(1) ? (.leftMouseDragged, .left)
            : buttonsDown.contains(2) ? (.rightMouseDragged, .right)
            : buttonsDown.isEmpty ? (.mouseMoved, .left) : (.otherMouseDragged, .center)
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(step.dx))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(step.dy))
        e.flags = flags
        KeyboardTap.shared.post(e)
    }

    /// 화면 밖으로 나가지 않게
    private static func clamp(_ p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let rects = ids.map { CGDisplayBounds($0) }
        if rects.contains(where: { $0.contains(p) }) { return p }
        // 가장 가까운 화면 안으로
        guard let nearest = rects.min(by: { distance(p, $0) < distance(p, $1) }) else { return p }
        return CGPoint(x: min(max(p.x, nearest.minX), nearest.maxX - 1), y: min(max(p.y, nearest.minY), nearest.maxY - 1))
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}
