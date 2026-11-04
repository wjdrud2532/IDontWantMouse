import AppKit
import SwiftUI

// README 이미지 만들기: Hanmium 의 그리기 코드로 가짜 화면(링크가 많은 웹 페이지, 터미널 분할 창)과 설정 창을
// 화면 밖에서 그린다. 실제 화면을 찍지 않으니 쓰는 화면의 내용이 들어가지 않는다.
//   Tools/make-doc-images.sh  → docs/images/*.png

struct Item {
    let title: String
    let site: String
    let points: Int
    let user: String
    let age: String
    let comments: Int
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images"
let scale: CGFloat = 2

/// 위가 0 인 좌표로 그려 2배 크기 PNG 로 저장한다
func savePNG(_ name: String, size: CGSize, _ body: () -> Void) {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
    guard let image = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("만듦: \(outDir)/\(name).png")
}

/// 배경만 그린 CGImage (유리가 굴절시킬 "화면 사진")
func renderBackground(size: CGSize, _ body: () -> Void) -> CGImage? {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

func text(_ s: String, _ font: NSFont, _ color: NSColor, _ p: CGPoint) -> CGRect {
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    a.draw(at: p)
    return CGRect(origin: p, size: a.size())
}

func drawBackground(_ bg: CGImage, _ size: CGSize) {
    NSImage(cgImage: bg, size: size).draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy,
                                          fraction: 1, respectFlipped: true, hints: nil)
}

// MARK: 1. 라벨 클릭 — 링크가 많은 웹 페이지

do {
    let size = CGSize(width: 860, height: 420)
    var targets: [CGRect] = []
    let gray = NSColor(srgbRed: 0.51, green: 0.51, blue: 0.51, alpha: 1)
    let title = NSFont(name: "Verdana", size: 13) ?? .systemFont(ofSize: 13)
    let small = NSFont(name: "Verdana", size: 9.5) ?? .systemFont(ofSize: 9.5)
    let bg = renderBackground(size: size) {
        NSColor(srgbRed: 0.965, green: 0.965, blue: 0.937, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        NSColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: size.width, height: 28).fill()
        var x: CGFloat = 12
        targets.append(text("Hacker News", .boldSystemFont(ofSize: 13), .black, CGPoint(x: x, y: 6)))
        x = targets[0].maxX + 12
        for n in ["new", "past", "comments", "ask", "show", "jobs", "submit"] {
            let r = text(n, .systemFont(ofSize: 11), .black, CGPoint(x: x, y: 7))
            targets.append(r)
            x = r.maxX + 10
        }
        for (i, item) in items.prefix(12).enumerated() {
            let y = 40 + CGFloat(i) * 31
            _ = text("\(i + 1).", title, gray, CGPoint(x: 10, y: y))
            let t = text(item.title, title, .black, CGPoint(x: 36, y: y))
            targets.append(t)
            if !item.site.isEmpty { targets.append(text(" (\(item.site))", .systemFont(ofSize: 10.5), gray, CGPoint(x: t.maxX, y: y + 2))) }
            var sx = text("\(item.points) points by ", small, gray, CGPoint(x: 36, y: y + 16)).maxX
            let u = text(item.user, small, gray, CGPoint(x: sx, y: y + 16))
            targets.append(u)
            sx = text(" | hide | ", small, gray, CGPoint(x: u.maxX, y: y + 16)).maxX
            targets.append(text("\(item.comments) comments", small, gray, CGPoint(x: sx, y: y + 16)))
        }
    }!
    let source = GlassSource(ScreenSnapshot(image: bg, axFrame: CGRect(origin: .zero, size: size))!)
    let labels = LabelMaker.make(count: targets.count, alphabet: Array("fjdkslaghrueiwoqptyvncmxbz"))
    savePNG("labels", size: size) {
        drawBackground(bg, size)
        Draw.glassSource = source
        for (label, r) in zip(labels, targets) {
            Draw.pill(label.uppercased(), center: CGPoint(x: r.midX, y: r.midY), within: CGRect(origin: .zero, size: size))
        }
        Draw.glassSource = nil
    }
}

// MARK: 2. 리퀴드 글래스 — 밝은·어두운 배경 위 라벨

do {
    let size = CGSize(width: 640, height: 150)
    let bg = renderBackground(size: size) {
        let half = size.width / 2
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: half, height: size.height).fill()
        NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1).setFill()
        CGRect(x: half, y: 0, width: half, height: size.height).fill()
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let light: [NSColor] = [.darkGray, .systemBlue]
        let dark: [NSColor] = [.systemPink, .systemGreen, .systemYellow, .systemBlue]
        for i in 0..<8 {
            _ = text("let glass = refract(light, n: 1.5)", mono, light[i % 2], CGPoint(x: 8, y: CGFloat(i) * 18 + 2))
            _ = text("func render(_ items: [Item]) -> View", mono, dark[i % 4], CGPoint(x: half + 8, y: CGFloat(i) * 18 + 2))
        }
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: CGRect(x: 190, y: 60, width: 90, height: 90)).fill()
        NSColor.systemPurple.setFill()
        NSBezierPath(ovalIn: CGRect(x: 520, y: -20, width: 90, height: 90)).fill()
    }!
    let source = GlassSource(ScreenSnapshot(image: bg, axFrame: CGRect(origin: .zero, size: size))!)
    let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
    let spots: [(String, CGPoint)] = [("FJ", CGPoint(x: 70, y: 40)), ("DK", CGPoint(x: 200, y: 95)), ("SL", CGPoint(x: 120, y: 120)),
                                      ("A", CGPoint(x: 390, y: 40)), ("GH", CGPoint(x: 470, y: 100)), ("RU", CGPoint(x: 560, y: 45))]
    savePNG("glass", size: size) {
        drawBackground(bg, size)
        Draw.glassSource = source
        for (label, p) in spots { Draw.pill(label, center: p, within: CGRect(origin: .zero, size: size), font: font) }
        Draw.glassSource = nil
    }
}

// MARK: 3. 스크롤 모드 — 터미널 분할 창 3개

do {
    let size = CGSize(width: 760, height: 380)
    let panes = [CGRect(x: 16, y: 16, width: 360, height: 348), CGRect(x: 384, y: 16, width: 360, height: 196),
                 CGRect(x: 384, y: 220, width: 360, height: 144)]
    let bg = renderBackground(size: size) {
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.15, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let colors: [NSColor] = [NSColor(white: 0.85, alpha: 1), .systemGreen, .systemYellow, .systemBlue, .systemPink]
        for (n, p) in panes.enumerated() {
            NSColor(srgbRed: 0.13, green: 0.14, blue: 0.20, alpha: 1).setFill()
            p.fill()
            let lines = n == 0 ? (1...20).map { "\(980 + $0)  echo build step \($0)" }
                : n == 1 ? ["$ git log --oneline", "e968f62 add: Hanmium", "746f6d3 fix: nav layer", "8d15381 fix: 한영 전환",
                            "9a746d2 update: ₩ 키", "49224f4 revert: Opt+b", "72c837c update: Caps Lock", "…"]
                : ["$ make test", "✓ glass refraction", "✓ scroll areas", "✓ wezterm panes", "✗ flaky network test"]
            for (i, line) in lines.enumerated() {
                _ = text(line, mono, colors[(i + n) % colors.count], CGPoint(x: p.minX + 10, y: p.minY + 8 + CGFloat(i) * 17))
            }
        }
    }!
    let source = GlassSource(ScreenSnapshot(image: bg, axFrame: CGRect(origin: .zero, size: size))!)
    let selected = 1
    savePNG("scroll", size: size) {
        drawBackground(bg, size)
        Draw.glassSource = source
        let color = Config.scrollBorderColor
        for (i, p) in panes.enumerated() where i != selected {
            Draw.glassArea(p, selected: panes[selected], color: color, fillOpacity: 0.12,
                           edge: Draw.glassAreaEdge(p, color: color, fillOpacity: 0.12, bezel: Draw.slabBezel(3)))
        }
        Draw.glassRing(panes[selected], color: color, band: Draw.ringBand(3))
        for (i, p) in panes.enumerated() {
            Draw.pill("\(i + 1)", typedCount: i == selected ? 0 : 1, center: CGPoint(x: p.minX + 14, y: p.minY + 12),
                      within: CGRect(origin: .zero, size: size))
        }
        Draw.glassSource = nil
    }
}

// MARK: 4. 물방울 이동 (선택 기능) — 늘어나는 물방울이 옆 창으로 옮겨가는 장면 4개

do {
    let size = CGSize(width: 380, height: 220)
    let panes = [CGRect(x: 12, y: 12, width: 170, height: 196), CGRect(x: 198, y: 12, width: 170, height: 196)]
    let bg = renderBackground(size: size) {
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.15, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for p in panes {
            NSColor(srgbRed: 0.13, green: 0.14, blue: 0.20, alpha: 1).setFill()
            p.fill()
            for i in 0..<11 { _ = text("line \(i + 1) …", mono, NSColor(white: 0.8, alpha: 1), CGPoint(x: p.minX + 8, y: p.minY + 6 + CGFloat(i) * 17)) }
        }
    }!
    let source = GlassSource(ScreenSnapshot(image: bg, axFrame: CGRect(origin: .zero, size: size))!)
    let motion = DropletMotion(rect: panes[0], style: .stretch, timeScale: 1)
    motion.move(to: panes[1])
    var frame = 0
    let shots = [0, 6, 11, 40]
    let sheet = CGSize(width: size.width * 4 + 30, height: size.height)
    var images: [CGImage] = []
    for target in shots {
        while frame < target { motion.step(1.0 / 60); frame += 1 }
        if let img = renderBackground(size: size, {
            drawBackground(bg, size)
            Draw.glassSource = source
            Draw.glassRing(motion.rect, color: Config.scrollBorderColor, band: Draw.ringBand(3), stretch: motion.stretch,
                           lens: motion.lens, moving: !motion.isSettled)
            Draw.glassSource = nil
        }) { images.append(img) }
    }
    savePNG("droplet", size: sheet) {
        NSColor.white.setFill()
        CGRect(origin: .zero, size: sheet).fill()
        for (i, img) in images.enumerated() {
            NSImage(cgImage: img, size: size).draw(in: CGRect(x: CGFloat(i) * (size.width + 10), y: 0, width: size.width, height: size.height),
                                                   from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

// MARK: 5. 설정 창 — 모든 항목이 보이게 높이를 늘려서

MainActor.assumeIsolated {
    _ = NSApplication.shared
    SettingsView.height = 2350
    let view = NSHostingView(rootView: SettingsView(onHotkeysChanged: {}, onRecording: { _ in }))
    let size = CGSize(width: 460, height: SettingsView.height)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = view
    view.frame = CGRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/settings.png"))
    print("만듦: \(outDir)/settings.png")
}
