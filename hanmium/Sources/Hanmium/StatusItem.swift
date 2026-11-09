import AppKit
import ApplicationServices

/// 메뉴 막대 아이콘. 실행 중인지, 단축키·권한 상태를 보여주고 사용 전환·설정을 연다.
final class StatusItem: NSObject, NSMenuDelegate {
    enum HotkeyState { case registered, failed, off }

    struct Hotkey {
        let kind: ModeKind
        let display: String
        let state: HotkeyState
    }

    var hotkeys: [Hotkey] = []
    var onToggleEnabled: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// 번들 ID 를 앱별 사용 목록에 넣거나 뺀다
    var onToggleListed: ((String) -> Void)?
    var onCheckApp: ((NSRunningApplication) -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        item.button?.image = Self.icon
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshButton()
    }

    /// 앱 아이콘의 노란 라벨을 옮긴 "jk" 알약. 템플릿이라 메뉴 막대 색을 따르고, 글자는 알약을 뚫어서 그린다.
    private static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let pill = CGRect(x: 0.5, y: 2.5, width: 19, height: 13)
            ctx.setFillColor(.black)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            let base = NSFont.systemFont(ofSize: 11.5, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11.5) } ?? base
            let text = NSAttributedString(string: "jk", attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            let line = CTLineCreateWithAttributedString(text)
            // j 의 아래 꼬리까지 넣은 글자 모양 기준으로 알약 가운데에 둔다
            let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.setBlendMode(.destinationOut)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: pill.midX - glyphs.midX, y: pill.midY - glyphs.midY)
            CTLineDraw(line, ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hanmium"
        return image
    }()

    /// 메뉴 막대 메뉴가 열려도 앞 앱은 그대로라서, 이 앱이 '지금 쓰던 앱'이다. Hanmium 자신(설정 창)은 뺀다.
    private var frontmostOther: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              app.bundleIdentifier != nil else { return nil }
        return app
    }

    /// 권한이 없거나, 일시 정지 중이거나, 앱별 설정으로 지금 앱에서 꺼진 상태면 아이콘을 흐리게
    func refreshButton() {
        let trusted = AXIsProcessTrusted()
        let blockedApp = frontmostOther.flatMap { Config.isAllowed($0.bundleIdentifier) ? nil : $0 }
        item.button?.appearsDisabled = !trusted || !Config.enabled || blockedApp != nil
        let state = !trusted ? "Hanmium: 손쉬운 사용 권한 필요"
            : !Config.enabled ? "Hanmium 일시 정지됨"
            : blockedApp.map { "Hanmium: \($0.localizedName ?? "이 앱")에서 꺼짐" } ?? "Hanmium 실행 중"
        item.button?.toolTip = state + (Self.glassNeedsCapture ? " · 화면 기록 권한 없음(유리 굴절 꺼짐)" : "")
    }

    // 열 때마다 권한 상태를 다시 확인해서 메뉴를 만든다
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshButton()
        menu.removeAllItems()
        menu.addItem(withTitle: item.button?.toolTip ?? "Hanmium", action: nil, keyEquivalent: "")
        if !AXIsProcessTrusted() {
            let fix = menu.addItem(withTitle: "⚠︎ 손쉬운 사용 권한 필요 — 설정 열기",
                                   action: #selector(openAccessibilitySettings), keyEquivalent: "")
            fix.target = self
        }
        if Self.glassNeedsCapture {
            let fix = menu.addItem(withTitle: "⚠︎ 화면 기록 권한 필요(유리 굴절) — 설정 열기",
                                   action: #selector(openScreenCaptureSettings), keyEquivalent: "")
            fix.target = self
        }
        menu.addItem(.separator())
        // 단축키를 오른쪽 열에 맞춰 보여준다
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 170)]
        for h in hotkeys {
            let (state, color): (String, NSColor) = switch h.state {
            case .registered: (h.display, .secondaryLabelColor)
            case .failed: ("\(h.display) (등록 실패)", .systemRed)
            case .off: ("꺼짐", .tertiaryLabelColor)
            }
            let line = NSMenuItem(title: h.kind.title, action: nil, keyEquivalent: "")
            line.attributedTitle = NSAttributedString(string: "\(h.kind.title)\t\(state)", attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: color,
                .paragraphStyle: style,
            ])
            menu.addItem(line)
        }
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: "Hanmium 사용", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = Config.enabled ? .on : .off
        // 지금 앱을 앱별 사용 목록에 넣거나 뺀다. 방식에 따라 '사용 안 함' 목록이거나 '사용' 목록이다.
        if let app = frontmostOther, let id = app.bundleIdentifier {
            let name = app.localizedName ?? id
            let title = Config.appFilterMode == .include ? "\(name)에서 사용" : "\(name)에서 사용 안 함"
            let listed = menu.addItem(withTitle: title, action: #selector(toggleListed(_:)), keyEquivalent: "")
            listed.target = self
            listed.representedObject = id
            listed.state = Config.isListed(id) ? .on : .off
            let check = menu.addItem(withTitle: "\(name) 점검…", action: #selector(checkApp(_:)), keyEquivalent: "")
            check.target = self
            check.representedObject = app
        }
        let settings = menu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hanmium 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleEnabled() { onToggleEnabled?() }

    @objc private func toggleListed(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onToggleListed?(id) }
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func checkApp(_ sender: NSMenuItem) {
        if let app = sender.representedObject as? NSRunningApplication { onCheckApp?(app) }
    }

    /// 유리를 쓰는데 화면 기록 권한이 없어 굴절 대신 흐림으로 그리는 중인지
    static var glassNeedsCapture: Bool { GlassSnapshots.usesGlass && !CGPreflightScreenCaptureAccess() }

    @objc private func openScreenCaptureSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
