import AppKit
import ScreenCaptureKit

/// WezTerm 은 AX 로 분할 패널을 알려주지 않아서 `wezterm cli list` 의 배치(칸 단위)를 화면 좌표로 바꾼다.
enum WezTerm {
    static let bundleID = "com.github.wez.wezterm"

    struct Pane: Decodable {
        struct Size: Decodable {
            let rows: Int
            let cols: Int
            let pixel_width: Int
            let pixel_height: Int
            let dpi: Int?
        }

        let pane_id: Int
        let window_id: Int
        let tab_id: Int
        let size: Size
        let left_col: Int
        let top_row: Int
        let title: String
        let window_title: String
        let is_active: Bool
    }

    private static let executables = [
        "/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm", "/Applications/WezTerm.app/Contents/MacOS/wezterm",
    ]

    static func panes() -> [Pane] {
        (try? JSONDecoder().decode([Pane].self, from: cli(["list", "--format", "json"]))) ?? []
    }

    private struct Client: Decodable {
        let focused_pane_id: Int?
    }

    /// 지금 키 입력을 받는 패널(앞에 있는 WezTerm 창의 활성 패널)
    static func focusedPaneID() -> Int? {
        let clients = (try? JSONDecoder().decode([Client].self, from: cli(["list-clients", "--format", "json"]))) ?? []
        return clients.lazy.compactMap(\.focused_pane_id).first
    }

    private static func cli(_ args: [String]) -> Data {
        guard let process = cliProcess(args) else { return Data() }
        let out = Pipe()
        process.standardOutput = out
        do { try process.run() } catch { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Log.write("wezterm cli \(args.first ?? "") 실패 (종료 코드 \(process.terminationStatus))")
        }
        return data
    }

    /// 화면에 떠 있는 WezTerm 에 붙는 `wezterm cli`.
    /// WezTerm 안의 셸에서 Hanmium 을 띄우면 그 WezTerm 의 소켓 주소(WEZTERM_UNIX_SOCKET)를 물려받는데,
    /// 그 WezTerm 을 끄고 다시 켜면 주소가 사라진다. 그러면 CLI 가 없는 소켓에 붙으려고 mux 서버를 띄우고
    /// 5초쯤 기다리다 실패해서, 패널을 못 찾고 모드도 5초 늦게 열렸다. 그래서 물려받은 주소는 버리고
    /// 지금 떠 있는 WezTerm 을 CLI 가 직접 찾게 하고, 못 찾으면 서버를 띄우지 않고 바로 끝낸다.
    private static func cliProcess(_ args: [String]) -> Process? {
        guard let exe = executables.first(where: FileManager.default.isExecutableFile) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["cli", "--no-auto-start"] + args
        var env = ProcessInfo.processInfo.environment
        env["WEZTERM_UNIX_SOCKET"] = nil
        env["WEZTERM_PANE"] = nil
        process.environment = env
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// 창 하나에 지금 보이는 탭의 패널들과 그 창의 탭 수
    struct VisibleTab {
        let panes: [Pane]
        let tabCount: Int
    }

    /// AX 창마다 짝이 되는 WezTerm 창과 그 창에 보이는 탭.
    /// CLI 의 창 제목은 새 창이면 비어 있고, 프로그램이 제목을 바꾸면 패널 제목과 같아지는 등 화면의 창 제목과
    /// 맞지 않을 때가 많아서 제목만으로 짝을 짓지 않는다. 탭 내용 크기(칸 수 × 칸 크기)가 창 크기에 들어맞는지로
    /// 짝을 짓고, 제목이 맞으면 그쪽을 먼저 고른다.
    /// wezterm cli 두 번(list, list-clients)을 미리 동시에 시작해 둔다. AX 를 훑는 동안 돌고, wait() 로 받는다.
    final class Prefetch {
        private let group = DispatchGroup()
        private var panes: [Pane] = []
        private var focused: Int?

        init() {
            DispatchQueue.global(qos: .userInteractive).async(group: group) { self.panes = WezTerm.panes() }
            DispatchQueue.global(qos: .userInteractive).async(group: group) { self.focused = WezTerm.focusedPaneID() }
        }

        func wait() -> (panes: [Pane], focused: Int?) {
            group.wait()
            return (panes, focused)
        }
    }

    /// 화면마다 AX 좌표 틀과 배율. NSScreen 은 메인 스레드에서 읽어 넘긴다(TreeBuilder.forFrontmost).
    struct ScreenScales {
        let items: [(frame: CGRect, scale: CGFloat)]

        static func current() -> ScreenScales {
            ScreenScales(items: NSScreen.screens.map { (Screens.axFrame($0), $0.backingScaleFactor) })
        }

        /// 창 가운데가 있는 화면의 배율
        func scale(for r: CGRect) -> CGFloat {
            let mid = CGPoint(x: r.midX, y: r.midY)
            return items.first { $0.frame.contains(mid) }?.scale ?? items.first?.scale ?? 1
        }
    }

    static func visibleTabs(for windows: [Element], in panes: [Pane], focused known: Int?? = nil,
                            scales: ScreenScales = .current()) -> [VisibleTab?] {
        guard !panes.isEmpty else { return windows.map { _ in nil } }
        let focused = known ?? focusedPaneID()
        let config = Config.load()
        let byWindow = Dictionary(grouping: panes, by: \.window_id)
        var free = Set(byWindow.keys)
        return windows.map { window in
            let title = normalized(window.title ?? "")
            let scored = free.compactMap { id -> (score: CGFloat, tab: VisibleTab, id: Int)? in
                guard let mine = byWindow[id], let first = mine.first else { return nil }
                let tabs = Dictionary(grouping: mine, by: \.tab_id)
                // 보이는 탭: 키 입력을 받는 패널이 든 탭 > 활성 패널 제목이 창 제목과 같은 탭 > 첫 탭
                let visible = mine.first { $0.pane_id == focused }?.tab_id
                    ?? mine.first { $0.is_active && !title.isEmpty && normalized($0.title) == title }?.tab_id
                    ?? first.tab_id
                guard let tab = tabs[visible],
                      let layout = layout(tab, tabCount: tabs.count, window: window.frame,
                                          scale: scales.scale(for: window.frame), config: config) else { return nil }
                let titled = !title.isEmpty && (normalized(first.window_title) == title
                    || tab.contains { $0.is_active && normalized($0.title) == title })
                return ((titled ? 0 : 10000) + layout.score, VisibleTab(panes: tab, tabCount: tabs.count), id)
            }
            guard let best = scored.min(by: { $0.score < $1.score }) else {
                note("WezTerm 창 짝 없음: AX 창 \(window.frame) 에 맞는 CLI 창이 없음 (CLI 창 \(byWindow.keys.sorted()))")
                return nil
            }
            free.remove(best.id)
            return best.tab
        }
    }

    /// 탭 하나를 창에 놓은 모양. 칸 크기와 첫 칸 왼쪽 위는 포인트(AX 좌표).
    struct Layout {
        let cellW: CGFloat
        let cellH: CGFloat
        let origin: CGPoint
        /// 축마다 CLI 픽셀 값을 몇으로 나눠 창에 맞췄는지. nil 이면 맞는 값이 없어 창 길이를 칸 수로 나눈 추정이다.
        let divisorX: CGFloat?
        let divisorY: CGFloat?
        /// 칸을 채우고 남는 폭 + 높이(탭 바 포함)
        let slack: CGFloat

        /// 여러 창을 짝지을 때 작을수록 맞다. 추정한 축은 크게 깎는다.
        var score: CGFloat { slack + (divisorX == nil ? 1000 : 0) + (divisorY == nil ? 1000 : 0) }
    }

    /// 칸 수(정수)와 실제 창 크기를 기준으로 칸 크기를 축마다 따로 정한다.
    /// CLI 의 픽셀 값(pixel_width·pixel_height)은 화면을 옮긴 뒤 틀린 채 남을 때가 있다. 1배 화면인데 가로만
    /// 2배 값이고 dpi 도 패널마다 72·144 로 섞였던 적이 있다(2026-11-11). 그래서 화면 배율로 나눈 값이 창에 맞는지
    /// 보고, 안 맞으면 다른 배율(1·2·3)로 나눠 보고, 그래도 안 맞으면 창 길이를 칸 수로 나눈다.
    /// WezTerm 은 앞쪽 여백 다음부터 칸을 채우고 칸에 못 미치는 나머지를 뒤쪽에 남기므로, 맞는 칸 크기라면
    /// 창 길이 − 양쪽 여백 − 칸 수 × 칸 크기 가 0 이상 한 칸 미만이다(위쪽은 탭 바 높이만큼 더).
    static func layout(_ tab: [Pane], tabCount: Int, window f: CGRect, scale: CGFloat, config: Config) -> Layout? {
        let cols = tab.map { $0.left_col + $0.size.cols }.max() ?? 0
        let rows = tab.map { $0.top_row + $0.size.rows }.max() ?? 0
        guard cols > 0, rows > 0, f.width > 0, f.height > 0, scale > 0 else { return nil }
        let titleBar = config.titleBar
            ? NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled).height - 100
            : 0
        let contentH = f.height - titleBar
        let tabBarShown = config.tabBarOnTop(tabs: tabCount)

        func unique(_ values: [CGFloat]) -> [CGFloat] {
            values.reduce(into: []) { out, v in if v > 0, !out.contains(where: { abs($0 - v) < 0.01 }) { out.append(v) } }
        }
        let rawW = unique(tab.filter { $0.size.cols > 0 }.map { CGFloat($0.size.pixel_width) / CGFloat($0.size.cols) })
        let rawH = unique(tab.filter { $0.size.rows > 0 }.map { CGFloat($0.size.pixel_height) / CGFloat($0.size.rows) })

        /// 한 축을 푼다. extra: 남는 길이에 더 들어갈 수 있는 것(탭 바)의 최대치, reserve: 추정할 때 그 몫.
        func solve(count: Int, length: CGFloat, raw: [CGFloat], lead: String, trail: String,
                   leadCells: CGFloat, trailCells: CGFloat, extra: CGFloat, reserve: CGFloat)
            -> (start: CGFloat, cell: CGFloat, slack: CGFloat, divisor: CGFloat?) {
            func pads(_ c: CGFloat) -> (CGFloat, CGFloat) {
                (config.padding(lead, cell: c, window: length, pixelScale: scale, defaultCells: leadCells),
                 config.padding(trail, cell: c, window: length, pixelScale: scale, defaultCells: trailCells))
            }
            let divisors = [scale] + [1, 2, 3].filter { $0 != scale }
            for r in raw {
                for d in divisors {
                    let c = r / d
                    guard c >= 3 else { continue }
                    let (a, b) = pads(c)
                    let slack = length - a - b - CGFloat(count) * c
                    if slack >= -2, slack < c + 2 + extra { return (a, c, slack, d) }
                }
            }
            var c = (length - reserve) / CGFloat(count)
            for _ in 0..<2 {
                let (a, b) = pads(c)
                c = max(1, (length - a - b - reserve) / CGFloat(count))
            }
            return (pads(c).0, c, reserve, nil)
        }

        let x = solve(count: cols, length: f.width, raw: rawW, lead: "left", trail: "right",
                      leadCells: 1, trailCells: 1, extra: 0, reserve: 0)
        let y = solve(count: rows, length: contentH, raw: rawH, lead: "top", trail: "bottom",
                      leadCells: 0.5, trailCells: 0.5, extra: tabBarShown ? 60 : 0, reserve: tabBarShown ? 28 : 0)
        // 탭 바 높이는 글꼴에 따라 달라서 남는 높이에서 추정한다 (아래 나머지는 한 칸 미만이므로 반 칸으로 본다)
        let tabBar = !tabBarShown ? 0 : y.divisor == nil ? y.slack : max(0, y.slack - y.cell / 2)
        return Layout(cellW: x.cell, cellH: y.cell,
                      origin: CGPoint(x: f.minX + x.start, y: f.minY + titleBar + tabBar + y.start),
                      divisorX: x.divisor, divisorY: y.divisor, slack: max(0, x.slack) + max(0, y.slack))
    }

    /// 패널로 옮긴다. 마우스로 누르면 Claude Code·vim 처럼 마우스를 받는 프로그램에 클릭이 그대로 가서 쓰지 않는다.
    static func activate(pane id: Int) {
        guard let process = cliProcess(["activate-pane", "--pane-id", String(id)]) else { return }
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
    }

    /// 창의 패널마다 AX 요소 대신 쓸 영역. 스크롤·라벨 클릭 대상이 된다.
    static func paneElements(for window: Element, tab: VisibleTab?, scales: ScreenScales = .current()) -> [Element] {
        guard let tab else { return [] }
        return paneFrames(for: window, tab: tab.panes, tabCount: tab.tabCount,
                          scale: scales.scale(for: window.frame)).map { frame, pane in
            let e = Element.region(frame, in: window, role: "AXWezTermPane", title: pane.title)
            e.wezTermPane = pane.pane_id
            return e
        }
    }

    /// 창에 보이는 탭의 패널 영역들(AX 좌표). 하나뿐이면 나눌 필요가 없으니 빈 배열.
    static func paneFrames(for window: Element, tab: [Pane], tabCount: Int, scale: CGFloat) -> [(frame: CGRect, pane: Pane)] {
        guard tab.count > 1, let layout = layout(tab, tabCount: tabCount, window: window.frame, scale: scale,
                                                 config: Config.load()) else { return [] }
        if layout.divisorX != scale || layout.divisorY != scale {
            let sizes = tab.map { "\($0.size.cols)x\($0.size.rows)칸 \($0.size.pixel_width)x\($0.size.pixel_height)px dpi\($0.size.dpi ?? 0)" }
            func axis(_ d: CGFloat?) -> String { d.map { "÷\(Int($0))" } ?? "창 크기로 추정" }
            note("WezTerm 픽셀 값이 화면(배율 \(Int(scale)))과 안 맞음: 가로 \(axis(layout.divisorX)), 세로 \(axis(layout.divisorY))"
                 + " → 칸 \(layout.cellW)x\(layout.cellH)pt · 창 \(window.frame) · 패널 \(sizes.joined(separator: ", "))")
        }
        return frames(tab, layout: layout)
    }

    static func frames(_ tab: [Pane], layout: Layout) -> [(frame: CGRect, pane: Pane)] {
        tab.map {
            (CGRect(x: layout.origin.x + CGFloat($0.left_col) * layout.cellW,
                    y: layout.origin.y + CGFloat($0.top_row) * layout.cellH,
                    width: CGFloat($0.size.cols) * layout.cellW, height: CGFloat($0.size.rows) * layout.cellH), $0)
        }
    }

    // MARK: - 화면에 그려진 경계선으로 확인

    /// 계산한 패널 경계가 WezTerm 이 실제로 그린 경계선(설정의 split 색, 기본 #444444)과 맞는지.
    /// CLI 값은 틀린 채 남을 수 있어서(layout 참고) 화면을 기준으로 확인한다. 화면 기록 권한이 필요하다.
    struct ScreenCheck {
        struct Split {
            let vertical: Bool
            /// 창 왼쪽 위 기준 포인트
            let expected: CGFloat
            let found: CGFloat?
        }

        let splits: [Split]
        let tolerance: CGFloat
        var mismatched: [Split] { splits.filter { s in s.found.map { abs($0 - s.expected) > tolerance } ?? true } }
        /// 경계선을 하나도 못 찾으면 색이 다르거나 창이 가려진 것이라 판단하지 않는다
        var conclusive: Bool { splits.contains { $0.found != nil } }
    }

    static func checkOnScreen(window: Element, tab: VisibleTab, scale: CGFloat) -> ScreenCheck? {
        let config = Config.load()
        guard tab.panes.count > 1,
              let layout = layout(tab.panes, tabCount: tab.tabCount, window: window.frame, scale: scale, config: config),
              let id = AX.windowID(window.ref),
              let image = captureWindow(id, size: window.frame.size, scale: scale) else { return nil }
        let px = CGFloat(image.width) / window.frame.width
        let lines = splitLines(in: image, color: config.splitColor ?? (0x44, 0x44, 0x44))
        var expected: [(vertical: Bool, at: CGFloat)] = []
        for p in tab.panes {
            // 경계선은 두 패널 사이 한 칸의 가운데에 그려진다
            if p.left_col > 0 { expected.append((true, layout.origin.x - window.frame.minX + (CGFloat(p.left_col) - 0.5) * layout.cellW)) }
            if p.top_row > 0 { expected.append((false, layout.origin.y - window.frame.minY + (CGFloat(p.top_row) - 0.5) * layout.cellH)) }
        }
        var seen = Set<String>()
        let splits = expected.filter { seen.insert("\($0.vertical)\(Int($0.at.rounded()))").inserted }.map { e in
            let found = (e.vertical ? lines.xs : lines.ys).map { $0 / px }.min { abs($0 - e.at) < abs($1 - e.at) }
            return ScreenCheck.Split(vertical: e.vertical, expected: e.at, found: found)
        }
        return ScreenCheck(splits: splits, tolerance: max(2, min(layout.cellW, layout.cellH) / 2))
    }

    /// 이미지에서 split 색으로 길게(이미지 길이의 1/5 이상) 이어진 세로·가로 줄의 가운데(이미지 픽셀).
    static func splitLines(in image: CGImage, color c: (Int, Int, Int), tolerance: Int = 48) -> (xs: [CGFloat], ys: [CGFloat]) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return ([], []) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func hit(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return abs(Int(buf[i]) - c.0) <= tolerance && abs(Int(buf[i + 1]) - c.1) <= tolerance
                && abs(Int(buf[i + 2]) - c.2) <= tolerance
        }
        func longestRun(_ n: Int, _ at: (Int) -> Bool) -> Int {
            var best = 0, run = 0
            for i in 0..<n {
                run = at(i) ? run + 1 : 0
                best = max(best, run)
            }
            return best
        }
        /// 붙어 있는 줄 번호를 묶어 가운데를 낸다
        func centers(_ hits: [Int]) -> [CGFloat] {
            var out: [CGFloat] = []
            var group: [Int] = []
            for i in hits {
                if let last = group.last, i != last + 1 {
                    out.append(CGFloat(group.first! + group.last!) / 2 + 0.5)
                    group = []
                }
                group.append(i)
            }
            if !group.isEmpty { out.append(CGFloat(group.first! + group.last!) / 2 + 0.5) }
            return out
        }
        let xs = (0..<w).filter { x in longestRun(h) { hit(x, $0) } >= max(40, h / 5) }
        let ys = (0..<h).filter { y in longestRun(w) { hit($0, y) } >= max(40, w / 5) }
        return (centers(xs), centers(ys))
    }

    /// 창 하나를 (다른 창에 가려져 있어도) 찍는다. 3초 안에 못 찍으면 nil.
    private static func captureWindow(_ id: CGWindowID, size: CGSize, scale: CGFloat) -> CGImage? {
        guard #available(macOS 14.0, *) else { return nil }
        let done = DispatchSemaphore(value: 0)
        var result: CGImage?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            guard let window = content?.windows.first(where: { $0.windowID == id }) else {
                done.signal()
                return
            }
            let config = SCStreamConfiguration()
            config.width = Int(size.width * scale)
            config.height = Int(size.height * scale)
            config.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                             configuration: config) { image, _ in
                result = image
                _ = done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 3)
        return result
    }

    /// 같은 내용은 한 번만 로그에 남긴다(스크롤 모드를 열 때마다 쌓이지 않게)
    private static var noted = Set<String>()
    private static let noteLock = NSLock()

    private static func note(_ line: String) {
        noteLock.lock()
        let fresh = noted.insert(line).inserted
        noteLock.unlock()
        if fresh { Log.write(line) }
    }

    /// ~/.wezterm.lua 에서 배치에 필요한 설정만 읽는다. 주석 줄은 빼고, 같은 설정이 여러 번이면 마지막 것.
    struct Config {
        let text: String

        static func load() -> Config {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let paths = [ProcessInfo.processInfo.environment["WEZTERM_CONFIG_FILE"],
                         home + "/.wezterm.lua", home + "/.config/wezterm/wezterm.lua"].compactMap { $0 }
            let raw = paths.lazy.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.first ?? ""
            let lines = raw.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            return Config(text: lines.joined(separator: "\n"))
        }

        private func last(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last else { return nil }
            return (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }

        private func flag(_ name: String) -> Bool? {
            last(name + #"\s*=\s*(true|false)"#).map { $0[1] == "true" }
        }

        /// window_padding 의 한 변(포인트). 숫자만 쓰면 픽셀, 'Ncell'·'Npx'·'Npt'·'N%' 도 받는다.
        func padding(_ side: String, cell: CGFloat, window: CGFloat, pixelScale: CGFloat,
                     defaultCells: CGFloat) -> CGFloat {
            guard let block = last(#"window_padding\s*=\s*\{([^}]*)\}"#)?[1],
                  let re = try? NSRegularExpression(pattern: side + #"\s*=\s*['"]?([0-9.]+)\s*(cell|px|pt|%)?"#),
                  let m = re.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
                  let numberRange = Range(m.range(at: 1), in: block), let n = Double(block[numberRange])
            else { return defaultCells * cell }
            let unit = Range(m.range(at: 2), in: block).map { String(block[$0]) } ?? ""
            switch unit {
            case "cell": return CGFloat(n) * cell
            case "pt": return CGFloat(n)
            case "%": return CGFloat(n) / 100 * window
            default: return CGFloat(n) / pixelScale
            }
        }

        /// colors 의 split = '#rrggbb' (패널 경계선 색)
        var splitColor: (Int, Int, Int)? {
            guard let hex = last(##"split\s*=\s*['"]#([0-9a-fA-F]{6})['"]"##)?[1], let v = Int(hex, radix: 16) else { return nil }
            return ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
        }

        /// 기본값은 macOS 제목 막대가 있는 'TITLE | RESIZE'
        var titleBar: Bool {
            guard let value = last(#"window_decorations\s*=\s*['"]([^'"]*)['"]"#)?[1] else { return true }
            return value.contains("TITLE")
        }

        func tabBarOnTop(tabs: Int) -> Bool {
            guard flag("enable_tab_bar") != false, flag("tab_bar_at_bottom") != true else { return false }
            return tabs > 1 || flag("hide_tab_bar_if_only_one_tab") != true
        }
    }

    /// 제목 앞의 스피너·아이콘(◐ ✳ 등)은 계속 바뀌므로 글자나 숫자가 나오기 전까지는 버리고 비교한다.
    private static func normalized(_ title: String) -> Substring {
        title.drop { !($0.isLetter || $0.isNumber) }
    }
}
