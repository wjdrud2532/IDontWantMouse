import AppKit
import QuartzCore

/// 앱 호환성 점검. Hanmium 이 그 앱에서 찾아야 할 것을 못 찾는 신호를 잡아낸다.
/// 앱마다 화면 구조가 달라서 생기는 문제(Slack 의 스크롤 영역, 새 WezTerm 창의 분할 창 등)를 쓰다가 마주치기 전에 알려고 둔다.
/// `Hanmium --check [번들ID]` 로 실행 중인 앱(또는 그 앱)을 점검하고, 메뉴 막대의 "이 앱 점검" 으로도 볼 수 있다.
enum Diagnostics {
    enum Level: String {
        case ok = "✓"
        case info = "·"
        case warn = "⚠︎"
    }

    struct Finding {
        let level: Level
        let text: String
    }

    struct Report {
        let app: String
        let findings: [Finding]

        var hasWarnings: Bool { findings.contains { $0.level == .warn } }

        var text: String {
            "[\(app)]\n" + findings.map { "  \($0.level.rawValue) \($0.text)" }.joined(separator: "\n")
        }
    }

    /// builder 는 메인 스레드에서 만든 것(TreeBuilder.forFrontmost). 점검은 AX 를 많이 부르므로 백그라운드에서 돌려도 된다.
    static func check(_ running: NSRunningApplication, builder: TreeBuilder, scrollBuilder: TreeBuilder) -> Report {
        let name = running.localizedName ?? running.bundleIdentifier ?? "?"
        var findings: [Finding] = []
        func add(_ level: Level, _ text: String) { findings.append(Finding(level: level, text: text)) }

        guard AXIsProcessTrusted() else {
            return Report(app: name, findings: [Finding(level: .warn, text: "손쉬운 사용 권한이 없어 점검할 수 없습니다")])
        }

        // 라벨 클릭
        var t0 = CACurrentMediaTime()
        let click = builder.clickSnapshot()
        let clickMs = Int((CACurrentMediaTime() - t0) * 1000)
        let window = click.anchor
        let inWindow = window.map { w in click.elements.filter { w.contains($0.clickPoint) }.count } ?? 0
        if window == nil {
            add(.info, "앞에 있는 창이 없습니다 (메뉴 막대·Dock 만 대상)")
        } else if inWindow == 0 {
            add(.warn, "창 안에서 클릭 대상을 하나도 찾지 못했습니다 — 앱이 손쉬운 사용 정보를 내놓지 않습니다")
        } else {
            add(.ok, "클릭 대상: 창 안 \(inWindow)개, 전체 \(click.elements.count)개")
        }
        if clickMs > 600 { add(.warn, "라벨을 찾는 데 \(clickMs)ms — 느립니다") } else { add(.ok, "라벨 찾기 \(clickMs)ms") }

        // 스크롤
        t0 = CACurrentMediaTime()
        let scroll = scrollBuilder.scrollSnapshot()
        let scrollMs = Int((CACurrentMediaTime() - t0) * 1000)
        if scroll.windows.isEmpty {
            add(.info, "스크롤할 창이 없습니다")
        } else {
            let fw = scroll.windows.indices.contains(scroll.focusedWindow) ? scroll.focusedWindow : 0
            let w = scroll.windows[fw].frame
            let areas = scroll.areas.filter { $0.window == fw }.map(\.area)
            let wholeWindow = areas.count == 1
                && areas[0].visibleFrame.width * areas[0].visibleFrame.height >= w.width * w.height * 0.85
            if areas.count == 1, areas[0].role == kAXWindowRole {
                add(.warn, "스크롤 영역을 찾지 못해 창 전체에 휠을 보냅니다")
            } else if wholeWindow && isWebApp(running) && !TreeBuilder.browsers.contains(running.bundleIdentifier ?? "") {
                // 브라우저는 페이지 하나뿐인 사이트가 흔하다 — 그때는 페이지 전체가 맞다
                add(.warn, "웹 화면(Electron·Chromium)인데 안쪽 스크롤 영역을 찾지 못했습니다 — 창 전체 하나로 잡힙니다")
            } else {
                add(.ok, "스크롤 영역 \(areas.count)개")
            }
            if running.bundleIdentifier == WezTerm.bundleID {
                let tab = WezTerm.visibleTabs(for: [scroll.windows[fw]], in: WezTerm.panes())[0]
                let expected = tab?.panes.count ?? 0
                if expected > 1, areas.filter({ $0.wezTermPane != nil }).count != expected {
                    add(.warn, "WezTerm 분할 창 \(expected)개 중 \(areas.filter { $0.wezTermPane != nil }.count)개만 찾았습니다")
                } else if expected > 1 {
                    add(.ok, "WezTerm 분할 창 \(expected)개 모두 찾음")
                } else if tab == nil {
                    add(.warn, "이 창과 짝이 되는 WezTerm 창을 CLI 에서 찾지 못했습니다")
                }
            }
            if scroll.focusedArea == nil {
                add(.info, "키보드 포커스가 있는 영역을 알 수 없어 가장 큰 영역에서 시작합니다")
            } else {
                add(.ok, "포커스 영역에서 시작 (\(scroll.focusedArea! + 1)번)")
            }
        }
        if scrollMs > 600 { add(.warn, "스크롤 영역을 찾는 데 \(scrollMs)ms — 느립니다") } else { add(.ok, "스크롤 영역 찾기 \(scrollMs)ms") }

        if GlassSnapshots.usesGlass, !CGPreflightScreenCaptureAccess() {
            add(.info, "화면 기록 권한이 없어 유리 굴절 대신 흐림으로 그립니다")
        }
        return Report(app: name, findings: findings)
    }

    /// Electron·Chromium 으로 만든 앱인지 (번들 안 프레임워크로 판단)
    static func isWebApp(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, AXEnabler.chromiumBrowsers.contains(id) { return true }
        guard let url = app.bundleURL?.appendingPathComponent("Contents/Frameworks") else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { $0.hasPrefix("Electron Framework") || $0.contains("Chromium") }
    }

    /// --check: 지정한 앱, 없으면 창이 있는 실행 중인 앱 모두. 경고가 있으면 종료 코드 1.
    static func runCLI(bundleID: String?) -> Int32 {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        let apps = bundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            ?? NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard !apps.isEmpty else {
            print("점검할 앱을 찾지 못했습니다.")
            return 2
        }
        var warned = false
        for app in apps {
            let report = check(app, builder: TreeBuilder.forFrontmost(app), scrollBuilder: TreeBuilder.forFrontmost(app))
            print(report.text)
            warned = warned || report.hasWarnings
        }
        return warned ? 1 : 0
    }
}
