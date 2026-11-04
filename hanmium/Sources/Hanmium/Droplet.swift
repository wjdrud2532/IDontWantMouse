import AppKit

/// 한 변의 위치를 스프링으로 목표까지 끌고 간다
final class Spring {
    var x: CGFloat
    var v: CGFloat = 0
    var target: CGFloat
    private var k: CGFloat = 300
    private var c: CGFloat = 30

    init(_ x: CGFloat) {
        self.x = x
        target = x
    }

    /// ratio < 1 이면 살짝 지나쳤다 돌아와서 출렁인다
    func set(_ t: CGFloat, stiffness: CGFloat, ratio: CGFloat) {
        target = t
        k = stiffness
        c = 2 * ratio * stiffness.squareRoot()
    }

    func step(_ dt: CGFloat) {
        v += (k * (target - x) - c * v) * dt
        x += v * dt
    }

    var isSettled: Bool { abs(target - x) < 0.5 && abs(v) < 8 }
}

/// 스크롤 모드에서 고른 영역을 옮길 때 테두리를 물방울처럼 옮긴다 (설정 › 영역 이동).
/// 테두리 사각형의 네 변을 스프링 넷으로 따로 움직인다.
final class DropletMotion {
    static let droplet: CGFloat = 34

    let style: FocusMotion
    /// 움직임 애니메이션 배율. 2 면 두 배로 느긋하게.
    private let time: CGFloat
    /// minX, minY, maxX, maxY
    private let edges: [Spring]
    private var target: CGRect
    /// 날아가는 물방울: 0 뭉치기, 1 날아가기, 2 퍼지기
    private var phase = 2
    private var phaseTime: CGFloat = 0

    init(rect: CGRect, style: FocusMotion, timeScale: CGFloat) {
        self.style = style
        time = max(timeScale, 0.1)
        target = rect
        edges = [Spring(rect.minX), Spring(rect.minY), Spring(rect.maxX), Spring(rect.maxY)]
    }

    var rect: CGRect {
        let x0 = min(edges[0].x, edges[2].x), x1 = max(edges[0].x, edges[2].x)
        let y0 = min(edges[1].x, edges[3].x), y1 = max(edges[1].x, edges[3].x)
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 2), height: max(y1 - y0, 2))
    }

    /// 0~1. 빠르게 움직일수록 커서 테두리가 더 둥글고 두꺼워진다.
    var stretch: CGFloat {
        let speed = edges.map { abs($0.v) }.max() ?? 0
        return min(1, speed * time / 1600)
    }

    /// 0~1. 날아가는 물방울에서 테두리가 속이 찬 물방울로 바뀐 정도.
    var lens: CGFloat {
        guard style == .hop else { return 0 }
        let r = rect
        return min(max((Self.droplet * 2.4 - min(r.width, r.height)) / Self.droplet, 0), 1)
    }

    var isSettled: Bool { phase == 2 && edges.allSatisfy(\.isSettled) }

    func move(to r: CGRect) {
        target = r
        switch style {
        case .stretch:
            aim(r, lead: 420, trail: 120)
        case .hop:
            phase = 0
            phaseTime = 0
            let here = rect
            aim(drop(at: CGPoint(x: here.midX, y: here.midY)), stiffness: 520, ratio: 0.85)
        case .none:
            let t = [r.minX, r.minY, r.maxX, r.maxY]
            for i in 0..<4 {
                edges[i].x = t[i]
                edges[i].target = t[i]
                edges[i].v = 0
            }
        }
    }

    func step(_ dt: CGFloat) {
        for _ in 0..<4 { edges.forEach { $0.step(dt / 4) } }
        guard style == .hop else { return }
        phaseTime += dt
        let r = rect
        if phase == 0, phaseTime > 0.16 * time || max(r.width, r.height) < Self.droplet * 1.15 {
            phase = 1
            phaseTime = 0
            aim(drop(at: CGPoint(x: target.midX, y: target.midY)), lead: 300, trail: 110)
        } else if phase == 1, hypot(r.midX - target.midX, r.midY - target.midY) < 14 || phaseTime > 0.9 * time {
            phase = 2
            aim(target, stiffness: 260, ratio: 0.5)
        }
    }

    /// 앞서가는 변(움직이는 쪽)은 빠르고 단단하게, 뒤따르는 변은 느리게 → 가는 동안 늘어난다
    private func aim(_ r: CGRect, lead: CGFloat, trail: CGFloat) {
        let t = [r.minX, r.minY, r.maxX, r.maxY]
        for i in 0..<4 {
            let leading = i < 2 ? t[i] < edges[i].x : t[i] > edges[i].x
            edges[i].set(t[i], stiffness: (leading ? lead : trail) / (time * time), ratio: leading ? 0.62 : 0.9)
        }
    }

    private func aim(_ r: CGRect, stiffness: CGFloat, ratio: CGFloat) {
        let t = [r.minX, r.minY, r.maxX, r.maxY]
        for i in 0..<4 { edges[i].set(t[i], stiffness: stiffness / (time * time), ratio: ratio) }
    }

    private func drop(at p: CGPoint) -> CGRect {
        CGRect(x: p.x - Self.droplet / 2, y: p.y - Self.droplet / 2, width: Self.droplet, height: Self.droplet)
    }
}
