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

setvbuf(stdout, nil, _IOLBF, 0)
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
    let labels = LabelMaker.make(count: targets.count, alphabet: Array(Config.defaultLabelCharacters))
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
                           edge: Draw.glassAreaEdge(p, color: color, fillOpacity: 0.12))
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

// MARK: 5. 설정 창 — 탭(일반·라벨·스크롤)마다 모든 항목이 보이게 높이를 늘려 그린 뒤 나란히

MainActor.assumeIsolated {
    _ = NSApplication.shared
    SettingsView.height = 1700
    var shots: [(rep: NSBitmapImageRep, height: CGFloat)] = []
    for tab in SettingsView.Tab.allCases {
        SettingsView.forcedTab = tab
        let view = NSHostingView(rootView: SettingsView(onHotkeysChanged: {}, onRecording: { _ in }))
        let size = CGSize(width: 460, height: SettingsView.height)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                   bitsPerPixel: 0)!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        // 아래쪽 빈 바탕은 잘라 낸다: 바탕색과 다른 픽셀이 있는 마지막 줄 + 여백
        let background = rep.colorAt(x: 2, y: rep.pixelsHigh - 2)
        var last = rep.pixelsHigh - 1
        search: while last > 0 {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) where rep.colorAt(x: x, y: last) != background {
                break search
            }
            last -= 1
        }
        shots.append((rep, min(size.height, CGFloat(last) / scale + 16)))
    }
    SettingsView.forcedTab = nil
    let gap: CGFloat = 16
    let size = CGSize(width: CGFloat(shots.count) * 460 + CGFloat(shots.count - 1) * gap,
                      height: shots.map(\.height).max() ?? 0)
    savePNG("settings", size: size) {
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: size).fill()
        for (i, shot) in shots.enumerated() {
            let x = CGFloat(i) * (460 + gap)
            let crop = CGRect(x: 0, y: 0, width: 460 * scale, height: shot.height * scale)
            if let cg = shot.rep.cgImage?.cropping(to: crop) {
                NSImage(cgImage: cg, size: CGSize(width: 460, height: shot.height))
                    .draw(in: CGRect(x: x, y: 0, width: 460, height: shot.height), from: .zero, operation: .copy,
                          fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
}

// MARK: 6~8. VS Code·Slack 라벨, Slack 다중 스크롤 움직이는 그림 (지어낸 내용의 비슷한 화면)

func render(size: CGSize, scale s: CGFloat, _ body: () -> Void) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: Int(size.width * s), height: Int(size.height * s), bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

let alphabet = Array(Config.defaultLabelCharacters)

/// 화면에 라벨을 붙인 그림 (typed: 이미 친 글자, 맞는 라벨만 남긴다)
func drawLabels(_ m: MockScreen, size: CGSize, typed: String = "") {
    let labels = LabelMaker.make(count: m.targets.count, alphabet: alphabet)
    let big = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
    for (label, r) in zip(labels, m.targets) where label.hasPrefix(typed) {
        Draw.pill(label.uppercased(), typedCount: typed.count, center: CGPoint(x: r.midX, y: r.midY),
                  within: CGRect(origin: .zero, size: size), font: typed.isEmpty ? Draw.font : big)
    }
}

func labelFor(_ target: CGRect, in m: MockScreen) -> String {
    let labels = LabelMaker.make(count: m.targets.count, alphabet: alphabet)
    return m.targets.firstIndex(of: target).map { labels[$0] } ?? ""
}

do {
    for (name, size, draw) in [("vscode-labels", CodeMock.size, { CodeMock.draw() }),
                               ("slack-labels", SlackMock.size, { SlackMock.draw(SlackState()) })] as [(String, CGSize, () -> MockScreen)] {
        var screen = MockScreen()
        let bg = renderBackground(size: size) { screen = draw() }!
        let source = GlassSource(ScreenSnapshot(image: bg, axFrame: CGRect(origin: .zero, size: size))!)
        savePNG(name, size: size) {
            drawBackground(bg, size)
            Draw.glassSource = source
            drawLabels(screen, size: size)
            Draw.glassSource = nil
        }
    }
}

/// 아래쪽 자막: 누른 키(키캡)와 설명
func caption(_ keys: String, _ text: String, size: CGSize) {
    let font = NSFont.systemFont(ofSize: 15, weight: .medium)
    let keyFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
    let t = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
    let k = NSAttributedString(string: keys, attributes: [.font: keyFont, .foregroundColor: NSColor.black])
    let keyW = keys.isEmpty ? 0 : k.size().width + 18
    let w = t.size().width + keyW + (keys.isEmpty ? 32 : 44)
    let bar = CGRect(x: (size.width - w) / 2, y: size.height - 58, width: w, height: 40)
    fill(bar, NSColor(white: 0, alpha: 0.72), radius: 20)
    var x = bar.minX + 16
    if !keys.isEmpty {
        let cap = CGRect(x: x, y: bar.minY + 8, width: keyW, height: 24)
        fill(cap, NSColor(white: 0.95, alpha: 1), radius: 6)
        k.draw(at: CGPoint(x: cap.minX + 9, y: cap.minY + 3))
        x = cap.maxX + 12
    }
    t.draw(at: CGPoint(x: x, y: bar.minY + 10))
}

enum SlackMode {
    case none
    case scroll(Int)
    case labels(String)
    case clicked(CGRect)
}

/// 시각 t(초)의 장면: 화면 상태, 모드, 자막
func slackScene(_ t: Double) -> (SlackState, SlackMode, String, String) {
    func ease(_ x: Double) -> CGFloat { CGFloat(x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x)) }
    func ramp(_ a: Double, _ b: Double) -> CGFloat { ease((t - a) / (b - a)) }
    var st = SlackState()
    st.messagesOffset = 140 * ramp(2.0, 3.4) + 134 * ramp(3.5, 3.8)
    st.threadOffset = 240 * ramp(5.0, 6.2)
    st.channelsOffset = 110 * ramp(7.0, 8.2) - 110 * ramp(8.4, 8.7)
    switch t {
    case ..<1.0: return (st, .none, "", "Slack — 채널 목록 · 메시지 · 스레드, 스크롤 영역이 세 곳")
    case ..<2.0: return (st, .scroll(1), "⇧⌘J", "스크롤 모드 — 영역마다 번호, 메시지(2)에서 시작")
    case ..<3.45: return (st, .scroll(1), "j", "누르는 동안 부드럽게 아래로")
    case ..<4.2: return (st, .scroll(1), "d", "반 페이지 아래로")
    case ..<5.0: return (st, .scroll(2), "3", "스레드로 옮기기")
    case ..<6.3: return (st, .scroll(2), "j", "스레드 아래로")
    case ..<7.0: return (st, .scroll(0), "1", "채널 목록으로 옮기기")
    case ..<8.3: return (st, .scroll(0), "j", "채널 목록 아래로")
    case ..<9.1: return (st, .scroll(0), "gg", "맨 위로")
    case ..<9.7: return (st, .none, "Esc", "스크롤 모드 닫기")
    case ..<11.0: return (st, .labels(""), "⌥Space", "라벨 모드 — 누를 수 있는 곳마다 라벨")
    default:
        return (st, .labels(""), "", "")  // 11초 뒤는 아래에서 라벨 입력·클릭 장면으로 채운다
    }
}

/// Slack 다중 스크롤 장면 하나를 그린다 (t 초, scale 배)
final class SlackClip {
    let size = SlackMock.size
    let total = 13.6
    private let designRect: CGRect
    private let designLabel: String

    init() {
        // #design 채널 라벨 (라벨 모드에서 칠 글자)
        var screen = MockScreen()
        _ = render(size: SlackMock.size, scale: 1) { screen = SlackMock.draw(slackScene(10).0) }
        designRect = screen.named["design"] ?? .zero
        designLabel = labelFor(designRect, in: screen)
    }

    func frame(at t: Double, scale s: CGFloat) -> CGImage? {
        var (st, mode, keys, text) = slackScene(t)
        if t >= 11.0 {
            // 첫 글자 → 둘째 글자(누름) → #design 이 열린다
            if t < 11.9 {
                mode = .labels(String(designLabel.prefix(1)))
                keys = String(designLabel.prefix(1)).uppercased()
                text = "첫 글자 — 맞는 라벨만 크게 남는다"
            } else if t < 12.5 {
                mode = .clicked(designRect)
                keys = designLabel.uppercased()
                text = "둘째 글자 — #design 을 누른다"
            } else {
                st.channel = "design"
                mode = .none
                keys = ""
                text = "마우스 없이 채널 이동 · 세 영역 스크롤 · 클릭까지 키보드로"
            }
        }
        var screen = MockScreen()
        guard let bg = render(size: size, scale: s, { screen = SlackMock.draw(st) }),
              let snap = ScreenSnapshot(image: bg, axFrame: CGRect(origin: .zero, size: size)) else { return nil }
        let source = GlassSource(snap)
        return render(size: size, scale: s) {
            drawBackground(bg, size)
            Draw.glassSource = source
            switch mode {
            case .none:
                break
            case .scroll(let selected):
                let color = Config.scrollBorderColor
                for (i, a) in screen.areas.enumerated() where i != selected {
                    Draw.glassArea(a, selected: screen.areas[selected], color: color, fillOpacity: 0.12,
                                   edge: Draw.glassAreaEdge(a, color: color, fillOpacity: 0.12))
                }
                Draw.glassRing(screen.areas[selected], color: color, band: Draw.ringBand(3))
                for (i, a) in screen.areas.enumerated() {
                    Draw.pill("\(i + 1)", typedCount: i == selected ? 0 : 1, center: CGPoint(x: a.minX + 14, y: a.minY + 12),
                              within: CGRect(origin: .zero, size: size))
                }
            case .labels(let typed):
                drawLabels(screen, size: size, typed: typed)
            case .clicked(let r):
                let path = NSBezierPath(roundedRect: r.insetBy(dx: -6, dy: -3), xRadius: 6, yRadius: 6)
                Config.scrollBorderColor.setStroke()
                path.lineWidth = 3
                path.stroke()
            }
            Draw.glassSource = nil
            caption(keys, text, size: size)
        }
    }
}

// GitHub README 는 저장소에 넣은 동영상을 본문에서 재생하지 못해서, 그 자리에서 움직이는 GIF 로 만든다.
// 초당 10장으로 그리고, 바뀌지 않는 장면은 한 장으로 합쳐 길게 보여줘서 용량을 줄인다.
do {
    let clip = SlackClip()
    let fps = 10.0
    var frames: [(image: CGImage, delay: Double)] = []
    var lastBytes: Data?
    for f in 0..<Int(clip.total * fps) {
        guard let img = clip.frame(at: Double(f) / fps, scale: 1),
              let bytes = img.dataProvider?.data as Data? else { continue }
        if bytes == lastBytes, !frames.isEmpty {
            frames[frames.count - 1].delay += 1 / fps
        } else {
            frames.append((img, 1 / fps))
            lastBytes = bytes
        }
    }
    let url = URL(fileURLWithPath: "\(outDir)/slack-scroll.gif")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) else {
        fatalError("GIF 를 만들 수 없음")
    }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (img, delay) in frames {
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
        ]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("만듦: \(url.path) (장면 \(frames.count)개, \(bytes / 1024)KB)")
}
