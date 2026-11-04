import AppKit

// Hanmium 스크롤 모드 "물방울 이동" 예시. Hanmium 의 유리 그리기 코드를 그대로 쓴다.
// 1~4·Tab: 영역 이동  V: 방식 바꾸기  Space: 자동 재생  Esc: 닫기

// Spring 은 Hanmium 의 Droplet.swift 것을 쓴다 (이 예시가 그대로 앱에 들어갔다)

enum Variant {
    case stretch, hop

    var title: String { self == .stretch ? "A · 늘어나는 물방울" : "B · 날아가는 물방울" }
}

final class DemoView: NSView {
    private(set) var panes: [CGRect] = []
    private(set) var selected = 1
    var variant = Variant.stretch
    var autoplay = true
    /// minX, minY, maxX, maxY
    private var edges: [Spring] = []
    private var phase = 0
    private var phaseTime: CGFloat = 0
    private var slab: [CGFloat] = []
    private var background: CGImage?
    private var source: GlassSource?
    private var autoTime: CGFloat = 0
    private var timer: Timer?
    private let droplet: CGFloat = 34
    private let sequence = [1, 3, 0, 2]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let w = frame.width, h = frame.height, mid = (308 + w - 8) / 2
        panes = [
            CGRect(x: 10, y: 10, width: 290, height: h - 20),
            CGRect(x: 310, y: 10, width: w - 320, height: 300),
            CGRect(x: 310, y: 320, width: mid - 314, height: h - 330),
            CGRect(x: mid + 4, y: 320, width: w - mid - 14, height: h - 330),
        ]
        let r = panes[selected]
        edges = [Spring(r.minX), Spring(r.minY), Spring(r.maxX), Spring(r.maxY)]
        slab = panes.indices.map { $0 == selected ? 0 : 1 }
    }

    required init?(coder: NSCoder) { fatalError() }

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
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).setFill()
        bounds.fill()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        func line(_ s: String, _ c: NSColor, _ p: CGPoint, font: NSFont = mono) {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c]).draw(at: p)
        }
        // 1: 밝은 문서
        let doc = panes[0]
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1).setFill()
        doc.fill()
        line("Liquid Glass 메모", .black, CGPoint(x: doc.minX + 14, y: doc.minY + 16),
             font: .boldSystemFont(ofSize: 17))
        let words = ["유리는 뒤 화면을 굴절시키고", "가장자리에서 빛을 받는다.", "스넬 법칙 n₁sinθ₁ = n₂sinθ₂",
                     "볼록 스퀘어클 단면", "https://kube.io/blog/liquid-glass", "물방울처럼 늘어났다가",
                     "제자리에서 출렁이며 멈춘다.", "Hanmium 스크롤 모드"]
        for (i, wd) in (words + words + words).enumerated() {
            line(wd, i % 4 == 3 ? .systemBlue : NSColor(white: 0.25, alpha: 1),
                 CGPoint(x: doc.minX + 14, y: doc.minY + 52 + CGFloat(i) * 21), font: .systemFont(ofSize: 13))
        }
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: CGRect(x: doc.minX + 150, y: doc.maxY - 150, width: 110, height: 110)).fill()
        // 2: 코드
        let code = panes[1]
        let palette: [NSColor] = [.systemPink, .systemGreen, .systemYellow, .systemBlue, .white, .systemPurple]
        for i in 0..<17 {
            line("func render(_ items: [Item]) -> some View { ForEach(items) { Text($0.title) } }",
                 palette[i % palette.count], CGPoint(x: code.minX + 10, y: code.minY + 8 + CGFloat(i) * 17))
        }
        NSColor.systemPurple.setFill()
        NSBezierPath(ovalIn: CGRect(x: code.maxX - 120, y: code.minY + 40, width: 90, height: 90)).fill()
        // 3, 4: 터미널
        for (n, p) in panes[2...].enumerated() {
            for i in 0..<12 {
                let ok = (i + n) % 3 != 0
                line(ok ? "✓ test_glass_\(i) passed (\(i * 7 + 3)ms)" : "✗ test_drop_\(i) failed",
                     ok ? .systemGreen : .systemRed, CGPoint(x: p.minX + 10, y: p.minY + 8 + CGFloat(i) * 17))
            }
            NSGradient(colors: [.systemTeal, .systemIndigo, .systemPink])?
                .draw(in: CGRect(x: p.minX + 10, y: p.maxY - 30, width: p.width - 20, height: 14), angle: 0)
        }
        // 분할선
        NSColor(srgbRed: 0.35, green: 0.37, blue: 0.42, alpha: 1).setFill()
        CGRect(x: 304, y: 0, width: 2, height: bounds.height).fill()
        CGRect(x: 306, y: 314, width: bounds.width, height: 2).fill()
        CGRect(x: panes[3].minX - 4, y: 316, width: 2, height: bounds.height).fill()
    }

    // MARK: 움직임

    private var blob: CGRect {
        let x0 = min(edges[0].x, edges[2].x), x1 = max(edges[0].x, edges[2].x)
        let y0 = min(edges[1].x, edges[3].x), y1 = max(edges[1].x, edges[3].x)
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 2), height: max(y1 - y0, 2))
    }

    /// 앞서가는 변(움직이는 쪽)은 빠르고 단단하게, 뒤따르는 변은 느리게 → 가는 동안 늘어난다
    private func aim(_ r: CGRect, lead: CGFloat, trail: CGFloat) {
        let t = [r.minX, r.minY, r.maxX, r.maxY]
        for i in 0..<4 {
            let leading = i < 2 ? t[i] < edges[i].x : t[i] > edges[i].x
            edges[i].set(t[i], stiffness: leading ? lead : trail, ratio: leading ? 0.62 : 0.9)
        }
    }

    private func aim(_ r: CGRect, stiffness: CGFloat, ratio: CGFloat) {
        let t = [r.minX, r.minY, r.maxX, r.maxY]
        for i in 0..<4 { edges[i].set(t[i], stiffness: stiffness, ratio: ratio) }
    }

    private func drop(at p: CGPoint) -> CGRect {
        CGRect(x: p.x - droplet / 2, y: p.y - droplet / 2, width: droplet, height: droplet)
    }

    func select(_ i: Int) {
        guard i != selected, panes.indices.contains(i) else { return }
        selected = i
        autoTime = 0
        switch variant {
        case .stretch:
            aim(panes[i], lead: 420, trail: 120)
        case .hop:
            phase = 0
            phaseTime = 0
            aim(drop(at: CGPoint(x: blob.midX, y: blob.midY)), stiffness: 520, ratio: 0.85)
        }
    }

    func step(_ dt: CGFloat) {
        for _ in 0..<4 { edges.forEach { $0.step(dt / 4) } }
        phaseTime += dt
        if variant == .hop {
            let target = panes[selected]
            if phase == 0, phaseTime > 0.16 || max(blob.width, blob.height) < droplet * 1.15 {
                phase = 1
                phaseTime = 0
                aim(drop(at: CGPoint(x: target.midX, y: target.midY)), lead: 300, trail: 110)
            } else if phase == 1, hypot(blob.midX - target.midX, blob.midY - target.midY) < 14 || phaseTime > 0.9 {
                phase = 2
                aim(target, stiffness: 260, ratio: 0.5)
            }
        }
        // 물방울이 덮은 만큼 그 영역의 유리판이 걷힌다
        for i in panes.indices {
            let o = blob.intersection(panes[i])
            let covered = o.isNull ? 0 : (o.width * o.height) / (panes[i].width * panes[i].height)
            let want = 1 - min(1, covered * 1.3)
            slab[i] += (want - slab[i]) * min(1, dt / 0.07)
        }
        if autoplay {
            autoTime += dt
            if autoTime > 1.6, let at = sequence.firstIndex(of: selected) {
                select(sequence[(at + 1) % sequence.count])
            }
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.step(1.0 / 60)
            self?.needsDisplay = true
        }
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let background, let source else { return }
        NSImage(cgImage: background, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1,
                                                              respectFlipped: true, hints: nil)
        Draw.glassSource = source
        for (i, p) in panes.enumerated() where slab[i] > 0.01 {
            ctx.saveGState()
            ctx.setAlpha(slab[i])
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            Draw.glassArea(p, selected: .zero, color: Config.inactiveAreaColor, fillOpacity: Config.inactiveFillOpacity,
                           edge: Draw.glassAreaEdge(p, color: Config.inactiveAreaColor,
                                                    fillOpacity: Config.inactiveFillOpacity, bezel: Draw.slabBezel(3)))
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        drawBlob(ctx, snapshot: source.snapshot)
        for (i, p) in panes.enumerated() {
            Draw.pill("\(i + 1)", typedCount: i == selected ? 0 : 1, center: CGPoint(x: p.minX + 16, y: p.minY + 14),
                      within: bounds)
        }
        Draw.glassSource = nil
        drawHelp()
    }

    private func drawBlob(_ ctx: CGContext, snapshot: ScreenSnapshot) {
        let r = blob
        let color = Config.scrollBorderColor
        let speed = edges.map { abs($0.v) }.max() ?? 0
        let stretch = min(1, speed / 1600)
        let minDim = min(r.width, r.height)
        // B 에서 작아지면 테두리 대신 속이 찬 물방울(볼록 렌즈)
        let lens = variant == .hop ? min(max((droplet * 2.4 - minDim) / droplet, 0), 1) : 0
        let radius = min(minDim / 2, 10 + stretch * minDim * 0.2 + lens * minDim)
        let band = 9 * (1 + 0.4 * stretch)
        let outer = lens > 0.5 ? r : r.insetBy(dx: -band, dy: -band)
        let outerRadius = lens > 0.5 ? radius : radius + band

        // 바깥 그림자
        ctx.saveGState()
        let shape = CGPath(roundedRect: outer, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil)
        ctx.addRect(outer.insetBy(dx: -30, dy: -30))
        ctx.addPath(shape)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.fillPath()
        ctx.restoreGState()

        if lens < 1, let ring = LiquidGlass.renderEdge(r, ring: true, width: band, cornerRadius: radius, tint: color,
                                                     tintAlpha: 0.3, from: snapshot) {
            NSImage(cgImage: ring.image, size: ring.frame.size).draw(
                in: ring.frame, from: .zero, operation: .sourceOver, fraction: 1 - lens, respectFlipped: true, hints: nil)
        }
        if lens > 0, let drop = LiquidGlass.renderEdge(r, ring: false, width: minDim / 2 + 1, cornerRadius: minDim / 2,
                                                     tint: color, tintAlpha: 0.12, from: snapshot) {
            NSImage(cgImage: drop.image, size: drop.frame.size).draw(
                in: drop.frame, from: .zero, operation: .sourceOver, fraction: lens, respectFlipped: true, hints: nil)
        }
    }

    private func drawHelp() {
        let text = "\(variant.title)   ·   1–4·Tab 이동   V 방식 바꾸기   Space 자동 재생 \(autoplay ? "끄기" : "켜기")   Esc 닫기"
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                              .foregroundColor: NSColor.white])
        let size = s.size()
        let r = CGRect(x: (bounds.width - size.width) / 2 - 12, y: bounds.height - size.height - 22,
                       width: size.width + 24, height: size.height + 10)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        s.draw(at: CGPoint(x: r.minX + 12, y: r.minY + 5))
    }

    // MARK: 키

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 18, 19, 20, 21: select(Int(event.keyCode) - 18)
        case 48: select((selected + 1) % panes.count)
        case 9:
            variant = variant == .stretch ? .hop : .stretch
            autoTime = 0
        case 49: autoplay.toggle()
        case 53: NSApp.terminate(nil)
        default: super.keyDown(with: event)
        }
    }
}

// MARK: 확인용: 창 없이 몇 장면을 그려 한 장으로 붙인다

func renderFrames(to path: String) {
    let size = CGSize(width: 900, height: 560)
    let frames = [0, 4, 8, 12, 17, 24, 34, 60]
    let thumb = CGSize(width: 450, height: 280)
    let sheet = NSImage(size: CGSize(width: thumb.width * 4, height: thumb.height * 4))
    var shots: [(Variant, Int, NSImage)] = []
    for variant in [Variant.stretch, .hop] {
        let view = DemoView(frame: NSRect(origin: .zero, size: size))
        view.variant = variant
        view.autoplay = false
        view.prepare(scale: 1)
        view.select(2)
        var frame = 0
        for target in frames {
            while frame < target {
                view.step(1.0 / 60)
                frame += 1
            }
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            let img = NSImage(size: size)
            img.addRepresentation(rep)
            shots.append((variant, target, img))
        }
    }
    sheet.lockFocus()
    for (n, shot) in shots.enumerated() {
        let col = n % 4, row = n / 4
        let r = CGRect(x: CGFloat(col) * thumb.width, y: sheet.size.height - CGFloat(row + 1) * thumb.height,
                       width: thumb.width, height: thumb.height)
        shot.2.draw(in: r)
        NSAttributedString(string: "\(shot.0 == .stretch ? "A" : "B") \(shot.1 * 1000 / 60)ms",
                           attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white,
                                        .backgroundColor: NSColor.black])
            .draw(at: CGPoint(x: r.minX + 6, y: r.minY + 6))
    }
    sheet.unlockFocus()
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
// --frame <a|b> <n> <path>: 그 장면 하나를 2배 크기로
if let i = args.firstIndex(of: "--frame"), i + 3 < args.count {
    let view = DemoView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
    view.variant = args[i + 1] == "b" ? .hop : .stretch
    view.autoplay = false
    view.prepare(scale: 2)
    view.select(2)
    for _ in 0..<(Int(args[i + 2]) ?? 0) { view.step(1.0 / 60) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1120, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 3]))
    exit(0)
}
if let i = args.firstIndex(of: "--frames"), i + 1 < args.count {
    renderFrames(to: args[i + 1])
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
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = "Hanmium · 물방울 이동 예시"
let view = DemoView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
window.contentView = view
window.center()
view.prepare(scale: window.backingScaleFactor)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
view.start()
app.run()
