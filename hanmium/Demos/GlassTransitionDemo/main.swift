import AppKit

// 스크롤 모드에서 다른 영역으로 옮길 때 고르지 않은 영역 유리판의 굴절을 비교하는 예시.
// Hanmium 의 유리 그리기 코드(GlassSource·Draw)와 물방울 움직임(DropletMotion)을 그대로 쓴다.
//
//   왼쪽  지금: 떠난 영역에는 다 만들어진 유리판이 바로 생기고, 갈 영역의 유리판은 바로 사라진다(결과만).
//   오른쪽 틀 모양 그대로: 유리판 = 영역 − 움직이는 테두리(바깥 유리 막대까지). 매 장면 그 모양의 가장자리를
//          새로 구해 굴절시킨다. 테두리가 빠져나가는 자리에는 테두리 모양 그대로 유리가 차오르고,
//          들어가는 영역은 테두리 모양대로 파인다. 앱에 들어간 코드(ScrollMode.paint 와 같은 순서,
//          Draw.carvedGlassArea)를 그대로 쓴다. 유리판이 없는 틈·위쪽(배경화면 자리)도 테두리 둘레가 휜다
//          (Draw.carvedBackground). 멈춘 뒤에도 테두리 둘레는 휜 채로 남는다.
//
// 1~4·Tab: 영역 이동  Space: 자동 재생  Esc: 닫기
//   --frame <n> <png>  창 없이, 영역 2 → 4 로 옮기기 시작해 n 장면 뒤를 그린다(확인용)

// MARK: 예시 화면

enum Style {
    case now, shaped

    var title: String {
        switch self {
        case .now: "지금 Hanmium — 결과만 바로"
        case .shaped: "틀 모양 그대로 실시간 굴절"
        }
    }
}

final class PaneDemo: NSView {
    let style: Style
    private(set) var panes: [CGRect] = []
    private(set) var selected = 1
    private var motion: DropletMotion
    private var background: CGImage?
    private var source: GlassSource?

    init(frame: NSRect, style: Style) {
        self.style = style
        let w = frame.width, h = frame.height, top: CGFloat = 30, mid = (216 + w - 6) / 2
        panes = [
            CGRect(x: 8, y: top, width: 202, height: h - top - 8),
            CGRect(x: 218, y: top, width: w - 226, height: 170),
            CGRect(x: 218, y: top + 178, width: mid - 222, height: h - top - 186),
            CGRect(x: mid + 4, y: top + 178, width: w - mid - 12, height: h - top - 186),
        ]
        motion = DropletMotion(rect: panes[1], style: .stretch, timeScale: 1 / Config.focusMotionSpeed)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: 배경 (가짜 4분할 화면) — 유리가 굴절시킬 "화면 사진"

    func prepare(scale: CGFloat) {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawMock()
        NSGraphicsContext.restoreGraphicsState()
        background = ctx.makeImage()
        if let background, let snap = ScreenSnapshot(image: background, axFrame: bounds) {
            source = GlassSource(snap)
        }
    }

    private func drawMock() {
        // 배경화면: 영역 사이 틈·위쪽 띠에서 테두리 둘레가 휘는 것이 보이게 사선 줄무늬
        NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.12, blue: 0.30, alpha: 1),
                            NSColor(srgbRed: 0.05, green: 0.25, blue: 0.32, alpha: 1)])?.draw(in: bounds, angle: 20)
        NSColor(white: 1, alpha: 0.18).setStroke()
        for x in stride(from: -bounds.height, to: bounds.width, by: 14) {
            let stripe = NSBezierPath()
            stripe.move(to: CGPoint(x: x, y: 0))
            stripe.line(to: CGPoint(x: x + bounds.height, y: bounds.height))
            stripe.lineWidth = 3
            stripe.stroke()
        }
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        func line(_ s: String, _ c: NSColor, _ p: CGPoint, font: NSFont = mono) {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c]).draw(at: p)
        }
        // 1: 밝은 문서
        let doc = panes[0]
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1).setFill()
        doc.fill()
        line("Liquid Glass 메모", .black, CGPoint(x: doc.minX + 10, y: doc.minY + 10), font: .boldSystemFont(ofSize: 15))
        let words = ["유리는 뒤 화면을 굴절시키고", "가장자리에서 빛을 받는다.", "스넬 법칙 n₁sinθ₁ = n₂sinθ₂",
                     "볼록 단면", "https://kube.io/blog", "물방울처럼 늘어났다가", "출렁이며 멈춘다."]
        for (i, wd) in (words + words + words).enumerated() {
            line(wd, i % 4 == 3 ? .systemBlue : NSColor(white: 0.25, alpha: 1),
                 CGPoint(x: doc.minX + 10, y: doc.minY + 38 + CGFloat(i) * 18), font: .systemFont(ofSize: 12))
        }
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: CGRect(x: doc.minX + 110, y: doc.maxY - 110, width: 80, height: 80)).fill()
        // 2: 코드
        let code = panes[1]
        let palette: [NSColor] = [.systemPink, .systemGreen, .systemYellow, .systemBlue, .white, .systemPurple]
        for i in 0..<11 {
            line("func render(_ items: [Item]) -> some View { ForEach(items) { Text($0) } }",
                 palette[i % palette.count], CGPoint(x: code.minX + 8, y: code.minY + 6 + CGFloat(i) * 15))
        }
        NSColor.systemPurple.setFill()
        NSBezierPath(ovalIn: CGRect(x: code.maxX - 90, y: code.minY + 30, width: 70, height: 70)).fill()
        // 3, 4: 터미널
        for (n, p) in panes[2...].enumerated() {
            for i in 0..<10 {
                let ok = (i + n) % 3 != 0
                line(ok ? "✓ test_glass_\(i) passed (\(i * 7 + 3)ms)" : "✗ test_drop_\(i) failed",
                     ok ? .systemGreen : .systemRed, CGPoint(x: p.minX + 8, y: p.minY + 6 + CGFloat(i) * 15))
            }
            NSGradient(colors: [.systemTeal, .systemIndigo, .systemPink])?
                .draw(in: CGRect(x: p.minX + 8, y: p.maxY - 22, width: p.width - 16, height: 10), angle: 0)
        }
    }

    // MARK: 움직임

    func select(_ i: Int) {
        guard i != selected, panes.indices.contains(i) else { return }
        selected = i
        motion.move(to: panes[i])
    }

    func step(_ dt: CGFloat) { motion.step(dt) }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        guard let background, let source else { return }
        NSImage(cgImage: background, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1,
                                                              respectFlipped: true, hints: nil)
        Draw.glassSource = source
        let color = Config.inactiveAreaColor, fill = Config.inactiveFillOpacity
        let blob = motion.rect
        let band = Draw.ringBand(Config.scrollBorderWidth)
        for (i, p) in panes.enumerated() {
            let bezel = Draw.slabBezel(for: p)
            switch style {
            case .now:
                // 지금 Hanmium(ScrollMode.paint): 고른 영역이 아닌 곳에 다 된 유리판, 가장자리는 한 번 그려 둔 것
                guard i != selected else { continue }
                Draw.glassArea(p, selected: panes[selected], color: color, fillOpacity: fill,
                               edge: Draw.glassAreaEdge(p, color: color, fillOpacity: fill))
            case .shaped:
                // ScrollMode.paint 와 같다: 유리판 = 영역 − 테두리 모양. 멈춘 뒤에도 테두리 둘레는 휜 채로 남는다.
                let hole = Draw.ringOuter(blob, band: band, stretch: motion.stretch, lens: motion.lens)
                if i == 0 {
                    Draw.draw(Draw.carvedBackground(bounds, hole: hole.rect, holeRadius: hole.radius, excluding: panes))
                }
                if hole.rect.contains(p) { continue }
                if hole.rect.insetBy(dx: -bezel, dy: -bezel).intersects(p),
                   let carved = Draw.carvedGlassArea(p, hole: hole.rect, holeRadius: hole.radius, color: color,
                                                     fillOpacity: fill) {
                    Draw.draw([carved])
                    continue
                }
                if i == selected { continue }
                Draw.glassArea(p, selected: motion.isSettled ? panes[selected] : .zero, color: color, fillOpacity: fill,
                               edge: Draw.glassAreaEdge(p, color: color, fillOpacity: fill))
            }
        }
        Draw.glassRing(blob, color: Config.scrollBorderColor, band: band, stretch: motion.stretch, lens: motion.lens,
                       moving: !motion.isSettled, shadow: motion.activity)
        for (i, p) in panes.enumerated() {
            Draw.pill("\(i + 1)", typedCount: i == selected ? 0 : 1, center: CGPoint(x: p.minX + 14, y: p.minY + 12),
                      within: bounds)
        }
        Draw.glassSource = nil
        let title = NSAttributedString(string: style.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        title.draw(at: CGPoint(x: 10, y: 7))
    }
}

/// 왼쪽(지금)과 오른쪽(틀 모양 그대로)을 나란히 두고 같은 순서로 움직인다
final class CompareView: NSView {
    let left: PaneDemo
    let right: PaneDemo
    var autoplay = true
    private var autoTime: CGFloat = 0
    private var timer: Timer?
    private let sequence = [3, 0, 2, 1]
    private var selected = 1

    override init(frame: NSRect) {
        let half = NSRect(x: 0, y: 0, width: (frame.width - 10) / 2, height: frame.height - 30)
        left = PaneDemo(frame: half, style: .now)
        right = PaneDemo(frame: half.offsetBy(dx: half.width + 10, dy: 0), style: .shaped)
        super.init(frame: frame)
        addSubview(left)
        addSubview(right)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func prepare(scale: CGFloat) {
        left.prepare(scale: scale)
        right.prepare(scale: scale)
    }

    func select(_ i: Int) {
        selected = i
        autoTime = 0
        left.select(i)
        right.select(i)
    }

    func step(_ dt: CGFloat) {
        left.step(dt)
        right.step(dt)
        if autoplay {
            autoTime += dt
            if autoTime > 1.8, let at = sequence.firstIndex(of: selected) {
                select(sequence[(at + 1) % sequence.count])
            }
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            step(1.0 / 60)
            left.needsDisplay = true
            right.needsDisplay = true
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.06, alpha: 1).setFill()
        bounds.fill()
        let text = "1–4·Tab 영역 이동   Space 자동 재생 \(autoplay ? "끄기" : "켜기")   Esc 닫기"
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                              .foregroundColor: NSColor(white: 0.8, alpha: 1)])
        s.draw(at: CGPoint(x: (bounds.width - s.size().width) / 2, y: bounds.height - 22))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 18, 19, 20, 21: select(Int(event.keyCode) - 18)
        case 48: select((selected + 1) % 4)
        case 49: autoplay.toggle()
        case 53: NSApp.terminate(nil)
        default: super.keyDown(with: event)
        }
    }
}

let size = CGSize(width: 1290, height: 440)
let args = CommandLine.arguments

// --frame <n> <png>: 영역 2 → 4 로 옮기기 시작해 n 장면 뒤를 2배 크기로 한 장
if let i = args.firstIndex(of: "--frame"), i + 2 < args.count {
    _ = NSApplication.shared
    let view = CompareView(frame: NSRect(origin: .zero, size: size))
    view.autoplay = false
    view.prepare(scale: 2)
    view.select(3)
    for _ in 0..<(Int(args[i + 1]) ?? 0) { view.step(1.0 / 60) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 2]))
    exit(0)
}

final class DemoDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = DemoDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
appItem.submenu?.addItem(withTitle: "닫기", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
app.mainMenu = menu
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = "Hanmium · 유리판 굴절 비교"
let view = CompareView(frame: NSRect(origin: .zero, size: size))
window.contentView = view
window.center()
view.prepare(scale: window.backingScaleFactor)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
view.start()
app.run()
