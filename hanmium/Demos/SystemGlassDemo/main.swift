import AppKit

// 스크롤 모드를 시스템 리퀴드 글래스(NSGlassEffectView)로 그리면 어떻게 보이는지 지금 Hanmium 과 나란히 비교하는 예시.
//   왼쪽  지금 Hanmium: 화면을 찍어 굴절을 직접 계산한다(화면 기록 권한). 앱 코드(ScrollMode.paint 와 같은 순서)를 그대로 쓴다.
//   오른쪽 시스템 유리: 고른 영역 테두리는 유리 막대 네 개, 고르지 않은 영역은 유리판 한 장씩. 모두 한
//          NSGlassEffectContainerView 안에 있어서 가까워지면 시스템이 녹여 붙인다. 뒤 화면은 시스템이 섞어 그리므로
//          화면 기록 권한이 필요 없다. 테두리는 왼쪽과 같은 물방울 움직임(DropletMotion)을 따라간다.
// 두 쪽 모두 같은 가짜 화면(문서·코드·터미널 두 개) 위에 그린다.
//
// 1~4·Tab: 영역 이동  Space: 자동 재생  C: 시스템 유리 맑게(clear) ↔ 보통(regular)
// B: 시스템 테두리 굵기 지금과 같게 ↔ 굵게  T: 시스템 유리 색 입히기 켜고 끄기  S: 고르지 않은 영역 유리판 켜고 끄기
// Esc: 닫기
// 시스템 유리는 가운데가 빈 고리 모양을 만들 수 없다(가림막 layer.mask 를 무시하고 사각형 전체가 유리가 된다).
// 그래서 테두리는 막대 네 개이고, 물방울처럼 둥글게 늘어나는 모양은 따라 하지 못한다.
//   --shot <폴더>  다른 창 뒤에 창을 띄워 몇 장면을 screencapture 로 찍고 끝난다(확인용)

// MARK: 왼쪽: 지금 Hanmium (GlassTransitionDemo 의 '틀 모양 그대로' 와 같다)

final class PaneDemo: NSView {
    private(set) var panes: [CGRect] = []
    private(set) var selected = 1
    private(set) var motion: DropletMotion
    private(set) var background: CGImage?
    private var source: GlassSource?

    override init(frame: NSRect) {
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
        Draw.glassRing(blob, color: Config.scrollBorderColor, band: band, stretch: motion.stretch, lens: motion.lens,
                       moving: !motion.isSettled, shadow: motion.activity)
        for (i, p) in panes.enumerated() {
            Draw.numberBadge("\(i + 1)", dim: i != selected, center: CGPoint(x: p.minX + 14, y: p.minY + 12), within: bounds)
        }
        Draw.glassSource = nil
        let title = NSAttributedString(string: "지금 Hanmium — 직접 굴절 (화면 기록 필요)", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        title.draw(at: CGPoint(x: 10, y: 7))
    }
}

// MARK: 오른쪽: 시스템 유리

/// 뒤집힌 좌표(위가 0)의 빈 보기
class Flip: NSView {
    override var isFlipped: Bool { true }
}

/// 가짜 화면 그림만 그린다
final class ImageBack: Flip {
    var image: CGImage?
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1,
                                                        respectFlipped: true, hints: nil)
    }
}

/// 번호와 제목 (유리 위에)
final class SystemLabels: Flip {
    var panes: [CGRect] = []
    var selected = 1
    var title = ""
    override func draw(_ dirtyRect: NSRect) {
        for (i, p) in panes.enumerated() {
            Draw.numberBadge("\(i + 1)", dim: i != selected, center: CGPoint(x: p.minX + 14, y: p.minY + 12), within: bounds)
        }
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]).draw(at: CGPoint(x: 10, y: 7))
    }
}

final class SystemGlassPane: Flip {
    let panes: [CGRect]
    private(set) var selected = 1
    private var motion: DropletMotion
    private let back = ImageBack()
    private let container = NSGlassEffectContainerView()
    private let content = Flip()
    private var slabs: [NSGlassEffectView] = []
    private var bars: [NSGlassEffectView] = []

    private let labels = SystemLabels()
    var style: NSGlassEffectView.Style = .clear { didSet { (slabs + bars).forEach { $0.style = style }; updateTitle() } }
    var thick = false { didSet { layoutGlass(); updateTitle() } }
    var tinted = true { didSet { applyTint(); updateTitle() } }

    init(frame: NSRect, panes: [CGRect], background: CGImage?) {
        self.panes = panes
        motion = DropletMotion(rect: panes[1], style: .stretch, timeScale: 1 / Config.focusMotionSpeed)
        super.init(frame: frame)
        back.frame = bounds
        back.image = background
        addSubview(back)
        container.frame = bounds
        content.frame = bounds
        container.contentView = content
        container.spacing = 12
        addSubview(container)
        for p in panes {
            let g = NSGlassEffectView(frame: p)
            g.cornerRadius = Draw.areaCornerRadius
            slabs.append(g)
            content.addSubview(g)
        }
        for _ in 0..<4 {
            let g = NSGlassEffectView()
            bars.append(g)
            content.addSubview(g)
        }

        labels.frame = bounds
        labels.panes = panes
        addSubview(labels)
        (slabs + bars).forEach { $0.style = style }
        applyTint()
        updateSlabs(animated: false)
        layoutGlass()
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        labels.title = "시스템 유리 (\(style == .clear ? "맑게" : "보통")\(thick ? ", 굵게" : "")\(tinted ? "" : ", 색 없음")\(showSlabs ? "" : ", 유리판 없음")) — 화면 기록 필요 없음"
        labels.needsDisplay = true
    }

    private func applyTint() {
        bars.forEach { $0.tintColor = tinted ? Config.scrollBorderColor.withAlphaComponent(0.45) : nil }
        slabs.forEach { $0.tintColor = tinted ? Config.inactiveAreaColor.withAlphaComponent(max(0.05, Config.inactiveFillOpacity)) : nil }
    }

    /// 고르지 않은 영역에만 유리판 (투명도는 시스템 유리에 먹지 않아 숨기기로)
    private func updateSlabs(animated: Bool) {
        for (i, s) in slabs.enumerated() { s.isHidden = !showSlabs || i == selected }
    }
    var showSlabs = true { didSet { updateSlabs(animated: false); updateTitle() } }

    /// 테두리 = 물방울 사각형 둘레의 막대 네 개 (모서리에서 겹쳐 시스템이 이어 붙인다)
    private func layoutGlass() {
        let blob = motion.rect
        let band = thick ? 12 : Draw.ringBand(Config.scrollBorderWidth) * (1 + 0.4 * motion.stretch)
        let o = blob.insetBy(dx: -band, dy: -band)
        let frames = [
            CGRect(x: o.minX, y: o.minY, width: o.width, height: band),
            CGRect(x: o.minX, y: o.maxY - band, width: o.width, height: band),
            CGRect(x: o.minX, y: o.minY, width: band, height: o.height),
            CGRect(x: o.maxX - band, y: o.minY, width: band, height: o.height),
        ]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (g, f) in zip(bars, frames) {
            g.frame = f
            g.cornerRadius = band / 2
        }
        CATransaction.commit()
    }

    func select(_ i: Int) {
        guard i != selected, panes.indices.contains(i) else { return }
        selected = i
        labels.selected = i
        labels.needsDisplay = true
        motion.move(to: panes[i])
        updateSlabs(animated: true)
    }

    func step(_ dt: CGFloat) {
        motion.step(dt)
        layoutGlass()
    }
}

// MARK: 나란히

final class CompareView: NSView {
    let left: PaneDemo
    var right: SystemGlassPane!
    var autoplay = true
    private var autoTime: CGFloat = 0
    private var timer: Timer?
    private let sequence = [3, 0, 2, 1]
    private var selected = 1

    override init(frame: NSRect) {
        let half = NSRect(x: 0, y: 0, width: (frame.width - 10) / 2, height: frame.height - 30)
        left = PaneDemo(frame: half)
        super.init(frame: frame)
        addSubview(left)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func prepare(scale: CGFloat) {
        left.prepare(scale: scale)
        let r = left.frame.offsetBy(dx: left.frame.width + 10, dy: 0)
        right = SystemGlassPane(frame: r, panes: left.panes, background: left.background)
        addSubview(right)
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
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.06, alpha: 1).setFill()
        bounds.fill()
        let text = "1–4·Tab 영역 이동   Space 자동 재생 \(autoplay ? "끄기" : "켜기")   C 맑게·보통   B 굵기   T 색   S 유리판   Esc 닫기"
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                              .foregroundColor: NSColor(white: 0.8, alpha: 1)])
        s.draw(at: CGPoint(x: (bounds.width - s.size().width) / 2, y: bounds.height - 22))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 18, 19, 20, 21: select(Int(event.keyCode) - 18)
        case 48: select((selected + 1) % 4)
        case 49: autoplay.toggle(); needsDisplay = true
        case 8: right.style = right.style == .clear ? .regular : .clear      // C
        case 11: right.thick.toggle()                                          // B
        case 17: right.tinted.toggle()                                         // T
        case 1: right.showSlabs.toggle()                                       // S
        case 53: NSApp.terminate(nil)
        default: super.keyDown(with: event)
        }
    }
}

// MARK: 실행

final class DemoDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let size = CGSize(width: 1290, height: 470)
let args = CommandLine.arguments
let shotDir = args.firstIndex(of: "--shot").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }

let app = NSApplication.shared
let delegate = DemoDelegate()
app.delegate = delegate
app.setActivationPolicy(shotDir == nil ? .regular : .accessory)
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
appItem.submenu?.addItem(withTitle: "닫기", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
app.mainMenu = menu
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = "Hanmium · 스크롤 모드 유리: 지금 ↔ 시스템 유리"
let view = CompareView(frame: NSRect(origin: .zero, size: size))
window.contentView = view
window.center()
view.prepare(scale: window.backingScaleFactor)

if let shotDir {
    // 확인용: 포커스를 가져가지 않고 다른 창 뒤에 띄워 장면마다 그 창만 찍는다
    view.autoplay = false
    window.orderBack(nil)
    let wid = window.windowNumber
    func shot(_ name: String) {
        view.left.needsDisplay = true
        view.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(wid)", "\(shotDir)/\(name).png"]
        try? p.run()
        p.waitUntilExit()
        print("\(shotDir)/\(name).png")
    }
    func steps(_ n: Int) { for _ in 0..<n { view.step(1.0 / 60) } }
    shot("1-clear-settled")
    view.select(3); steps(8); shot("2-clear-moving")
    steps(120); shot("3-clear-settled-4")
    view.right.style = .regular; shot("4-regular")
    view.right.style = .clear; view.right.showSlabs = false; shot("5-no-slabs")
    view.right.thick = true; shot("6-no-slabs-thick")
    exit(0)
}

window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
view.start()
app.run()
