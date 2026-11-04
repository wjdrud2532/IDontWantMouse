import AppKit

// 링크가 많은 페이지(HN)에서 라벨을 어떻게 보여줄지 비교하는 예시. Hanmium 의 유리 라벨 그리기를 그대로 쓴다.
// 1~7: 방식 바꾸기  글자: 라벨 입력  ⌫: 지우기/뒤로  Esc: 처음으로  Tab: 종류 바꾸기(3)  ↑↓: 띠 옮기기(7)

struct Item {
    let title: String
    let site: String
    let points: Int
    let user: String
    let age: String
    let comments: Int
}

enum Kind {
    case nav, upvote, title, site, user, age, hide, comments

    var name: String {
        switch self {
        case .nav: "메뉴"
        case .upvote: "추천"
        case .title: "제목"
        case .site: "사이트"
        case .user: "사용자"
        case .age: "시간"
        case .hide: "숨기기"
        case .comments: "댓글"
        }
    }
}

struct Target {
    let rect: CGRect
    let kind: Kind
    /// -1 은 맨 위 메뉴 줄
    let row: Int
    let text: String
}

enum Strategy: Int, CaseIterable {
    case current, rows, kinds, grow, loupe, list, band, fit

    var title: String {
        ["지금 방식", "줄 먼저", "종류별", "치면 커짐", "돋보기", "옆 목록", "주변만", "요소 크기"][rawValue]
    }

    var summary: String {
        [
            "링크마다 작은 라벨 (비교용)",
            "① 왼쪽 큰 라벨로 줄을 고르고 → ② 그 줄의 링크만 큰 라벨로",
            "한 종류(제목)만 큰 라벨로. Tab 으로 댓글 → 사이트 → 사용자 → 전체",
            "처음엔 지금과 같고, 첫 글자를 치면 맞는 라벨만 크게 남는다",
            "① 큰 글자로 구역(3줄)을 고르면 → ② 그 구역을 1.4배 확대해서 링크 고르기",
            "오른쪽에 제목·댓글 목록을 크게. 글자를 치면 페이지의 링크와 선으로 이어진다",
            "↑↓ 로 옮기는 3줄 띠 안의 링크만 큰 라벨로",
            "링크마다 그 크기 그대로 유리 상자를 씌우고, 라벨 글자도 링크 높이에 맞춘다",
        ][rawValue]
    }
}

enum Stage: Equatable {
    case start
    case row(Int)
    case zone(Int)
}

enum Action {
    case click(Int)
    case row(Int)
    case zone(Int)
}

struct Choice {
    let label: String
    let center: CGPoint
    let font: NSFont
    let action: Action
}

// MARK: - 페이지

enum Page {
    static let size = CGSize(width: 1280, height: 884)
    static let x: CGFloat = 40
    static let width: CGFloat = 860
    static let top: CGFloat = 46
    static let rowH: CGFloat = 31
    static let rows = 24
    static let gray = NSColor(srgbRed: 0.51, green: 0.51, blue: 0.51, alpha: 1)
    static let title = NSFont(name: "Verdana", size: 13) ?? .systemFont(ofSize: 13)
    static let small = NSFont(name: "Verdana", size: 10.5) ?? .systemFont(ofSize: 10.5)
    static let sub = NSFont(name: "Verdana", size: 9.5) ?? .systemFont(ofSize: 9.5)

    static func rowRect(_ r: Int) -> CGRect {
        r < 0 ? CGRect(x: x, y: 6, width: width, height: 30)
            : CGRect(x: x, y: top + CGFloat(r) * rowH - 3, width: width, height: rowH)
    }

    /// 그리면서(draw) 링크 자리를 모은다
    @discardableResult
    static func layout(draw: Bool) -> [Target] {
        var targets: [Target] = []
        func text(_ s: String, _ font: NSFont, _ color: NSColor, _ p: CGPoint) -> CGRect {
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            if draw { a.draw(at: p) }
            return CGRect(origin: p, size: a.size())
        }
        if draw {
            NSColor.white.setFill()
            CGRect(origin: .zero, size: size).fill()
            NSColor(srgbRed: 0.965, green: 0.965, blue: 0.937, alpha: 1).setFill()
            CGRect(x: x, y: 6, width: width, height: top + CGFloat(rows) * rowH).fill()
            NSColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 1).setFill()
            CGRect(x: x, y: 6, width: width, height: 26).fill()
            NSColor.white.setStroke()
            NSBezierPath(rect: CGRect(x: x + 4, y: 10, width: 18, height: 18)).stroke()
            NSAttributedString(string: "Y", attributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                                                         .foregroundColor: NSColor.white]).draw(at: CGPoint(x: x + 8, y: 11))
        }
        let hn = text("Hacker News", NSFont(name: "Verdana-Bold", size: 13) ?? .boldSystemFont(ofSize: 13), .black,
                      CGPoint(x: x + 28, y: 11))
        targets.append(Target(rect: hn, kind: .nav, row: -1, text: "Hacker News"))
        var cx = hn.maxX + 10
        for (i, n) in ["new", "past", "comments", "ask", "show", "jobs", "submit"].enumerated() {
            if i > 0 { cx = text(" | ", small, .black, CGPoint(x: cx, y: 13)).maxX }
            let r = text(n, small, .black, CGPoint(x: cx, y: 13))
            targets.append(Target(rect: r, kind: .nav, row: -1, text: n))
            cx = r.maxX
        }
        let login = text("login", small, .black, CGPoint(x: x + width - 40, y: 13))
        targets.append(Target(rect: login, kind: .nav, row: -1, text: "login"))

        for (i, item) in items.prefix(rows).enumerated() {
            let y = top + CGFloat(i) * rowH
            let rank = NSAttributedString(string: "\(i + 1).", attributes: [.font: title, .foregroundColor: gray])
            if draw { rank.draw(at: CGPoint(x: x + 32 - rank.size().width, y: y)) }
            let up = CGRect(x: x + 36, y: y + 4, width: 10, height: 9)
            if draw {
                let tri = NSBezierPath()
                tri.move(to: CGPoint(x: up.midX, y: up.minY))
                tri.line(to: CGPoint(x: up.maxX, y: up.maxY))
                tri.line(to: CGPoint(x: up.minX, y: up.maxY))
                tri.close()
                NSColor(white: 0.6, alpha: 1).setFill()
                tri.fill()
            }
            targets.append(Target(rect: up.insetBy(dx: -2, dy: -2), kind: .upvote, row: i, text: "추천"))
            let t = text(item.title, title, .black, CGPoint(x: x + 50, y: y))
            targets.append(Target(rect: t, kind: .title, row: i, text: item.title))
            if !item.site.isEmpty {
                let s = text(" (\(item.site))", small, gray, CGPoint(x: t.maxX, y: y + 2))
                targets.append(Target(rect: s.insetBy(dx: 2, dy: 0), kind: .site, row: i, text: item.site))
            }
            var sx = text("\(item.points) points by ", sub, gray, CGPoint(x: x + 50, y: y + 16)).maxX
            let user = text(item.user, sub, gray, CGPoint(x: sx, y: y + 16))
            targets.append(Target(rect: user, kind: .user, row: i, text: item.user))
            sx = text(" ", sub, gray, CGPoint(x: user.maxX, y: y + 16)).maxX
            let age = text(item.age, sub, gray, CGPoint(x: sx, y: y + 16))
            targets.append(Target(rect: age, kind: .age, row: i, text: item.age))
            sx = text(" | ", sub, gray, CGPoint(x: age.maxX, y: y + 16)).maxX
            let hide = text("hide", sub, gray, CGPoint(x: sx, y: y + 16))
            targets.append(Target(rect: hide, kind: .hide, row: i, text: "hide"))
            sx = text(" | ", sub, gray, CGPoint(x: hide.maxX, y: y + 16)).maxX
            let c = text("\(item.comments) comments", sub, gray, CGPoint(x: sx, y: y + 16))
            targets.append(Target(rect: c, kind: .comments, row: i, text: "\(item.comments) comments"))
        }
        return targets
    }
}

/// flipped(위가 0) 좌표로 그려서 CGImage 로
func renderImage(size: CGSize, scale: CGFloat, _ body: () -> Void) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
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

func bold(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .bold) }

// MARK: - 예시 화면

final class HNDemo: NSView {
    let targets = Page.layout(draw: false)
    var strategy = Strategy.current
    private var typed = ""
    private var stage = Stage.start
    private let kinds: [Kind?] = [.title, .comments, .site, .user, nil]
    private var kindIndex = 0
    private var bandTop = 0
    private var flash: Int?
    private var toast: String?
    private var page: CGImage?
    private var pageSource: GlassSource?
    private var scene: CGImage?
    private var sceneSource: GlassSource?
    private var choices: [Choice] = []
    private var scale: CGFloat = 1
    private var alphabet: [Character] { Config.labelAlphabet }
    private let accent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func prepare(scale: CGFloat) {
        self.scale = scale
        page = renderImage(size: bounds.size, scale: scale) { Page.layout(draw: true) }
        if let page { pageSource = ScreenSnapshot(image: page, axFrame: bounds).map(GlassSource.init) }
        rebuild()
    }

    func set(_ s: Strategy) {
        strategy = s
        typed = ""
        stage = .start
        kindIndex = 0
        rebuild()
    }

    // MARK: 상태 → 라벨

    private func labels(_ n: Int) -> [String] { LabelMaker.make(count: n, alphabet: alphabet) }

    /// 0 은 맨 위 메뉴, 그다음부터 3줄씩
    private let zoneCount = 1 + Page.rows / 3

    private func zoneRows(_ z: Int) -> ClosedRange<Int> { z == 0 ? -1...(-1) : ((z - 1) * 3)...((z - 1) * 3 + 2) }

    private func zoneRect(_ z: Int) -> CGRect {
        zoneRows(z).map(Page.rowRect).reduce(CGRect.null) { $0.union($1) }
    }

    private let loupeScale: CGFloat = 1.4

    private func loupeRect(_ z: Int) -> CGRect {
        let zr = zoneRect(z)
        let w = zr.width * loupeScale, h = zr.height * loupeScale
        let y = min(max(zr.midY - h / 2, 10), bounds.height - 90 - h)
        return CGRect(x: (bounds.width - w) / 2, y: y, width: w, height: h)
    }

    private func toLoupe(_ p: CGPoint, zone z: Int) -> CGPoint {
        let zr = zoneRect(z), lr = loupeRect(z)
        return CGPoint(x: lr.minX + (p.x - zr.minX) * loupeScale, y: lr.minY + (p.y - zr.minY) * loupeScale)
    }

    private var bandRows: Range<Int> { bandTop..<min(bandTop + 3, Page.rows) }

    private var bandRect: CGRect {
        bandRows.map(Page.rowRect).reduce(CGRect.null) { $0.union($1) }
    }

    private func center(_ t: Target) -> CGPoint { CGPoint(x: t.rect.midX, y: t.rect.midY) }

    /// 요소 높이에 맞춘 라벨 글자 크기
    private func fitFont(_ t: Target) -> CGFloat { min(max(t.rect.height * 0.8, 8), 18) }

    private func makeChoices() -> [Choice] {
        func clicks(_ idx: [Int], font: NSFont, at place: (Target) -> CGPoint) -> [Choice] {
            zip(labels(idx.count), idx).map { Choice(label: $0, center: place(targets[$1]), font: font, action: .click($1)) }
        }
        let all = Array(targets.indices)
        switch strategy {
        case .current:
            return clicks(all, font: Draw.font, at: center)
        case .rows:
            if case .row(let r) = stage {
                return clicks(all.filter { targets[$0].row == r }, font: bold(15), at: center)
            }
            let rows = Array(-1..<Page.rows)
            return zip(labels(rows.count), rows).map { label, r in
                Choice(label: label, center: CGPoint(x: 22, y: Page.rowRect(r).midY), font: bold(15), action: .row(r))
            }
        case .kinds:
            let kind = kinds[kindIndex]
            return clicks(all.filter { kind == nil || targets[$0].kind == kind }, font: kind == nil ? Draw.font : bold(14),
                          at: center)
        case .grow:
            return clicks(all, font: typed.isEmpty ? Draw.font : bold(17), at: center)
        case .loupe:
            if case .zone(let z) = stage {
                let rows = zoneRows(z)
                return clicks(all.filter { rows.contains(targets[$0].row) }, font: bold(15)) { self.toLoupe(self.center($0), zone: z) }
            }
            return zip(labels(zoneCount), 0..<zoneCount).map { label, z in
                Choice(label: label, center: CGPoint(x: 22, y: zoneRect(z).midY), font: bold(22), action: .zone(z))
            }
        case .list:
            let idx = all.filter { targets[$0].row >= 0 && (targets[$0].kind == .title || targets[$0].kind == .comments) }
            return clicks(idx, font: bold(13)) { t in
                CGPoint(x: t.kind == .title ? 926 : 1252, y: Page.rowRect(t.row).midY)
            }
        case .band:
            return clicks(all.filter { bandRows.contains(targets[$0].row) }, font: bold(15), at: center)
        case .fit:
            let idx = all
            return zip(labels(idx.count), idx).map { label, i in
                let t = targets[i]
                let size = fitFont(t)
                // 상자 왼쪽 안쪽에 붙인다
                let x = t.rect.minX + min(t.rect.width / 2, size * 1.05)
                return Choice(label: label, center: CGPoint(x: x, y: t.rect.midY), font: bold(size), action: .click(i))
            }
        }
    }

    // MARK: 장면 (라벨 아래 깔리는 것)

    private func rebuild() {
        choices = makeChoices()
        scene = renderImage(size: bounds.size, scale: scale) { drawScene() }
        sceneSource = scene.flatMap { ScreenSnapshot(image: $0, axFrame: bounds) }.map(GlassSource.init)
        needsDisplay = true
    }

    private var matching: [Choice] { choices.filter { $0.label.hasPrefix(typed) } }

    private func highlight(_ r: CGRect, alpha: CGFloat = 0.16) {
        accent.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -1), xRadius: 4, yRadius: 4).fill()
    }

    private func dim(except hole: CGRect?, alpha: CGFloat) {
        let path = NSBezierPath(rect: bounds)
        if let hole { path.append(NSBezierPath(roundedRect: hole, xRadius: 8, yRadius: 8)) }
        path.windingRule = .evenOdd
        NSColor(white: 1, alpha: alpha).setFill()
        path.fill()
    }

    private func drawScene() {
        guard let page else { return }
        NSImage(cgImage: page, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1,
                                                       respectFlipped: true, hints: nil)
        Draw.glassSource = pageSource
        defer { Draw.glassSource = nil }
        switch strategy {
        case .current:
            break
        case .rows:
            if case .row(let r) = stage {
                dim(except: Page.rowRect(r), alpha: 0.6)
                Draw.glassRing(Page.rowRect(r), color: accent, band: 7)
            } else {
                for r in stride(from: 0, to: Page.rows, by: 2) {
                    NSColor(white: 0, alpha: 0.03).setFill()
                    Page.rowRect(r).fill()
                }
            }
        case .kinds:
            if let kind = kinds[kindIndex] {
                for t in targets where t.kind == kind { highlight(t.rect) }
            }
            chip(kinds.enumerated().map { i, k in (k?.name ?? "전체", i == kindIndex) }, hint: "Tab")
        case .grow:
            if !typed.isEmpty {
                dim(except: nil, alpha: 0.35)
                for c in matching { if case .click(let i) = c.action { highlight(targets[i].rect, alpha: 0.22) } }
            }
        case .loupe:
            if case .zone(let z) = stage {
                NSColor(white: 0, alpha: 0.28).setFill()
                bounds.fill()
                let lr = loupeRect(z)
                let path = NSBezierPath(roundedRect: lr, xRadius: 14, yRadius: 14)
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                NSImage(cgImage: page, size: bounds.size).draw(in: CGRect(x: lr.minX - zoneRect(z).minX * loupeScale,
                                                                          y: lr.minY - zoneRect(z).minY * loupeScale,
                                                                          width: bounds.width * loupeScale,
                                                                          height: bounds.height * loupeScale),
                                                               from: .zero, operation: .sourceOver, fraction: 1,
                                                               respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                Draw.glassRing(lr.insetBy(dx: 4, dy: 4), color: accent, band: 10)
            } else {
                for z in 0..<zoneCount {
                    let r = zoneRect(z).insetBy(dx: 2, dy: 2)
                    let line = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
                    line.setLineDash([8, 5], count: 2, phase: 0)
                    line.lineWidth = 1.5
                    accent.withAlphaComponent(0.6).setStroke()
                    line.stroke()
                }
            }
        case .list:
            let panel = CGRect(x: 908, y: 6, width: 366, height: Page.top + CGFloat(Page.rows) * Page.rowH)
            NSColor(white: 1, alpha: 0.96).setFill()
            NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).fill()
            NSColor(white: 0, alpha: 0.12).setStroke()
            NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).stroke()
            NSAttributedString(string: "제목                                                     댓글",
                               attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                            .foregroundColor: NSColor.secondaryLabelColor])
                .draw(at: CGPoint(x: 944, y: 16))
            for (i, item) in items.prefix(Page.rows).enumerated() {
                let y = Page.rowRect(i).midY - 8
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                NSAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                    .foregroundColor: NSColor.black,
                                                                    .paragraphStyle: style])
                    .draw(in: CGRect(x: 944, y: y, width: 270, height: 17))
                NSAttributedString(string: "\(item.comments)", attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                            .foregroundColor: Page.gray])
                    .draw(at: CGPoint(x: 1218, y: y + 1))
            }
            if !typed.isEmpty {
                for c in matching {
                    guard case .click(let i) = c.action else { continue }
                    let t = targets[i]
                    highlight(t.rect, alpha: 0.25)
                    let line = NSBezierPath()
                    line.move(to: CGPoint(x: t.rect.maxX + 4, y: t.rect.midY))
                    line.line(to: CGPoint(x: c.center.x - 14, y: c.center.y))
                    line.lineWidth = 1.5
                    accent.withAlphaComponent(0.7).setStroke()
                    line.stroke()
                }
            }
        case .band:
            dim(except: bandRect, alpha: 0.5)
            Draw.glassRing(bandRect, color: accent, band: 8)
        case .fit:
            for t in targets {
                let r = t.rect.insetBy(dx: -3, dy: -1)
                let corner = min(r.height / 2, 5)
                if let glass = pageSource?.edge(r, ring: false, width: min(r.height / 2, 4), cornerRadius: corner,
                                                tint: accent, tintAlpha: 0.1) {
                    NSImage(cgImage: glass.image, size: glass.frame.size).draw(
                        in: glass.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                accent.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: r, xRadius: corner, yRadius: corner).fill()
                accent.withAlphaComponent(0.45).setStroke()
                NSBezierPath(roundedRect: r, xRadius: corner, yRadius: corner).stroke()
            }
        }
    }

    /// 위쪽에 지금 고른 종류를 보여주는 칩
    private func chip(_ items: [(String, Bool)], hint: String) {
        var x: CGFloat = 520
        for (name, on) in items {
            let s = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: on ? .bold : .regular),
                                                                  .foregroundColor: on ? NSColor.white : NSColor.black])
            let r = CGRect(x: x, y: 9, width: s.size().width + 16, height: 20)
            (on ? accent : NSColor(white: 1, alpha: 0.85)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
            s.draw(at: CGPoint(x: r.minX + 8, y: r.minY + 3))
            x = r.maxX + 4
        }
        NSAttributedString(string: hint, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white])
            .draw(at: CGPoint(x: x + 4, y: 12))
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        guard let scene else { return }
        NSImage(cgImage: scene, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1,
                                                        respectFlipped: true, hints: nil)
        Draw.glassSource = sceneSource
        for c in matching {
            Draw.pill(c.label.uppercased(), typedCount: typed.count, center: c.center, within: bounds, font: c.font)
        }
        Draw.glassSource = nil
        if let flash {
            let r = targets[flash].rect.insetBy(dx: -5, dy: -3)
            accent.setStroke()
            let p = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            p.lineWidth = 3
            p.stroke()
        }
        drawHUD()
    }

    private func drawHUD() {
        let bar = CGRect(x: 0, y: bounds.height - 74, width: bounds.width, height: 74)
        NSColor(white: 0.12, alpha: 0.96).setFill()
        bar.fill()
        var x: CGFloat = 16
        for s in Strategy.allCases {
            let on = s == strategy
            let str = NSAttributedString(string: "\(s.rawValue + 1) \(s.title)",
                                         attributes: [.font: NSFont.systemFont(ofSize: 13, weight: on ? .bold : .regular),
                                                      .foregroundColor: on ? NSColor.black : NSColor.white])
            let r = CGRect(x: x, y: bar.minY + 10, width: str.size().width + 18, height: 24)
            if on {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
            }
            str.draw(at: CGPoint(x: r.minX + 9, y: r.minY + 4))
            x = r.maxX + 6
        }
        let visible = matching.count
        let length = choices.first?.label.count ?? 0
        let info = "\(strategy.summary)   ·   지금 라벨 \(visible)개, \(length)글자"
        NSAttributedString(string: toast ?? info,
                           attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: toast == nil ? NSColor(white: 0.85, alpha: 1) : NSColor.systemGreen])
            .draw(at: CGPoint(x: 16, y: bar.minY + 44))
        let keys = NSAttributedString(string: "글자 입력 · ⌫ 뒤로 · Esc 처음 · 1–8 방식",
                                      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.6, alpha: 1)])
        keys.draw(at: CGPoint(x: bounds.width - keys.size().width - 16, y: bar.minY + 45))
    }

    // MARK: 입력

    private func perform(_ action: Action) {
        typed = ""
        switch action {
        case .row(let r): stage = .row(r)
        case .zone(let z): stage = .zone(z)
        case .click(let i):
            stage = .start
            flash = i
            let t = targets[i]
            toast = "클릭 → \(t.kind.name): \(t.text)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                guard let self, flash == i else { return }
                flash = nil
                toast = nil
                needsDisplay = true
            }
        }
        rebuild()
    }

    func type(_ ch: Character) {
        let next = typed + String(ch)
        let hits = choices.filter { $0.label.hasPrefix(next) }
        guard !hits.isEmpty else { return NSSound.beep() }
        typed = next
        if hits.count == 1, hits[0].label == next { return perform(hits[0].action) }
        rebuild()
    }

    override func keyDown(with event: NSEvent) {
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7]
        if let n = digits[event.keyCode], let s = Strategy(rawValue: n) { return set(s) }
        switch event.keyCode {
        case 53:
            typed = ""
            stage = .start
            rebuild()
        case 51:
            if !typed.isEmpty { typed.removeLast() } else { stage = .start }
            rebuild()
        case 48 where strategy == .kinds:
            kindIndex = (kindIndex + (event.modifierFlags.contains(.shift) ? kinds.count - 1 : 1)) % kinds.count
            typed = ""
            rebuild()
        case 125 where strategy == .band, 126 where strategy == .band:
            bandTop = min(max(bandTop + (event.keyCode == 125 ? 1 : -1), 0), Page.rows - 3)
            typed = ""
            rebuild()
        default:
            if let ch = KeyTranslator.character(for: event.keyCode), alphabet.contains(ch) { type(ch) }
        }
    }

    /// 확인용: 지금 화면을 PNG 로
    func shot(_ path: String) {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func scripted(_ s: Strategy, keys: String = "", band: Int = 0, kind: Int = 0) {
        set(s)
        bandTop = band
        kindIndex = kind
        rebuild()
        for k in keys { type(k) }
    }

    /// 확인용: index 번째 라벨
    func firstLabelOf(index: Int) -> String { choices.isEmpty ? "" : choices[min(index, choices.count - 1)].label }
}

// MARK: - 실행

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--shots"), i + 1 < args.count {
    let dir = args[i + 1]
    let view = HNDemo(frame: NSRect(origin: .zero, size: Page.size))
    view.prepare(scale: 1)
    let f = String(Config.labelAlphabet.first ?? "f")
    let cases: [(String, Strategy, String, Int, Int)] = [
        ("1-current", .current, "", 0, 0), ("2-rows", .rows, "", 0, 0), ("2-rows-b", .rows, "_row", 0, 0),
        ("3-kinds", .kinds, "", 0, 0), ("3-kinds-b", .kinds, "", 0, 1), ("4-grow", .grow, f, 0, 0),
        ("5-loupe", .loupe, "", 0, 0), ("5-loupe-b", .loupe, "_zone", 0, 0), ("6-list", .list, f, 0, 0),
        ("7-band", .band, "", 6, 0), ("8-fit", .fit, "", 0, 0),
    ]
    for (name, s, keys, band, kind) in cases {
        view.scripted(s, band: band, kind: kind)
        if keys == "_row" || keys == "_zone" {
            // 줄·구역 라벨 하나를 끝까지 쳐서 다음 단계로
            let label = view.firstLabelOf(index: keys == "_row" ? 4 : 3)
            for k in label { view.type(k) }
        } else {
            for k in keys { view.type(k) }
        }
        view.shot("\(dir)/\(name).png")
    }
    exit(0)
}

final class AppDelegateDemo: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegateDemo()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
appItem.submenu?.addItem(withTitle: "닫기", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
app.mainMenu = menu
let window = NSWindow(contentRect: NSRect(origin: .zero, size: Page.size), styleMask: [.titled, .closable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "Hanmium · 링크 많은 페이지 라벨 예시 (Hacker News)"
let view = HNDemo(frame: NSRect(origin: .zero, size: Page.size))
window.contentView = view
window.center()
view.prepare(scale: window.backingScaleFactor)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
app.run()
