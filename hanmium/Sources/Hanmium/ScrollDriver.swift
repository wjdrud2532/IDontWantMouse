import AppKit
import QuartzCore

/// 스크롤 모드에서 누르고 있는 키대로 움직임을 계산해 휠 이벤트로 보낸다.
///
/// 화면 새로 고침(디스플레이 링크)마다 한 번, 메인 스레드가 아닌 전용 스레드에서 보낸다. 메인 스레드는 유리 테두리를
/// 다시 그리느라 바쁠 때가 있어서 거기서 타이머를 돌리면 보내는 간격이 흔들리고, 화면과 다른 빈도(120Hz 타이머를 75Hz
/// 화면에)로 보내면 프레임마다 이벤트가 한 번·두 번씩 섞여 들어가 덜컹인다. 이동량은 그 프레임이 화면에 나올 시각으로 계산한다.
///
/// 메인 스레드는 키를 누르고 뗄 때 hold/page/release 를, 휠 보낼 곳이 바뀌면 setAim 을 부른다.
final class ScrollDriver: NSObject {
    /// 휠을 보낼 곳. target 이 nil 이면 커서 위치로 보낸다(부르는 쪽이 커서를 point 로 옮겨 둔다).
    struct Aim {
        var target: Mouse.Target?
        var point: CGPoint
    }

    /// 보낸 양(터미널은 칸으로 모으기 전)과, check 로 걸어 둔 확인을 시작했으면 보내기 직전에 읽은 표지 값과 그 표시.
    /// 메인 스레드에서 부른다.
    var onSend: ((CGVector, (values: [CGFloat?], tag: Int)?) -> Void)?

    private let screen: NSScreen
    /// WezTerm 처럼 휠 이벤트 하나를 한 칸으로 받는 앱이면 이만큼(px)씩 모아서 보낸다
    private let notch: CGFloat?
    /// 가속·감속 시간 상수(ms), 설정의 애니메이션 배율을 곱한다(0 이면 즉시)
    private let accelTau = 80.0 * Config.animationScale
    private let decelTau = 60.0 * Config.animationScale
    /// d/u 반 페이지 이동 시간. 너무 짧으면 몇 프레임 만에 건너뛰어 끊겨 보이므로 애니메이션을 켰으면 0.12초보다 줄이지 않는다.
    private let glideDuration: CFTimeInterval = Config.animationScale > 0 ? max(0.25 * Config.animationScale, 0.12) : 0
    /// d/u 를 이만큼 넘게 누르고 있으면 반 페이지에 이어 계속 스크롤한다
    private static let holdDelay = 0.12
    private let pxPerMs = Config.scrollPxPerMs
    private let dashMultiplier = Config.dashMultiplier

    // 아래는 lock 으로 지킨다 (메인 스레드의 키 입력과 스크롤 스레드의 프레임이 함께 쓴다)
    private let lock = NSLock()
    private var aim = Aim(target: nil, point: .zero)
    /// 다음 세로 스크롤을 보내기 직전에 읽을 표지 (휠 보낼 지점이 맞는지 확인을 시작할 때)
    private var pendingCheck: (probe: ScrollProbe, tag: Int)?
    /// 누르고 있는 키 → 목표 속도(기본 속도의 배수와 방향)
    private var held: [UInt16: CGVector] = [:]
    /// 누르고 있는 키 → 몇 번째 누름인지. 손을 뗐다 다시 누른 것과 계속 누른 것을 가른다.
    private var down: [UInt16: Int] = [:]
    private var pressCount = 0
    /// 지금 속도(px/ms). 목표 속도로 바로 바뀌지 않고 부드럽게 따라간다.
    private var velocity = CGVector.zero
    private var carry = CGVector.zero
    /// d/u 처럼 정해진 거리를 나눠 보내는 중인 스크롤. sent 는 지금까지 보낸 정수 픽셀.
    /// start 는 처음 맞는 프레임에서 정한다: 누른 시각으로 하면 첫 프레임이 한 프레임 넘게 몰아서 가 튄다.
    private var glide: (total: CGVector, sent: CGVector, start: CFTimeInterval?)?
    /// 반 페이지를 시작한 d/u 누름. 계속 누르고 있으면 계속 스크롤(continuous)로 넘긴다.
    private var paging: (key: UInt16, press: Int, start: CFTimeInterval, continuous: CGVector)?
    private var notchCarry = CGVector.zero
    private var lastTime: CFTimeInterval = 0
    private var running = false
    private var stopped = false

    // 스크롤 스레드에서만 쓴다
    private var link: AnyObject?
    private var fallbackTimer: Timer?

    init(screen: NSScreen, notch: CGFloat?) {
        self.screen = screen
        self.notch = notch
    }

    /// 프레임을 받는 스레드. 앱이 도는 동안 하나를 같이 쓴다.
    private static let thread: Thread = {
        let t = Thread {
            // 할 일이 없어도 run loop 가 끝나지 않게 포트를 붙여 둔다
            RunLoop.current.add(NSMachPort(), forMode: .default)
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        t.name = "Hanmium 스크롤"
        t.qualityOfService = .userInteractive
        t.start()
        return t
    }()

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        perform(#selector(finish), on: Self.thread, with: nil, waitUntilDone: false)
    }

    func setAim(_ aim: Aim) {
        lock.lock()
        self.aim = aim
        lock.unlock()
    }

    /// 다음 세로 스크롤 직전에 probe 를 읽고 onSend 로 넘기게 한다. nil 이면 걸어 둔 것을 지운다.
    func check(_ probe: ScrollProbe?, tag: Int) {
        lock.lock()
        pendingCheck = probe.map { ($0, tag) }
        lock.unlock()
    }

    /// 방향키·hjkl: 누르고 있는 동안 dir(기본 속도의 배수와 방향)으로 스크롤
    func hold(_ key: UInt16, _ dir: CGVector) {
        lock.lock()
        held[key] = dir
        press(key)
        lock.unlock()
        resume()
    }

    /// d/u: by 만큼 부드럽게 옮긴다. 아직 다 가지 않았는데 또 누르면 남은 거리에 더해 다시 시작한다.
    /// 짧게 치면 그 거리만, 계속 누르고 있으면 반 페이지 이동이 느려지기 전에 지금 속도를 이어받아 continuous 로 계속 간다.
    func page(_ key: UInt16, by: CGVector, continuous: CGVector) {
        let now = CACurrentMediaTime()
        lock.lock()
        var total = by
        if let g = glide {
            total.dx += g.total.dx - g.sent.dx
            total.dy += g.total.dy - g.sent.dy
        }
        glide = (total, .zero, nil)
        paging = (key, press(key), now, continuous)
        lock.unlock()
        resume()
    }

    func release(_ key: UInt16) {
        lock.lock()
        held.removeValue(forKey: key)
        down.removeValue(forKey: key)
        lock.unlock()
    }

    /// 지금 바로 by 만큼 보낸다 (gg/G 처럼 한 번에 크게)
    func post(_ by: CGVector) {
        send(by)
    }

    @discardableResult
    private func press(_ key: UInt16) -> Int {
        pressCount += 1
        down[key] = pressCount
        return pressCount
    }

    // MARK: - 프레임

    private func resume() {
        lock.lock()
        let start = !running && !stopped
        if start { running = true }
        lock.unlock()
        if start { perform(#selector(startFrames), on: Self.thread, with: nil, waitUntilDone: false) }
    }

    @objc private func startFrames() {
        if #available(macOS 14.0, *) {
            if let link = link as? CADisplayLink {
                guard link.isPaused else { return }
                begin()
                link.isPaused = false
            } else {
                begin()
                let l = screen.displayLink(target: self, selector: #selector(frame(_:)))
                l.add(to: .current, forMode: .default)
                link = l
            }
        } else if fallbackTimer == nil {
            begin()
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [unowned self] _ in
                advance(to: CACurrentMediaTime(), frame: 1.0 / 120, sendAt: nil)
            }
            RunLoop.current.add(t, forMode: .default)
            fallbackTimer = t
        }
    }

    private func begin() {
        lock.lock()
        lastTime = 0
        carry = .zero
        lock.unlock()
    }

    /// 디스플레이 링크는 vsync 바로 뒤에 불리는데, 앱(Chrome 등)도 그때 입력을 모아 프레임을 시작한다. 그 순간에 보내면
    /// 이번 프레임에 들어갈지 다음으로 밀릴지가 매번 달라 0 과 두 배가 번갈아 나온다. 프레임 가운데쯤에 보낸다.
    @available(macOS 14.0, *)
    @objc private func frame(_ link: CADisplayLink) {
        let duration = link.targetTimestamp - link.timestamp
        advance(to: link.targetTimestamp, frame: duration, sendAt: link.timestamp + duration / 2)
    }

    /// 움직임이 멎으면 프레임을 그만 받는다
    private func idle() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.isPaused = true }
    }

    /// 모드를 닫을 때: 디스플레이 링크를 놓아준다
    @objc private func finish() {
        idle()
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
    }

    /// now: 이번 프레임이 화면에 나올 시각, frame: 프레임 길이(초), sendAt: 이벤트를 보낼 시각
    private func advance(to now: CFTimeInterval, frame: CFTimeInterval, sendAt: CFTimeInterval?) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return finish()
        }
        let step = motion(at: now, frame: frame)
        let idle = held.isEmpty && glide == nil && paging == nil && velocity == .zero
        if idle { running = false }
        lock.unlock()
        if step.dx != 0 || step.dy != 0 {
            if let sendAt, case let wait = sendAt - CACurrentMediaTime(), wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
            send(step)
        }
        if idle { self.idle() }
    }

    /// 이번 프레임에 보낼 정수 픽셀 (lock 안에서)
    private func motion(at now: CFTimeInterval, frame: CFTimeInterval) -> CGVector {
        // 멈췄다 다시 시작한 첫 프레임은 한 프레임만큼 움직인다
        let dtMs = (lastTime == 0 ? frame : min(max(now - lastTime, 0), 0.05)) * 1000
        lastTime = now
        if glide != nil, glide?.start == nil { glide?.start = now - frame }
        let shift = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        let speed = pxPerMs * (shift ? dashMultiplier : 1)

        // d/u 를 아직 누르고 있으면: holdDelay 가 지났거나, 반 페이지를 반 넘게 가서 계속 스크롤 속도보다 느려지려 하면
        // 반 페이지 이동의 지금 속도를 그대로 이어받아 계속 스크롤로 넘긴다. 다 멈춘 뒤에 출발하면 한 번 끊겼다 가게 된다.
        if let p = paging {
            if down[p.key] != p.press {
                paging = nil
            } else {
                var glideVelocity = CGVector.zero
                var slowing = false
                if let g = glide, let start = g.start, glideDuration > 0 {
                    let progress = min(1, (now - start) / glideDuration)
                    let k = 2 * (1 - progress) / (glideDuration * 1000)
                    glideVelocity = CGVector(dx: g.total.dx * k, dy: g.total.dy * k)
                    slowing = progress >= 0.5
                        && hypot(glideVelocity.dx, glideVelocity.dy) <= hypot(p.continuous.dx, p.continuous.dy) * speed
                }
                if slowing || now - p.start >= Self.holdDelay {
                    velocity.dx += glideVelocity.dx
                    velocity.dy += glideVelocity.dy
                    held[p.key] = p.continuous
                    glide = nil
                    paging = nil
                }
            }
        }

        // 누르고 있는 키들의 목표 속도. 지금 속도는 거기로 지수적으로 다가간다(멈출 때는 조금 더 빨리).
        var target = CGVector.zero
        for d in held.values {
            target.dx += d.dx
            target.dy += d.dy
        }
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
        // 휠 이벤트는 정수 픽셀이라 소수점은 다음 프레임으로 넘긴다
        var step = CGVector(dx: carry.dx.rounded(.towardZero), dy: carry.dy.rounded(.towardZero))
        carry.dx -= step.dx
        carry.dy -= step.dy

        // d/u: ease-out 곡선을 따라 이번 프레임까지 가야 할 만큼
        if var g = glide, let start = g.start {
            let p = glideDuration > 0 ? min(1, (now - start) / glideDuration) : 1
            let eased = 1 - pow(1 - p, 2)
            let due = CGVector(dx: (g.total.dx * eased).rounded(.towardZero),
                               dy: (g.total.dy * eased).rounded(.towardZero))
            step.dx += due.dx - g.sent.dx
            step.dy += due.dy - g.sent.dy
            g.sent = due
            glide = p < 1 ? g : nil
        }
        return step
    }

    // MARK: - 보내기

    private func send(_ by: CGVector) {
        lock.lock()
        let aim = self.aim
        var check: (probe: ScrollProbe, tag: Int)?
        if by.dx == 0, by.dy != 0 {
            check = pendingCheck
            pendingCheck = nil
        }
        var events = [by]
        if let notch {
            // WezTerm 은 전체 화면 앱(Claude Code, vim 등)에 휠 이벤트 하나를 크기와 상관없이 한 칸으로 넘긴다.
            // 픽셀을 모았다가 설정한 줄 수(15px × N)씩, 한 칸씩 따로 보내야 칸 수만큼 움직인다.
            notchCarry.dx += by.dx
            notchCarry.dy += by.dy
            let nx = Int((notchCarry.dx / notch).rounded(.towardZero))
            let ny = Int((notchCarry.dy / notch).rounded(.towardZero))
            notchCarry.dx -= CGFloat(nx) * notch
            notchCarry.dy -= CGFloat(ny) * notch
            events = Array(repeating: CGVector(dx: 0, dy: ny > 0 ? notch : -notch), count: abs(ny))
                + Array(repeating: CGVector(dx: nx > 0 ? notch : -notch, dy: 0), count: abs(nx))
        }
        lock.unlock()
        // 확인은 보내기 전 값과 비교하므로 먼저 읽는다
        let before = check.map { (values: $0.probe.read(), tag: $0.tag) }
        for e in events {
            if let target = aim.target, Mouse.scroll(by: e, at: aim.point, to: target) { continue }
            Mouse.scroll(by: e, at: aim.point)
        }
        DispatchQueue.main.async { [weak self] in self?.onSend?(by, before) }
    }
}
