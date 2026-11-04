import AppKit

/// WezTerm 은 AX 로 분할 패널을 알려주지 않아서 `wezterm cli list` 의 배치(칸 단위)를 화면 좌표로 바꾼다.
enum WezTerm {
    static let bundleID = "com.github.wez.wezterm"

    struct Pane: Decodable {
        struct Size: Decodable {
            let rows: Int
            let cols: Int
            let pixel_width: Int
            let pixel_height: Int
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
        guard let exe = executables.first(where: FileManager.default.isExecutableFile) else { return Data() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["cli"] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
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

    static func visibleTabs(for windows: [Element], in panes: [Pane], focused known: Int?? = nil) -> [VisibleTab?] {
        guard !panes.isEmpty else { return windows.map { _ in nil } }
        let focused = known ?? focusedPaneID()
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
                guard let tab = tabs[visible], let slack = fit(tab, in: window.frame) else { return nil }
                let titled = !title.isEmpty && (normalized(first.window_title) == title
                    || tab.contains { $0.is_active && normalized($0.title) == title })
                return ((titled ? 0 : 10000) + slack, VisibleTab(panes: tab, tabCount: tabs.count), id)
            }
            guard let best = scored.min(by: { $0.score < $1.score }) else { return nil }
            free.remove(best.id)
            return best.tab
        }
    }

    /// 탭 내용(칸 수 × 칸 크기)이 창 안에 들어맞으면 남는 폭 + 높이(여백·제목 막대·탭 바·칸 나머지), 아니면 nil
    private static func fit(_ tab: [Pane], in f: CGRect) -> CGFloat? {
        guard let s = tab.first, s.size.cols > 0, s.size.rows > 0, f.width > 0 else { return nil }
        let cellW = CGFloat(s.size.pixel_width) / CGFloat(s.size.cols)
        let cellH = CGFloat(s.size.pixel_height) / CGFloat(s.size.rows)
        let rawW = tab.map { CGFloat($0.left_col + $0.size.cols) * cellW }.max() ?? 0
        let rawH = tab.map { CGFloat($0.top_row + $0.size.rows) * cellH }.max() ?? 0
        let scale = max(1, (rawW / f.width).rounded())
        let slackW = f.width - rawW / scale, slackH = f.height - rawH / scale
        guard slackW >= -2, slackH >= -2, slackW <= cellW / scale * 3 + 80, slackH <= cellH / scale * 3 + 160
        else { return nil }
        return slackW + slackH
    }

    /// 패널로 옮긴다. 마우스로 누르면 Claude Code·vim 처럼 마우스를 받는 프로그램에 클릭이 그대로 가서 쓰지 않는다.
    static func activate(pane id: Int) {
        guard let exe = executables.first(where: FileManager.default.isExecutableFile) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["cli", "activate-pane", "--pane-id", String(id)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// 창의 패널마다 AX 요소 대신 쓸 영역. 스크롤·라벨 클릭 대상이 된다.
    static func paneElements(for window: Element, tab: VisibleTab?) -> [Element] {
        guard let tab else { return [] }
        return paneFrames(for: window, tab: tab.panes, tabCount: tab.tabCount).map { frame, pane in
            let e = Element.region(frame, in: window, role: "AXWezTermPane", title: pane.title)
            e.wezTermPane = pane.pane_id
            return e
        }
    }

    /// 창에 보이는 탭의 패널 영역들(AX 좌표). 하나뿐이면 나눌 필요가 없으니 빈 배열.
    static func paneFrames(for window: Element, tab: [Pane], tabCount: Int) -> [(frame: CGRect, pane: Pane)] {
        guard tab.count > 1, let sample = tab.first, sample.size.cols > 0, sample.size.rows > 0 else { return [] }

        var cellW = CGFloat(sample.size.pixel_width) / CGFloat(sample.size.cols)
        var cellH = CGFloat(sample.size.pixel_height) / CGFloat(sample.size.rows)
        let f = window.frame
        // Retina 화면에서는 픽셀 단위라 창(포인트)보다 배수로 크다
        let rawW = tab.map { CGFloat($0.left_col + $0.size.cols) * cellW }.max() ?? 0
        let scale = max(1, (rawW / f.width).rounded())
        cellW /= scale
        cellH /= scale
        let totalW = rawW / scale
        let totalH = tab.map { CGFloat($0.top_row + $0.size.rows) * cellH }.max() ?? 0
        // WezTerm 은 왼쪽 위(제목 막대·탭 바·안쪽 여백 다음)부터 칸을 채우고, 칸에 못 미치는 나머지는
        // 오른쪽·아래에 남긴다. 그래서 왼쪽·위 여백만 알면 정확하다.
        let config = Config.load()
        let titleBar = config.titleBar
            ? NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled).height - 100
            : 0
        let contentH = f.height - titleBar
        let left = config.padding("left", cell: cellW, window: f.width, pixelScale: scale, defaultCells: 1)
        let top = config.padding("top", cell: cellH, window: contentH, pixelScale: scale, defaultCells: 0.5)
        let bottom = config.padding("bottom", cell: cellH, window: contentH, pixelScale: scale, defaultCells: 0.5)
        var tabBar: CGFloat = 0
        if config.tabBarOnTop(tabs: tabCount) {
            // 탭 바 높이는 글꼴에 따라 달라서 남는 높이에서 추정한다 (아래 나머지는 한 칸 미만이므로 반 칸으로 본다)
            tabBar = max(0, contentH - top - bottom - totalH - cellH / 2)
        }
        let originX = f.minX + left
        let originY = f.minY + titleBar + tabBar + top
        return tab.map {
            (CGRect(x: originX + CGFloat($0.left_col) * cellW, y: originY + CGFloat($0.top_row) * cellH,
                    width: CGFloat($0.size.cols) * cellW, height: CGFloat($0.size.rows) * cellH), $0)
        }
    }

    /// ~/.wezterm.lua 에서 배치에 필요한 설정만 읽는다. 주석 줄은 빼고, 같은 설정이 여러 번이면 마지막 것.
    struct Config {
        private let text: String

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
