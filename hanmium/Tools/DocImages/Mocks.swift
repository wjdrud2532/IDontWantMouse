import AppKit

// README 용 가짜 화면: VS Code·Slack 과 비슷한 화면을 지어낸 내용으로 그린다(실제 화면·대화·코드가 아님).
// 그리기는 위가 0 인 좌표(포인트)로 하고, 라벨을 붙일 자리(targets)와 스크롤 영역(areas)을 함께 돌려준다.

func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func fill(_ r: CGRect, _ c: NSColor, radius: CGFloat = 0) {
    c.setFill()
    if radius > 0 { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() } else { r.fill() }
}

@discardableResult
func label(_ s: String, _ size: CGFloat, _ color: NSColor, _ p: CGPoint, weight: NSFont.Weight = .regular,
           mono: Bool = false) -> CGRect {
    let font: NSFont = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    a.draw(at: p)
    return CGRect(origin: p, size: a.size())
}

func symbol(_ name: String, _ rect: CGRect, _ color: NSColor) {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: rect.height * 0.8, weight: .regular)) else { return }
    let tinted = NSImage(size: img.size, flipped: false) { r in
        img.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    let fit = CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
    tinted.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

/// 영역 안만 그리고, 내용을 offset 만큼 위로 민다(스크롤)
func clipped(_ r: CGRect, offset: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: r).addClip()
    let t = NSAffineTransform()
    t.translateX(by: 0, yBy: -offset)
    t.concat()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Slack 같은 화면

struct SlackState {
    var channelsOffset: CGFloat = 0
    var messagesOffset: CGFloat = 0
    var threadOffset: CGFloat = 0
    var channel = "dev"
}

struct MockScreen {
    var targets: [CGRect] = []
    var areas: [CGRect] = []
    /// 이름으로 찾을 자리 (채널 등)
    var named: [String: CGRect] = [:]
}

enum SlackMock {
    static let size = CGSize(width: 1000, height: 620)
    static let channels = ["general", "dev", "design", "release", "qa", "random", "help-macos", "infra", "frontend",
                           "backend", "docs", "standup", "announcements", "music"]
    static let people = ["Alex Kim", "Mina Park", "Jun Lee", "Sora Choi", "Theo Han", "Yuna Seo"]
    static let messages: [(String, Int, String, [String])] = [
        ("Alex Kim", 0x2E7D32, "09:58", ["좋은 아침이에요 ☀️ 오늘 배포 일정 공유드릴게요."]),
        ("Mina Park", 0x6A1B9A, "10:04", ["스크롤 성능 측정 결과 정리했어요.", "라벨 표시까지 80ms 안팎으로 줄었습니다."]),
        ("Jun Lee", 0x1565C0, "10:12", ["PR #482 리뷰 남겼어요. 테스트 하나만 더 추가하면 좋겠습니다."]),
        ("Sora Choi", 0xC62828, "10:19", ["디자인 시안 업데이트했습니다 🎨", "피드백은 #design 에 부탁드려요."]),
        ("Alex Kim", 0x2E7D32, "10:30", ["오후 3시에 release/1.4 배포합니다.", "체크리스트는 스레드에 정리할게요."]),
        ("Theo Han", 0xEF6C00, "10:41", ["빌드 다시 초록색이에요 ✅"]),
        ("Yuna Seo", 0x00838F, "10:52", ["문서 링크 업데이트했어요 → docs/release-notes"]),
        ("Jun Lee", 0x1565C0, "11:05", ["점심 뭐 드실래요? 🍜"]),
        ("Mina Park", 0x6A1B9A, "11:20", ["회의록 올렸습니다. 액션 아이템 3개예요."]),
        ("Sora Choi", 0xC62828, "11:34", ["아이콘 세트 최종본 공유드려요."]),
        ("Theo Han", 0xEF6C00, "11:47", ["모니터링 대시보드 정상입니다 📈"]),
        ("Alex Kim", 0x2E7D32, "12:02", ["배포 전 마지막 확인 부탁드려요 🙏"]),
    ]
    static let thread: [(String, Int, String, [String])] = [
        ("Alex Kim", 0x2E7D32, "10:30", ["오후 3시에 release/1.4 배포합니다.", "체크리스트는 스레드에 정리할게요."]),
        ("Alex Kim", 0x2E7D32, "10:31", ["1. DB 마이그레이션 확인"]),
        ("Jun Lee", 0x1565C0, "10:33", ["2. 롤백 스크립트 준비 완료 👍"]),
        ("Mina Park", 0x6A1B9A, "10:36", ["3. 공지 초안 작성했어요."]),
        ("Theo Han", 0xEF6C00, "10:40", ["4. 모니터링 알림 켜 둘게요."]),
        ("Sora Choi", 0xC62828, "10:44", ["5. 릴리스 노트 이미지 준비 완료"]),
        ("Yuna Seo", 0x00838F, "10:48", ["6. 문서 링크 확인했습니다."]),
        ("Jun Lee", 0x1565C0, "10:49", ["스테이징에서 한 번 더 돌려 볼게요."]),
        ("Mina Park", 0x6A1B9A, "10:50", ["공지 채널에도 올려 둘게요 📣"]),
        ("Theo Han", 0xEF6C00, "10:50", ["알림 채널 연결 확인했습니다."]),
        ("Alex Kim", 0x2E7D32, "10:51", ["모두 감사합니다! 🚀", "3시에 다시 모여요."]),
    ]

    static let sidebar = CGRect(x: 64, y: 86, width: 236, height: 534)
    static let messagesArea = CGRect(x: 300, y: 88, width: 420, height: 468)
    static let threadArea = CGRect(x: 721, y: 88, width: 279, height: 468)

    static func draw(_ st: SlackState) -> MockScreen {
        var m = MockScreen()
        m.areas = [sidebar, messagesArea, threadArea]
        let plum = hex(0x3F0E40), plumDark = hex(0x350D36)
        // 위 막대, 작업 공간 막대
        fill(CGRect(x: 0, y: 0, width: size.width, height: 38), plumDark)
        let search = CGRect(x: 330, y: 7, width: 340, height: 24)
        fill(search, NSColor(white: 1, alpha: 0.18), radius: 6)
        label("Hanmium 팀 검색", 12, NSColor(white: 1, alpha: 0.75), CGPoint(x: search.minX + 28, y: search.minY + 4))
        symbol("magnifyingglass", CGRect(x: search.minX + 6, y: search.minY + 4, width: 16, height: 16), NSColor(white: 1, alpha: 0.75))
        m.targets.append(search)
        fill(CGRect(x: 0, y: 38, width: 64, height: size.height - 38), plumDark)
        let ws = CGRect(x: 14, y: 52, width: 36, height: 36)
        fill(ws, .white, radius: 8)
        label("H", 18, plum, CGPoint(x: ws.minX + 11, y: ws.minY + 7), weight: .heavy)
        m.targets.append(ws)
        for (i, s) in ["house.fill", "bubble.left.and.bubble.right", "bell", "ellipsis"].enumerated() {
            let r = CGRect(x: 18, y: 108 + CGFloat(i) * 52, width: 28, height: 28)
            symbol(s, r, NSColor(white: 1, alpha: 0.8))
            m.targets.append(r)
        }
        // 사이드바
        fill(CGRect(x: 64, y: 38, width: 236, height: size.height - 38), plum)
        let wsName = label("Hanmium 팀 ⌄", 15, .white, CGPoint(x: 80, y: 50), weight: .bold)
        m.targets.append(wsName)
        fill(CGRect(x: 64, y: 85, width: 236, height: 1), NSColor(white: 1, alpha: 0.12))
        clipped(sidebar, offset: st.channelsOffset) {
            var y: CGFloat = 96
            label("채널", 13, NSColor(white: 1, alpha: 0.7), CGPoint(x: 80, y: y), weight: .semibold)
            y += 26
            for c in channels {
                let row = CGRect(x: 72, y: y - 3, width: 220, height: 26)
                if c == st.channel { fill(row, hex(0x1164A3), radius: 6) }
                let r = label("#  \(c)", 14, c == st.channel ? .white : NSColor(white: 1, alpha: 0.78), CGPoint(x: 82, y: y),
                              weight: c == st.channel ? .bold : .regular)
                let shown = r.offsetBy(dx: 0, dy: -st.channelsOffset)
                if sidebar.contains(CGPoint(x: shown.midX, y: shown.midY)) {
                    m.targets.append(shown)
                    m.named[c] = shown
                }
                y += 28
            }
            y += 10
            label("다이렉트 메시지", 13, NSColor(white: 1, alpha: 0.7), CGPoint(x: 80, y: y), weight: .semibold)
            y += 26
            for (i, p) in people.enumerated() {
                fill(CGRect(x: 82, y: y + 2, width: 16, height: 16), hex([0x2E7D32, 0x6A1B9A, 0x1565C0, 0xC62828, 0xEF6C00, 0x00838F][i]), radius: 4)
                let r = label(p, 14, NSColor(white: 1, alpha: 0.78), CGPoint(x: 106, y: y))
                let shown = r.offsetBy(dx: 0, dy: -st.channelsOffset)
                if sidebar.contains(CGPoint(x: shown.midX, y: shown.midY)) { m.targets.append(shown) }
                y += 28
            }
        }
        // 메시지 영역
        fill(CGRect(x: 300, y: 38, width: 700, height: size.height - 38), .white)
        let header = label("# \(st.channel) ⌄", 17, .black, CGPoint(x: 318, y: 52), weight: .heavy)
        m.targets.append(header)
        let members = CGRect(x: 640, y: 52, width: 64, height: 24)
        fill(members, NSColor(white: 0.95, alpha: 1), radius: 6)
        label("👥 12", 12, .darkGray, CGPoint(x: members.minX + 10, y: members.minY + 4))
        m.targets.append(members)
        fill(CGRect(x: 300, y: 87, width: 420, height: 1), NSColor(white: 0.88, alpha: 1))
        func drawMessages(_ list: [(String, Int, String, [String])], in area: CGRect, offset: CGFloat, threadLink: Int?) {
            clipped(area, offset: offset) {
                var y = area.minY + 12
                for (i, msg) in list.enumerated() {
                    fill(CGRect(x: area.minX + 16, y: y + 2, width: 34, height: 34), hex(msg.1), radius: 7)
                    label(String(msg.0.prefix(1)), 15, .white, CGPoint(x: area.minX + 27, y: y + 9), weight: .bold)
                    let name = label(msg.0, 14, .black, CGPoint(x: area.minX + 60, y: y), weight: .bold)
                    label(msg.2, 11, .gray, CGPoint(x: name.maxX + 8, y: y + 3))
                    let shownName = name.offsetBy(dx: 0, dy: -offset)
                    if area.contains(CGPoint(x: shownName.midX, y: shownName.midY)) { m.targets.append(shownName) }
                    var ty = y + 20
                    for line in msg.3 {
                        label(line, 14, NSColor(white: 0.15, alpha: 1), CGPoint(x: area.minX + 60, y: ty))
                        ty += 20
                    }
                    if threadLink == i {
                        let link = label("💬 댓글 6개  ·  마지막 댓글 10:51", 12, hex(0x1264A3), CGPoint(x: area.minX + 60, y: ty + 2),
                                         weight: .semibold)
                        let shown = link.offsetBy(dx: 0, dy: -offset)
                        if area.contains(CGPoint(x: shown.midX, y: shown.midY)) { m.targets.append(shown) }
                        ty += 22
                    }
                    y = ty + 14
                }
            }
        }
        drawMessages(messages, in: messagesArea, offset: st.messagesOffset, threadLink: 4)
        let composer = CGRect(x: 316, y: 562, width: 390, height: 44)
        NSColor(white: 0.75, alpha: 1).setStroke()
        NSBezierPath(roundedRect: composer, xRadius: 8, yRadius: 8).stroke()
        label("#\(st.channel)에 메시지 보내기", 14, .gray, CGPoint(x: composer.minX + 12, y: composer.minY + 13))
        m.targets.append(composer)
        // 스레드
        fill(CGRect(x: 720, y: 38, width: 1, height: size.height - 38), NSColor(white: 0.85, alpha: 1))
        label("스레드", 16, .black, CGPoint(x: 736, y: 52), weight: .heavy)
        label("# \(st.channel)", 12, .gray, CGPoint(x: 792, y: 56))
        let close = CGRect(x: 966, y: 52, width: 22, height: 22)
        symbol("xmark", close, .darkGray)
        m.targets.append(close)
        fill(CGRect(x: 721, y: 87, width: 279, height: 1), NSColor(white: 0.88, alpha: 1))
        drawMessages(thread, in: threadArea, offset: st.threadOffset, threadLink: nil)
        let reply = CGRect(x: 734, y: 562, width: 254, height: 44)
        NSBezierPath(roundedRect: reply, xRadius: 8, yRadius: 8).stroke()
        label("답장…", 14, .gray, CGPoint(x: reply.minX + 12, y: reply.minY + 13))
        m.targets.append(reply)
        return m
    }
}

// MARK: - VS Code 같은 화면

enum CodeMock {
    static let size = CGSize(width: 1000, height: 620)

    static func draw() -> MockScreen {
        var m = MockScreen()
        fill(CGRect(origin: .zero, size: size), hex(0x1E1E1E))
        // 제목 막대
        fill(CGRect(x: 0, y: 0, width: size.width, height: 30), hex(0x3C3C3C))
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            fill(CGRect(x: 12 + CGFloat(i) * 20, y: 9, width: 12, height: 12), hex(c), radius: 6)
        }
        label("LiquidGlass.swift — Hanmium", 12, NSColor(white: 0.8, alpha: 1), CGPoint(x: 410, y: 8))
        // 활동 막대
        fill(CGRect(x: 0, y: 30, width: 48, height: size.height - 54), hex(0x333333))
        for (i, s) in ["doc.on.doc", "magnifyingglass", "arrow.triangle.branch", "play.circle", "square.grid.2x2"].enumerated() {
            let r = CGRect(x: 12, y: 44 + CGFloat(i) * 48, width: 24, height: 24)
            symbol(s, r, i == 0 ? .white : NSColor(white: 0.55, alpha: 1))
            m.targets.append(r)
        }
        for (i, s) in ["person.crop.circle", "gearshape"].enumerated() {
            let r = CGRect(x: 12, y: 516 + CGFloat(i) * 40, width: 24, height: 24)
            symbol(s, r, NSColor(white: 0.55, alpha: 1))
            m.targets.append(r)
        }
        // 탐색기
        fill(CGRect(x: 48, y: 30, width: 240, height: size.height - 54), hex(0x252526))
        label("탐색기", 11, NSColor(white: 0.75, alpha: 1), CGPoint(x: 66, y: 40), weight: .semibold)
        label("⌄ HANMIUM", 11, NSColor(white: 0.85, alpha: 1), CGPoint(x: 58, y: 64), weight: .bold)
        let files: [(String, Int, Bool)] = [("⌄ Sources/Hanmium", 0, false), ("AX.swift", 1, false), ("AppDelegate.swift", 1, false),
                                            ("ClickMode.swift", 1, false), ("Config.swift", 1, false), ("Droplet.swift", 1, false),
                                            ("GlassGPU.swift", 1, false), ("LiquidGlass.swift", 1, true), ("Overlay.swift", 1, false),
                                            ("ScrollMode.swift", 1, false), ("Settings.swift", 1, false), ("› Tools", 0, false),
                                            ("Package.swift", 0, false), ("README.md", 0, false), ("TESTING.md", 0, false)]
        for (i, f) in files.enumerated() {
            let y = 88 + CGFloat(i) * 22
            if f.2 { fill(CGRect(x: 48, y: y - 2, width: 240, height: 22), hex(0x37373D)) }
            let color: NSColor = f.0.hasSuffix(".swift") ? hex(0xF05138) : f.0.hasSuffix(".md") ? hex(0x519ABA) : NSColor(white: 0.8, alpha: 1)
            let x: CGFloat = 62 + CGFloat(f.1) * 14
            if f.0.contains(".") { label("◆", 9, color, CGPoint(x: x, y: y + 3)) }
            let r = label(f.0, 13, NSColor(white: 0.85, alpha: 1), CGPoint(x: x + (f.0.contains(".") ? 14 : 0), y: y))
            m.targets.append(r)
        }
        // 탭
        fill(CGRect(x: 288, y: 30, width: 712, height: 35), hex(0x2D2D2D))
        var tx: CGFloat = 288
        for (i, t) in ["LiquidGlass.swift", "ScrollMode.swift", "README.md"].enumerated() {
            let w: CGFloat = 160
            fill(CGRect(x: tx, y: 30, width: w, height: 35), i == 0 ? hex(0x1E1E1E) : hex(0x2D2D2D))
            let r = label(t, 13, i == 0 ? .white : NSColor(white: 0.6, alpha: 1), CGPoint(x: tx + 14, y: 39))
            m.targets.append(r)
            let x = CGRect(x: tx + w - 26, y: 40, width: 14, height: 14)
            symbol("xmark", x, NSColor(white: 0.6, alpha: 1))
            m.targets.append(x)
            tx += w
        }
        for (i, s) in ["play", "rectangle.split.2x1", "ellipsis"].enumerated() {
            let r = CGRect(x: 920 + CGFloat(i) * 26, y: 40, width: 16, height: 16)
            symbol(s, r, NSColor(white: 0.8, alpha: 1))
            m.targets.append(r)
        }
        // 경로
        var bx: CGFloat = 300
        for (i, b) in ["Sources", "Hanmium", "LiquidGlass.swift", "render(_:from:forceDark:)"].enumerated() {
            let r = label(b, 12, NSColor(white: 0.7, alpha: 1), CGPoint(x: bx, y: 70))
            m.targets.append(r)
            bx = r.maxX + (i < 3 ? 6 : 0)
            if i < 3 { bx = label("›", 12, NSColor(white: 0.5, alpha: 1), CGPoint(x: bx, y: 70)).maxX + 6 }
        }
        // 코드
        let kw = hex(0x569CD6), ty = hex(0x4EC9B0), st = hex(0xCE9178), cm = hex(0x6A9955), pl = hex(0xD4D4D4), fn = hex(0xDCDCAA), nu = hex(0xB5CEA8)
        let code: [[(String, NSColor)]] = [
            [("/// 볼록 스퀘어클 단면 + 스넬 법칙으로 굴절 이동 거리를 구한다", cm)],
            [("struct ", kw), ("Profile", ty), (" {", pl)],
            [("    private let ", kw), ("table", pl), (": [", pl), ("CGFloat", ty), ("]", pl)],
            [("", pl)],
            [("    init", kw), ("(bezel: ", pl), ("CGFloat", ty), (", thickness: ", pl), ("CGFloat", ty), (") {", pl)],
            [("        table", pl), (" = (", pl), ("0", nu), ("..<", pl), ("128", nu), (").", pl), ("map", fn), (" { i ", pl), ("in", kw)],
            [("            let ", kw), ("u = ", pl), ("1", nu), (" - ", pl), ("CGFloat", ty), ("(i) / ", pl), ("127", nu)],
            [("            let ", kw), ("height = thickness * ", pl), ("pow", fn), ("(", pl), ("1", nu), (" - u*u*u*u, ", pl), ("0.25", nu), (")", pl)],
            [("            let ", kw), ("incident = ", pl), ("atan", fn), ("(slope(u))", pl)],
            [("            return ", kw), ("height * ", pl), ("tan", fn), ("(incident - ", pl), ("asin", fn), ("(", pl), ("sin", fn), ("(incident) / ", pl), ("1.5", nu), ("))", pl)],
            [("        }", pl)],
            [("    }", pl)],
            [("}", pl)],
            [("", pl)],
            [("let ", kw), ("look = ", pl), ("LiquidGlass", ty), (".", pl), ("render", fn), ("(rect, from: snapshot, forceDark: ", pl), ("false", kw), (")", pl)],
            [("print", fn), ("(", pl), ("\"라벨 250개: 4.5ms\"", st), (")", pl)],
        ]
        for (i, line) in code.enumerated() {
            let y = 96 + CGFloat(i) * 20
            label(String(format: "%3d", 40 + i), 12, NSColor(white: 0.45, alpha: 1), CGPoint(x: 296, y: y + 1), mono: true)
            var x: CGFloat = 340
            for (s, c) in line { x = label(s, 13, c, CGPoint(x: x, y: y), mono: true).maxX }
        }
        // 아래 패널
        fill(CGRect(x: 288, y: 430, width: 712, height: 1), hex(0x3C3C3C))
        var px: CGFloat = 300
        for (i, t) in ["문제", "출력", "디버그 콘솔", "터미널"].enumerated() {
            let r = label(t, 12, i == 3 ? .white : NSColor(white: 0.6, alpha: 1), CGPoint(x: px, y: 440))
            if i == 3 { fill(CGRect(x: r.minX, y: r.maxY + 3, width: r.width, height: 1.5), .white) }
            m.targets.append(r)
            px = r.maxX + 22
        }
        for (i, s) in ["plus", "trash", "chevron.up", "xmark"].enumerated() {
            let r = CGRect(x: 896 + CGFloat(i) * 26, y: 440, width: 16, height: 16)
            symbol(s, r, NSColor(white: 0.75, alpha: 1))
            m.targets.append(r)
        }
        for (i, line) in ["$ swift build -c release", "Building for production...", "Build complete! (11.52s)", "$ Tools/check-apps.sh",
                          "모두 통과", "$ ▍"].enumerated() {
            label(line, 12, i == 2 || i == 4 ? hex(0x4EC9B0) : NSColor(white: 0.85, alpha: 1), CGPoint(x: 300, y: 470 + CGFloat(i) * 18),
                  mono: true)
        }
        // 상태 막대
        fill(CGRect(x: 0, y: 596, width: size.width, height: 24), hex(0x007ACC))
        var sx: CGFloat = 10
        for t in ["⎇ main", "⊗ 0  ⚠ 0"] {
            let r = label(t, 12, .white, CGPoint(x: sx, y: 600))
            m.targets.append(r)
            sx = r.maxX + 18
        }
        var ex = size.width - 10
        for t in ["Swift", "UTF-8", "공백: 4", "줄 42, 열 18"] {
            let w = NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 12)]).size().width
            ex -= w
            let r = label(t, 12, .white, CGPoint(x: ex, y: 600))
            m.targets.append(r)
            ex -= 18
        }
        return m
    }
}
